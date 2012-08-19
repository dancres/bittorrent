require 'thread'
require 'socket'
require 'logger'
require_relative 'tracker.rb'
require_relative 'selector.rb'
require_relative 'btproto.rb'
require_relative 'storage.rb'
require_relative 'picker.rb'
require_relative 'util.rb'

class Downloader

	def initialize(storage, metainfo, tracker, client_details)
		@meta = metainfo
		@tracker = tracker
		@client_details = client_details
		@core = Core.new(client_details)
		@storage = storage
	end

	def run
		collector = Collector.new(@core.scheduler, @core.selector, @core.pool, @storage, @tracker, @meta, @client_details)
		collector.wait_for_exit
	end	
end

class Core
	attr_reader :selector, :serversocket, :client_details, :scheduler, :pool

	def initialize(client_details)
		@selector = Selector.new
		@client_details = client_details
		@serversocket = TCPServer.new(client_details.port)
		@scheduler = Scheduler.new
		@pool = Pool.new
	end

	def terminate
	end
end

=begin

If each message from a connection includes the connection itself and that connection indicates whether it is
server or client mode we can proceed and determine what to do with handshakes, bitmaps etc.

So for a connection from a client, the message might be "new connection, server" and we'd add ourselves as listener,
waiting for a handshake.

For a connection to a server, we'd get a message "new peer" and create a client connection into which we'd queue a
handshake straightaway.

We could have a connection support meta-data which we could markup to include it's server or client status, 
bitmap etc.

The connection could then be started with this meta-data and a signal for how to do the open (handshake first or
second) and it would call back with the handshake from the client at the appropriate moment. This allows
connection to continue handling e.g. warden constructs.

We'll need some timers to e.g. update Tracker. The timers gem (installed with rake install in timers dir) can do
this but is not thread-safe. BEWARE!

TODO:

We'll also need to handle choke, unchoke, interested and uninterested - catching others and sending ours
Choking, snubbing, keep alives etc
Server socket handling
Tracker updates
Statistics - per connection (state machine maintains them for upload and download bytes)

=end

class Collector
	MODE = 1
	CLIENT = 2
	PEER_CHOKED = 3
	AM_CHOKED = 4
	PEER_INTERESTED = 5
	AM_INTERESTED = 6
	BITFIELD = 7
	PIECE = 8
	BLOCKS = 9
	TIMER = 10
	SERVER = 11

	def initialize(scheduler, selector, connection_pool, storage, tracker, metainfo, client_details)
		@metainfo = metainfo
		@scheduler = scheduler
		@tracker_timer = nil
		@selector = selector
		@pool = connection_pool
		@client_details = client_details
		@lock = Mutex.new
		@terminate = false
		@queue = Queue.new
		@storage = storage
		@tracker = tracker
		@picker = Picker.new(@metainfo.info.pieces.pieces.length)
		@uploaded = 0
		@downloaded = 0		
		@logger = Logger.new(STDOUT)
		@logger.level = Logger::DEBUG
		formatter = Logger::Formatter.new
			@logger.formatter = proc { |severity, datetime, progname, msg|
		    	formatter.call(severity, datetime, progname, "#{@metainfo.info.sha1_hash.unpack("H*")} #{msg.dump}")
			}

		@queue_thread = Thread.new { run }
	end

	def wait_for_exit
		@queue_thread.join
	end

	def terminate
		@lock.synchronize {
			@terminate = true
		}

		@queue.enq(:poison)

		@queue_thread.join
	end

	def terminate?
		@lock.synchronize {
			@terminate
		}
	end

	def update(message)
		@queue.enq(message)
	end

	def run
		Thread.current.abort_on_exception = true

		response = @tracker.ping({Tracker::UPLOADED => 0, Tracker::DOWNLOADED => 0, 
			Tracker::LEFT => (@storage.overall_bytes - @storage.current_bytes),
			Tracker::EVENT => Tracker::STATUS_STARTED})

		puts response

		if (response.code == 200)
			puts "Good - going to pull: #{@metainfo.info.sha1_hash.unpack("H*")} #{@metainfo.info.pieces.pieces.length} pieces of length #{@metainfo.info.pieces.piece_length}"
			puts "#{@metainfo.info.directory}"

			tr = Tracker::AnnounceResponse.new(response.body)

			puts tr

			# Start connection for each peer that isn't us (as identified by Socket)
			my_addresses = Socket.ip_address_list.map { |addr| addr.ip_address}

			tr.peers.each { |peer|
				if (! ((my_addresses.include?(peer.ip.ip_address) && (peer.port == @client_details.port))))
					update(Peer.new(peer.id, peer.ip.ip_address, peer.port))
				end
			}

			@tracker_timer = @scheduler.add { |timers| timers.every(tr.interval) {
				update(UpdateTracker.new)
			}}

		else
			puts "Bad #{response.code}"
			return
		end

		until terminate? do
			message = @queue.deq
			@logger.debug("Message: #{message}")

			if (! terminate?)
				case message
				
				when UpdateTracker
					ping_tracker(message.status)

				when Peer
					socket = TCPSocket.new(message.ip, message.port)
					conn = Connection.new(socket, Connection::SEND_HANDSHAKE, @metainfo.info.sha1_hash, @selector, @client_details.peer_id)
					conn.metadata { |meta| 
						meta[MODE] = CLIENT
						meta[AM_CHOKED] = true
						meta[AM_INTERESTED] = false
						meta[PEER_CHOKED] = true
						meta[PEER_INTERESTED] = false
					}

					conn.add_observer(self)
					@pool.add(conn)
					conn.start	

				when Client
					conn = Connection.new(message.socket, Connection::HANDSHAKE_WAIT, @metainfo.info.sha1_hash, @selector, @client_details.peer_id)
					conn.metadata { |meta| 
						meta[MODE] = SERVER
						meta[AM_CHOKED] = true
						meta[AM_INTERESTED] = false
						meta[PEER_CHOKED] = true
						meta[PEER_INTERESTED] = false
					}

					conn.add_observer(self)
					@pool.add(conn)
					conn.start	

				when Handshake
					conn = message.connection

					if (@metainfo.info.sha1_hash == message.info_hash)
						@logger.debug("Valid #{message}")

						conn.send(Bitfield.new.implode(@storage.got))

						t = @scheduler.add { |timers| timers.every(20) {
								conn.send(KeepAlive.new.implode)
							}}

						conn.metadata { |meta| meta[TIMER] = t }
					else
						@logger.warn("Invalid #{message}")
						conn.close 
					end

				when Bitfield
					conn = message.connection

					b = Bitset.new(@metainfo.info.pieces.pieces.length).from_binary(message.bitfield)

					@picker.available(b)
					conn.metadata { |meta| meta[BITFIELD] = b }

					if (b.and(@storage.needed).nonZero)
						conn.metadata { |meta| meta[AM_INTERESTED] = true }
						conn.send(Interested.new.implode)

						start_streaming(conn)
					end

				when Have
					conn = message.connection
					b = conn.metadata { |meta| meta[BITFIELD] }

					if (b == nil)
						b = Bitset.new(@metainfo.info.pieces.pieces.length)
						conn.metadata { |meta| meta[BITFIELD] = b }
					end

					b.set(message.index)

					if (! metadata { |meta| meta[AM_INTERESTED] })
						if (b.and(@storage.needed).nonZero)
							conn.metadata { |meta| meta[AM_INTERESTED] = true }
							conn.send(Interested.new.implode)

							start_streaming(conn)
						end						
					end

				when Choke
					conn = message.connection
					conn.metadata { |meta| meta[AM_CHOKED] = true }

					clear_requests(conn)

				when Unchoke
					conn = message.connection
					conn.metadata { |meta| meta[AM_CHOKED] = false }

					start_streaming(conn)

				when Interested
					conn = message.connection
					conn.metadata { |meta| meta[PEER_INTERESTED] = true }

				when NotInterested
					conn = message.connection
					conn.metadata { |meta| meta[PEER_INTERESTED] = false }

					if (! conn.metadata { |meta| meta[PEER_CHOKED] })
						conn.metadata { |meta| meta[PEER_CHOKED] = true }
						conn.send(Choke.new.implode)
					end

				when Piece
					conn = message.connection					
					piece = conn.metadata { |meta| meta[PIECE] }

					if (piece == nil)
						@logger.warn("Unexpected piece - dropped #{conn}")
						return
					end

					blocks = conn.metadata { |meta| meta[BLOCKS] }
					current_block = blocks.take(1).flatten
					remaining_blocks = blocks.drop(1)

					@storage.save_block(piece, current_block, message.block)
					@downloaded += message.block.length

					if (remaining_blocks.length == 0)
						@storage.piece_complete(piece)

						if (@storage.complete?)
							update(UpdateTracker.new(Tracker::STATUS_COMPLETED))

							@logger.info("Closing up storage")
							@storage.close
						end

						# Send out not interested to anyone that can't supply us, also update our AM_INTERESTED
						# Send out have to any connections that are missing the piece we got
						#
						outstanding = @storage.needed

						@pool.each { |c| 
							available = c.metadata { |meta| meta[BITFIELD] }

							# If we're interested that can only be because we've seen a HAVE or BITFIELD which means no null check
							#
							if (c.metadata { |meta| meta[AM_INTERESTED] })
								if ((@storage.complete?) || (! available.and(outstanding).nonZero))
									c.metadata { |meta| meta[AM_INTERESTED] = false }
									c.send(NotInterested.new.implode)
								end
							end

							# In this general case, we have no guarantee we save a HAVE or BITFIELD
							#
							if (available != nil)
								if (available.get(piece) == 0)
									c.send(Have.new.implode(piece))
								end
							end
						}

						clear_requests(conn)

						start_streaming(conn)
					else
						conn.metadata { |meta| meta[BLOCKS] = remaining_blocks }

						if (wouldSend(conn))
							range = remaining_blocks.take(1).flatten
							@logger.debug "Next block #{piece} #{range}"
							conn.send(Request.new.implode(piece, range[0], range[1]))
						end
					end

				when Request

					# TODO: Request handling - update @uploaded with number of bytes

				when KeepAlive

					# TODO: Ought to track connection liveness

				when Closed
					conn = message.connection

					@pool.remove(conn)

					t = conn.metadata { |meta| meta[TIMER] }
					t.cancel unless (t == nil)

					@picker.unavailable(conn.metadata { |meta| meta[BITFIELD] })

					# CLEANUP - Tell picker about in-flight bits gone, piece unavailability etc
				else
					@logger.warn("Unprocessed message: #{message}")
				end
			end
		end

		ping_tracker(Tracker::STATUS_STOPPED)
	end

	def clear_requests(conn)
		piece = conn.metadata { |meta| meta[PIECE] }

		@picker.release_piece(piece) unless (piece == nil)

		conn.metadata { |meta|
			meta[PIECE] = nil
			meta[BLOCKS] = nil
		}
	end

	def wouldSend(conn)
		conn.metadata { |meta| (!meta[AM_CHOKED] && meta[AM_INTERESTED]) }
	end

	def start_streaming(conn)
		if (! wouldSend(conn))
			@logger.debug("Would stream but inhibited")
			return
		end

		piece = @picker.next_piece(@storage.needed, conn.metadata { |meta| meta[BITFIELD] })
		blocks = @storage.blocks(piece)
		@logger.debug("Selected piece: #{piece} #{blocks}")

		conn.metadata { |meta|
			meta[PIECE] = piece
			meta[BLOCKS] = blocks
		}

		range = blocks.take(1).flatten
		conn.send(Request.new.implode(piece, range[0], range[1]))
	end

	def ping_tracker(event)
		response = @tracker.ping({Tracker::UPLOADED => @uploaded, Tracker::DOWNLOADED => @downloaded, 
			Tracker::LEFT => (@storage.overall_bytes - @storage.current_bytes),
			Tracker::NO_PEER_ID => "",
			Tracker::EVENT => event})

		if (response.code != 200)
			@logger.warn("Tracker update failed: #{response}")
		end	
	end

	class Peer
		attr_reader :id, :ip, :port

		def initialize(id = nil, ip, port)
			@id = id
			@ip = ip
			@port = port
		end

		def to_s
	        "Peer => #{id} #{ip} #{port}"		
		end
	end

	class Client
		attr_reader :socket

		def initialize(s)
			@socket = s
		end
	end

	class UpdateTracker
		attr_reader :status

		def initialize(status = Tracker::UPDATE)
			@status = status
		end
	end
end


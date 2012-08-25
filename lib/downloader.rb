require 'thread'
require 'socket'
require 'set'
require_relative 'tracker.rb'
require_relative 'selector.rb'
require_relative 'btproto.rb'
require_relative 'storage.rb'
require_relative 'picker.rb'
require_relative 'util.rb'
require_relative '../configure/environment.rb'

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
		@core.accept_handler.add_observer(collector)
		@core.accept_handler.start

		collector.wait_for_exit
	end	
end

class Core
	attr_reader :selector, :serversocket, :accept_handler, :client_details, :scheduler, :pool

	def initialize(client_details)
		@selector = Selector.new
		@client_details = client_details
		@serversocket = TCPServer.new(client_details.port)
		@accept_handler = Acceptor.new(@selector, @serversocket)
		@scheduler = Scheduler.new
		@pool = Pool.new
	end

	def terminate
	end
end

=begin

TODO:

Fast extensions and others
Snubbing

Chain of Responsibility
=======================

Could change the observer structure so that we have a chain of responsibility arrangement for processing messages.
This might allow clean and separate state machines for e.g. fast extensions. Or at least clean and separate protocol
handling that updates a core state machine. That state machine might need some form of meta-data arrangement as per
connection.

Without something of this ilk the downloader state machine will get larger and more complex - is that healthy? Can
we break it down some more?

Choke Algorithm
===============

See below for the formal description. Note that this explanation does not cover those we download
from that are not interested. In essence, we take a max of 4 remote peers with rates faster than
our interesteds and run them alongside the interested ones. This balances our upload and download
bandwidth causing us to share heavily before downloading. Note also there is explanation in
the original spec for the case where one of these uninterested peers becomes interested. All that's
being said is that come next run of the choke, this peer is likely high enough rated that it'll bump
off one of the others.

The choke algorithm differs in leecher and seed states. We
describe first the choke algorithm in leecher state. At most
4 remote peers can be unchoked and interested at the same
time. Peers are unchoked using the following policy.

1. Every 10 seconds, the interested remote peers are or-
dered according to their download rate to the local
peer and the 3 fastest peers are unchoked.
2. Every 30 seconds, one additional interested remote
peer is unchoked at random. We call this random un-
choke the optimistic unchoke.

In the following, we call the three peers unchoked in step 1
the regular unchoked (RU) peers, and the peer unchoked in
step 2 the optimistic unchoked (OU) peer. The optimistic
unchoke peer selection has two purposes. It allows to evalu-
ate the download capacity of new peers in the peer set, and
it allows to bootstrap new peers that do not have any piece
to share by giving them their first piece.

We describe now the choke algorithm in seed state. In
previous versions of the BitTorrent protocol, the choke algo-
rithm was the same in leecher state and in seed state except
that in seed state the ordering performed in step 1 was based
on upload rates from the local peer. With this algorithm,
peers with a high download rate are favored independently
of their contribution to the torrent.

Starting with version 4.0.0, the mainline client [2] intro-
duced an entirely new algorithm in seed state. We are not
aware of any documentation on this new algorithm, nor of
any implementation of it apart from the mainline client.
We describe this new algorithm in seed state in the follow-
ing. At most 4 remote peers can be unchoked and interested
at the same time. Peers are unchoked using the following
policy.

1. Every 10 seconds, the unchoked and interested remote
peers are ordered according to the time they were last
unchoked, most recently unchoked peers first.
2. For two consecutive periods of 10 seconds, the 3 first
peers are kept unchoked and an additional 4th peer
that is choked and interested is selected at random
and unchoked.
3. For the third period of 10 seconds, the 4 first peers are
kept unchoked.

In the following, we call the three or four peers that are
kept unchoked according to the time they were last unchoked
the seed kept unchoked (SKU) peers, and the unchoked peer
selected at random the seed random unchoked (SRU) peer.
With this new algorithm, peers are no longer unchoked ac-
cording to their upload rate from the local peer, but accord-
ing to the time of their last unchoke. As a consequence, the
peers in the active peer set are changed regularly, each new
SRU peer taking an unchoke slot o® the oldest SKU peer.
We show in section 4.2.1 why the new choke algorithm
in seed state is fundamental to the fairness of the choke
algorithm.

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
	DOWNLOADED = 12
	UPLOADED = 13
	ACTIVE_REQUESTS	= 14

	def initialize(scheduler, selector, connection_pool, storage, tracker, metainfo, client_details)
		@metainfo = metainfo
		@scheduler = scheduler
		@tracker_timer = nil
		@choke_timer = nil
		@choker = ChokeAlgo.new(self)
		@selector = selector
		@pool = connection_pool
		@client_details = client_details
		@lock = Mutex.new
		@terminate = false
		@queue = Queue.new
		@storage = storage
		@tracker = tracker
		@tracker_status = Tracker::STATUS_STARTED
		@tracker_interval = -1
		@picker = Picker.new(@metainfo.info.pieces.pieces.length)
		@uploaded = 0
		@downloaded = 0		
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

	def peer_connected?(ip, port)
		exists = false

		@pool.each { |conn|
			addr = conn.remote_address

			if ((addr.ip_address == ip) && (addr.ip_port == port))
				exists = true
			end
		}

		exists
	end

	def ping_tracker
		response = @tracker.ping({Tracker::UPLOADED => @uploaded, Tracker::DOWNLOADED => @downloaded, 
			Tracker::LEFT => (@storage.overall_bytes - @storage.current_bytes),
			Tracker::EVENT => @tracker_status})

		if (@tracker_status == Tracker::STATUS_STOPPED)
			# There will be no more updates
			return
		end

		@tracker_status = Tracker::STATUS_UPDATE

		if (response.code != 200)
			COLLECTOR_LOGGER.warn("Tracker update failed: #{response}")
		else
			tr = Tracker::AnnounceResponse.new(response.body)

			@tracker_interval = tr.interval

			puts tr

			# Actively connect because we need to download?
			#
			if (! @storage.complete?)
				# Start connection for each peer that isn't us (as identified by Socket)
				my_addresses = Socket.ip_address_list.map { |addr| addr.ip_address}

				tr.peers.each { |peer|
					if ((! ((my_addresses.include?(peer.ip.ip_address) && (peer.port == @client_details.port)))) &&
						(! peer_connected?(peer.ip.ip_address, peer.port)))
						update(Peer.new(peer.id, peer.ip.ip_address, peer.port))
					end
				}
			end			
		end

		if (@tracker_interval != -1)
			TRACKER_LOGGER.debug("Tracker will next be pinged @ #{@tracker_interval}")

			@tracker_timer = @scheduler.add { |timers| timers.after(@tracker_interval) {
				update(UpdateTracker.new)
			}}
		else
			TRACKER_LOGGER.debug("Tracker will next be pinged @ 300")

			@tracker_timer = @scheduler.add { |timers| timers.after(300) {
				update(UpdateTracker.new)
			}}
		end
	end

	def run
		Thread.current.abort_on_exception = true

		puts "Sharing: #{@metainfo.info.sha1_hash.unpack("H*")} #{@metainfo.info.pieces.pieces.length} pieces of length #{@metainfo.info.pieces.piece_length}"
		puts "#{@metainfo.info.directory}"
		puts "I am #{@client_details.peer_id}"

		@tracker_timer = @scheduler.add { |timers| timers.after(5) {
			update(UpdateTracker.new)
		}}

		@choke_timer = @scheduler.add { |timers| timers.every(10) {
			update(@choker)
		}}		

		until terminate? do
			process(@queue.deq)			
		end

		@tracker_timer.cancel
		@tracker_status = Tracker::STATUS_STOPPED
		ping_tracker
	end

	def process(message)
		case message
		
		when ChokeAlgo
		
		when KeepAlive

		else
			COLLECTOR_LOGGER.debug("Message: #{message}")
		end

		case message
		
		when :poison

			COLLECTOR_LOGGER.info("Exiting downloader")
			return

		when ChokeAlgo
			CHOKER_LOGGER.debug("Current stats: #{@downloaded}, #{@uploaded}")
			@pool.each { |conn| 
				up = conn.metadata { |meta| meta[UPLOADED] }
				down = conn.metadata { |meta| meta[DOWNLOADED] }
				pchoked = conn.metadata { |meta| meta[PEER_CHOKED] }
				achoked = conn.metadata { |meta| meta[AM_CHOKED] }

				CHOKER_LOGGER.debug("Conn: #{conn} #{down} #{up} #{pchoked} #{achoked}")
			}

			@choker.run(@pool, @storage.complete?)

		when UpdateTracker
			ping_tracker

		when ChokePeer
			message.connection.metadata { |meta| meta[PEER_CHOKED] = true }
			message.connection.send(Choke.new.implode)
			message.connection.metadata { |meta| meta[ACTIVE_REQUESTS] = [] }

		when UnchokePeer
			message.connection.metadata { |meta| meta[PEER_CHOKED] = false }
			message.connection.send(Unchoke.new.implode)

		when Peer
			begin
				socket = TCPSocket.new(message.ip, message.port)

				conn = Connection.new(socket, Connection::SEND_HANDSHAKE, @metainfo.info.sha1_hash, @selector, @client_details.peer_id)
				conn.metadata { |meta| 
					meta[MODE] = CLIENT
					meta[AM_CHOKED] = true
					meta[AM_INTERESTED] = false
					meta[PEER_CHOKED] = true
					meta[PEER_INTERESTED] = false
					meta[ACTIVE_REQUESTS] = []
					meta[UPLOADED] = 0
					meta[DOWNLOADED] = 0
				}

				conn.add_observer(self)
				@pool.add(conn)
				conn.start

			rescue => e
				COLLECTOR_LOGGER.warn("Failed to connect #{message.ip} #{message.port} #{e.message} #{e.backtrace}")
			end

		when Client
			conn = Connection.new(message.socket, Connection::HANDSHAKE_WAIT, @metainfo.info.sha1_hash, @selector, @client_details.peer_id)
			conn.metadata { |meta| 
				meta[MODE] = SERVER
				meta[AM_CHOKED] = true
				meta[AM_INTERESTED] = false
				meta[PEER_CHOKED] = true
				meta[PEER_INTERESTED] = false
				meta[ACTIVE_REQUESTS] = []
				meta[UPLOADED] = 0
				meta[DOWNLOADED] = 0
			}

			conn.add_observer(self)
			@pool.add(conn)
			conn.start	

		when Handshake
			conn = message.connection

			if (@metainfo.info.sha1_hash == message.info_hash)
				COLLECTOR_LOGGER.debug("Valid #{message}")

				# We ought to send a have to a peer so long as there's been a handshake.
				# We may receive a bitfield or we may never (for a base protocol client) and denying
				# it haves would be wrong (especially as that might prompt an upload to that peer).
				# So when we see it's handshake, we initialise it's available to the empty bitset 
				# until we see otherwise.
				#
				conn.metadata { |meta| meta[BITFIELD] = Bitset.new(@metainfo.info.pieces.pieces.length).fill(0)}

				conn.send(Bitfield.new.implode(@storage.got))

				# TODO: Restore keepalive, make it happen only after periods of silence
				#
				#t = @scheduler.add { |timers| timers.every(20) {
				#		conn.send(KeepAlive.new.implode)
				#	}}

				conn.metadata { |meta| 
					# meta[TIMER] = t
				}
			else
				COLLECTOR_LOGGER.warn("Invalid handshake #{message}")
				conn.close 
				@pool.remove(conn)
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

			if (! conn.metadata { |meta| meta[AM_INTERESTED] })
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

		when PieceCompleted
			conn = message.connection
			piece = message.piece

			if (@storage.complete?)
				@tracker_status = Tracker::STATUS_COMPLETED

				COLLECTOR_LOGGER.info("Download completed")
			end

			if (message.success)

				# Send out not interested to anyone that can't supply us, also update our AM_INTERESTED
				# Send out have to any connections that are missing the piece we got
				#
				outstanding = @storage.needed

				@pool.each { |c| 
					available = c.metadata { |meta| meta[BITFIELD] }

					# If we're interested that can only be because we've seen a HAVE or BITFIELD which means no null check
					# of available is required.
					#
					if (c.metadata { |meta| meta[AM_INTERESTED] })
						if ((@storage.complete?) || (! available.and(outstanding).nonZero))
							c.metadata { |meta| meta[AM_INTERESTED] = false }
							c.send(NotInterested.new.implode)
						end
					end

					# In this general case, we have no guarantee we got a handshake on this connection.
					#
					if (available != nil)
						if (available.get(piece) == 0)
							c.send(Have.new.implode(piece))
						end
					end
				}
			else
				COLLECTOR_LOGGER.warn("Failed piece #{piece} on #{conn}")
			end

			clear_requests(conn)

			start_streaming(conn)

		when Piece
			conn = message.connection					
			piece = conn.metadata { |meta| meta[PIECE] }
			data = message.block

			if (piece == nil)
				COLLECTOR_LOGGER.warn("Unexpected piece - dropped #{conn}")
			else
				if (piece != message.index)
					raise "Requested piece doesn't match piece in message #{piece} #{message.index}"
				end

				blocks = conn.metadata { |meta| meta[BLOCKS] }
				current_block = blocks.take(1).flatten
				remaining_blocks = blocks.drop(1)

				@storage.save_block(piece, current_block, data)
				@downloaded += message.block.length

				conn.metadata { |meta|
					meta[DOWNLOADED] += message.block.length
				}

				if (remaining_blocks.length == 0)
					@storage.piece_complete(piece) { | success | 
						@queue.enq(PieceCompleted.new(conn, piece, success)) }
				else
					conn.metadata { |meta| meta[BLOCKS] = remaining_blocks }

					if (wouldSend(conn))
						range = remaining_blocks.take(1).flatten
						COLLECTOR_LOGGER.debug("Next block #{piece} #{range}")
						conn.send(Request.new.implode(piece, range[0], range[1]))
					end
				end
			end

		when PieceReady
			conn = message.connection

			# Ensure this request is still active
			found = conn.metadata { | meta |
				meta[ACTIVE_REQUESTS].reject! { | req | 
					if (req[0] == message.piece && req[1] == message.offset)
						true
					else
						false
					end
				}
			}

			if (! found)
				COLLECTOR_LOGGER.warn("Dump request, it's been cancelled #{message.piece} #{message.offset} #{conn.metadata { |meta| meta[ACTIVE_REQUESTS]}}")
			else
				if (conn.metadata { |meta| meta[PEER_CHOKED] })
					COLLECTOR_LOGGER.warn("Dumping request for choking peer #{conn}")
				else
					conn.send(Piece.new.implode(message.piece, message.offset, message.buffer))
					conn.metadata { |meta| meta[UPLOADED] += message.buffer.length}
					@uploaded += message.buffer.length
				end
			end

		when Request

			conn = message.connection

			if (conn.metadata { |meta| meta[PEER_CHOKED] })
				COLLECTOR_LOGGER.warn("Dropping message from choked peer #{conn}")
				raise "Consistency problem"
			else
				# Record the request
				conn.metadata { | meta | meta[ACTIVE_REQUESTS] << [message.index, message.start] 
					COLLECTOR_LOGGER.debug("Recording request #{meta[ACTIVE_REQUESTS]}")							
				}

				@storage.read_block(message.index, [message.start, message.length]) { |buffer|
					@queue.enq(PieceReady.new(conn, message.index, message.start, buffer))
				}
			end

		when KeepAlive

			# TODO: Ought to track connection liveness

		when Cancel

			conn.metadata { | meta |
				meta[ACTIVE_REQUESTS].reject! { | req | 
					if (req[0] == message.index && req[1] == message.start)
						true
					else
						false
					end
				}
			}

		when Closed
			COLLECTOR_LOGGER.warn("Connection closed: #{conn}")

			conn = message.connection

			@pool.remove(conn)

			t = conn.metadata { |meta| meta[TIMER] }
			t.cancel unless (t == nil)

			bitmap = conn.metadata { |meta| meta[BITFIELD] }
			@picker.unavailable(bitmap) unless (bitmap == nil)

			clear_requests(conn)

		else
			COLLECTOR_LOGGER.warn("Unprocessed message: #{message}")
		end
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
			COLLECTOR_LOGGER.debug("Would stream but inhibited")
			return
		end

		if ((conn.metadata { |meta| meta[PIECE] }) != nil)
			raise "In-flight request shouldn't be present"
		end

		piece = @picker.next_piece(@storage.needed, conn.metadata { |meta| meta[BITFIELD] })

		if (piece == nil)
			COLLECTOR_LOGGER.debug("No piece I can get")
			return
		end

		blocks = @storage.blocks(piece)
		COLLECTOR_LOGGER.debug("Selected piece: #{piece} #{blocks}")

		conn.metadata { |meta|
			meta[PIECE] = piece
			meta[BLOCKS] = blocks
		}

		range = blocks.take(1).flatten
		conn.send(Request.new.implode(piece, range[0], range[1]))
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

	class UpdateTracker
	end

	class PieceReady
		attr_reader :connection, :piece, :offset, :buffer

		def initialize(conn, piece, offset, buffer)
			@connection = conn
			@piece = piece
			@buffer = buffer
			@offset = offset
		end

		def to_s
			"Piece Ready: #{piece} #{offset} #{buffer.length} #{connection}"
		end
	end

	class PieceCompleted
		attr_reader :connection, :piece, :success

		def initialize(conn, piece, success)
			@connection = conn
			@piece = piece
			@success = success
		end
	end

	class ChokePeer
		attr_reader :connection

		def initialize(conn)
			@connection = conn
		end
	end

	class UnchokePeer
		attr_reader :connection

		def initialize(conn)
			@connection = conn
		end
	end

	class ChokeAlgo		
		def initialize(collector)
			@collector = collector
			@quantum = 0
		end

		def run(pool, complete)

			CHOKER_LOGGER.debug("Choke::run #{pool} #{complete}")

			@quantum +=1

			rated = SortedSet.new
			pool.each { |conn| rated << ConnectionComparator.new(conn, (complete) ? Collector::UPLOADED : Collector::DOWNLOADED) }

			uninterested = []
			interested = []

			rated.each { | c | 

				# Once we've found our first interested, there can be no more uninterested peers
				#
				if (c.connection.metadata { |meta| meta[PEER_INTERESTED] })
					interested << c.connection
				else
					uninterested << c.connection
				end
			}

			CHOKER_LOGGER.debug("Rated: #{rated} Interested: #{interested} Uninterested: #{uninterested}")

			if (@quantum == 3)
				@quantum = 0
				if (interested.length > 3)
					interested = interested.slice!(0, 3) << interested[ Random.new.rand(interested.length) ]
				else
					interested = interested.slice(0, 3)
				end
			else
				interested = interested.slice(0, 3)
			end

			uninterested = uninterested.slice(0, 3)

			CHOKER_LOGGER.debug("Chosen - Interested: #{interested} Uninterested: #{uninterested}")
			rated.each { | c | 
				if ((! interested.include?(c.connection)) && (! uninterested.include?(c.connection)))
					choke(c.connection)
				else
					unchoke(c.connection)
				end
			}
		end

		def choke(c)
			if (! c.metadata { |meta| meta[PEER_CHOKED] })
				CHOKER_LOGGER.debug("Choking: #{c}")

				@collector.update(ChokePeer.new(c))
			end
		end

		def unchoke(c)
			if (c.metadata { |meta| meta[PEER_CHOKED] })
				CHOKER_LOGGER.debug("Unchoking: #{c}")

				@collector.update(UnchokePeer.new(c))
			end
		end

		class ConnectionComparator
			include Comparable

			attr_reader :connection

			def initialize(conn, field)
				@connection = conn
				@field = field
			end

			def <=>(another_comparator)
				mine = connection.metadata { |meta| meta[@field] }
				other = another_comparator.connection.metadata { |meta| meta[@field] }

				if (mine < other)
					-1
				elsif (mine > other)
					1
				else
					0
				end						
			end
		end
	end
end


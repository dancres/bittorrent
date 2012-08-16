require 'thread'
require 'socket'
require 'logger'
require_relative 'tracker.rb'
require_relative 'selector.rb'
require_relative 'btproto.rb'
require_relative 'storage.rb'

class Downloader

	def initialize(metainfo, tracker, client_details)
		@meta = metainfo
		@tracker = tracker
		@client_details = client_details
		@core = Core.new(client_details)
	end

	def run
		response = @tracker.ping({Tracker::UPLOADED => 0, Tracker::DOWNLOADED => 0, 
			Tracker::LEFT => @meta.info.directory.files[0].length,
			Tracker::EVENT => Tracker::STATUS_STARTED})

		puts response

		if (response.code == 200)
			puts "Good - going to pull: #{@meta.info.sha1_hash.unpack("H*")} #{@meta.info.pieces.pieces.length} pieces of length #{@meta.info.pieces.piece_length}"

			tr = Tracker::AnnounceResponse.new(response.body)

			puts tr

			collector = Collector.new(@core.selector, @meta, @client_details)

			# Start connection for each peer that isn't us (as identified by Socket)
			my_addresses = Socket.ip_address_list.map { |addr| addr.ip_address}

			tr.peers.each { |peer|
				if (! ((my_addresses.include?(peer.ip.ip_address) && (peer.port == @client_details.port))))
					collector.update(Collector::Peer.new(peer.id, peer.ip.ip_address, peer.port))
				end
			}

			collector.wait_for_exit
		else
			puts "Bad #{response.code}"
			return
		end
	end	
end

class Core
	attr_reader :selector, :serversocket, :client_details

	def initialize(client_details)
		@selector = Selector.new
		@client_details = client_details
		@serversocket = TCPServer.new(client_details.port)
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

We should now add support for bitfields - catching others and sending ours (Have messages can maybe wait)
We'll also need to handle choke, unchoke, interested and uninterested - catching others and sending ours
Picking and block request streaming (which will be one piece broken into blocks per connection - use meta-data?)

=end

class Collector
	MODE = 1
	CLIENT = 2
	PEER_CHOKED = 3
	AM_CHOKED = 4
	PEER_INTERESTED = 5
	AM_INTERESTED = 6
	BITFIELD = 7

	def initialize(selector, metainfo, client_details)
		@logger = Logger.new(STDOUT)
		@logger.level = Logger::DEBUG
		formatter = Logger::Formatter.new
			@logger.formatter = proc { |severity, datetime, progname, msg|
		    	formatter.call(severity, datetime, progname, msg.dump)
			} 				
		@selector = selector
		@metainfo = metainfo
		@client_details = client_details
		@lock = Mutex.new
		@terminate = false
		@queue = Queue.new
		@queue_thread = Thread.new { run }
		@storage = Storage.new(@metainfo.info.pieces.pieces.length)
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

		until terminate? do
			message = @queue.deq
			@logger.debug("Message: #{message}")

			if (! terminate?)
				case message
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
					conn.start	

				when Handshake
					conn = message.connection

					if (@metainfo.info.sha1_hash == message.info_hash)
						@logger.debug("Valid #{message}")

						if ((conn.metadata { |meta| meta[MODE]}) == CLIENT)
							conn.send(Bitfield.new.implode(@storage.got))
						end
					else
						@logger.warn("Invalid #{message}")
						conn.close 
					end

				when Bitfield
					conn = message.connection

					b = Bitset.new(@metainfo.info.pieces.pieces.length).from_binary(message.bitfield)

					conn.metadata { |meta| meta[BITFIELD] = b }

					# TODO - declare interest, start sending requests if we're not choked
					if (b.and(@storage.needed).nonZero)
						conn.metadata { |meta| meta[AM_INTERESTED] = true }
						conn.send(Interested.new.implode)

						if (wouldSend(conn))
							start_streaming(conn)
						end
					end

				when Unchoke

					conn = message.connection
					conn.metadata { |meta| meta[AM_CHOKED] = false}

					if (wouldSend(conn))
						start_streaming(conn)
					end

				when KeepAlive

				when Closed

					# CLEANUP
				else
					puts "Unprocessed message: #{message}"
				end
			end
		end
	end

	def wouldSend(conn)
		conn.metadata { |meta| (!meta[AM_CHOKED] && meta[AM_INTERESTED])}
	end

	def start_streaming(conn)
		@logger.debug("Streaming requests on #{conn}")
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
end


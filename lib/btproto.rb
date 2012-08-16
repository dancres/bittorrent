require_relative 'selector.rb'
require 'observer'
require 'logger'

class Connection < Handler
	include Observable

	attr_reader :state

	# Use this state to start a server socket
	#
	HANDSHAKE_WAIT = -2
	HANDSHAKE_RCVD = -1

	# Use this state to start a client socket
	#
	SEND_HANDSHAKE = 1
	HANDSHAKE_SENT = 2
	OPEN = 3
	CLOSED = 4

	def initialize(socket, initial_state, hash, selector, peer_id)
		@info_hash = hash
		@peer_id = peer_id
		@selector = selector
		@lock = Mutex.new
		@socket = socket
		@socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
		@queue = []
		@state = initial_state
		@warden = nil
		@buffer = ""
		@metadata = {}
	    @logger = Logger.new(STDOUT)
	    @logger.level = Logger::INFO
	    formatter = Logger::Formatter.new
	      @logger.formatter = proc { |severity, datetime, progname, msg|
	        formatter.call(severity, datetime, progname, msg.dump)
	      }		
	end

	def start	
		@lock.synchronize {
			process(nil)
		}
	end

	def metadata(&block)
		@lock.synchronize {
			block.call(@metadata)
		}
	end

	def io
		@socket
	end

	def interests
		@lock.synchronize {
			@interests
		}
	end

	def process(msg)
		case @state
		when SEND_HANDSHAKE

			@queue.insert(
				0, 
				Handshake.new.implode(@info_hash, @peer_id)
				)

			@interests = "rw"
			@warden = HandshakeWarden.new
			@state = HANDSHAKE_SENT
			@selector.add(self)

		when HANDSHAKE_SENT
			handshake = Unpacker.explode_handshake(self, msg)
			@state = OPEN
			@warden = OpenWarden.new
			@interests = "r"

			changed
			notify_observers(handshake)

		when OPEN
			len = msg.slice(0, 4).unpack("N")[0]

			@logger.debug("Conn: Message arrived with length #{len}")

			exploded = Unpacker.explode(self, msg)

			changed
			notify_observers(exploded)

		when CLOSED
			@logger.info("Channel closed -- cleanup #{self}")
			@interests = nil
			@queue = []
			@socket.close

			changed
			notify_observers(Closed.new(self))
		else
			@logger.error("Unknown state :( #{@state}")
		end
	end

	def close
		@logger.debug("Closing #{self}")
		@lock.synchronize {
			@state = CLOSED
			process(nil)
		}
	end

	def send(message)
		@logger.debug("Sending: #{message.unpack("H*")}")
		@lock.synchronize {
			@interests = "rw"
			@queue.insert(0, message)
		}
	end

	def read
		@logger.debug("In read")
		@lock.synchronize {
			begin
				@buffer << @socket.read_nonblock(1520)

				consumption = @warden.consume(@buffer)
				if (consumption != 0)
					message = @buffer.slice!(0, consumption)
					process(message)
				end
			rescue IO::WaitReadable
				@logger.warn("Read failed")
			rescue EOFError
				@state = CLOSED
				process(nil)
			end
		}
	end

	def write
		@lock.synchronize {
			if (@queue.length != 0)
				data = @queue.pop

				@logger.debug("Attempting send of: #{data.unpack("H*")}")

				begin
					bytes = @socket.write_nonblock(data)
					if (bytes != data.length)
						# Some didn't go
						data.slice!(0, bytes)
						@queue.insert(0)
					end
				rescue IO::WaitWritable
					# data never out the door, put it back
					#
					@logger.warn("Write failed")
					@data.insert(0)
				end
			else
				@interests = "r"
			end
		}
	end
end

class HandshakeWarden
	def consume(buffer)
		desired = 1 + buffer.unpack("C*")[0] + 8 + 20 + 20

		if (buffer.length >= desired)
			return desired
		else
			return 0
		end
	end
end

class OpenWarden
	def consume(buffer)
		desired = 4 + buffer.slice(0, 4).unpack("N")[0]

		if (buffer.length >= desired)
			return desired
		else
			return 0
		end
	end
end

class Unpacker
	def self.explode_handshake(conn, msg) 
		Handshake.new.explode(conn, msg)
	end

	def self.explode(conn, msg)
		len = msg.slice(0, 4).unpack("N")[0]

		if (len == 0)
			KeepAlive.new.explode(conn)
		else
			id = msg.slice(4, 1).unpack("c")[0]

			case id
			when 0
				Choke.new.explode(conn)
			when 1
				Unchoke.new.explode(conn)
			when 2
				Interested.new.explode(conn)
			when 3
				NotInterested.new.explode(conn)
			when 4
				Have.new.explode(conn, msg.slice(5, msg.length - 5))
			when 5
				Bitfield.new.explode(conn, msg.slice(5, msg.length - 5))
			when 6
				Request.new.explode(conn, msg.slice(5, msg.length - 5))
			when 7
				Piece.new.explode(conn, msg.slice(5, msg.length - 5))
			when 8
				Cancel.new.explode(conn, msg.slice(5, msg.length - 5))
			when 9
				Port.new.explode(conn, msg.slice(5, msg.length - 5))
			else
				raise ArgumentError("Unknown message: #{id}")
			end
		end
	end
end

class Closed
	attr_reader :connection

	def initialize(conn)
		@connection = conn
	end

	def to_s
		"Closed: #{connection}"
	end
end

class Handshake
	attr_reader :protocol, :extensions, :info_hash, :peer_id, :connection
	
	def initialize
		@len = [19]
		@protocol = "BitTorrent protocol"
		@extensions = "\x00\x00\x00\x00\x00\x00\x00\x00"
	end

	def explode(conn, msg)
		len = msg.unpack("C")[0]
		@protocol = msg.slice(1, len)
		@extensions = msg.slice(1 + len, 8)
		@info_hash = msg.slice(1 + len + 8, 20)
		@peer_id = msg.slice(1 + len + 8 + 20, 20)
		@connection = conn
		self
	end

	def implode(info_hash, peer_id)
		@info_hash = info_hash
		@peer_id = peer_id
		"#{@len.pack("C")}#{@protocol}#{@extensions}#{@info_hash}#{@peer_id}"		
	end

	def to_s
		"Handshake: #{protocol} #{extensions.unpack("B*")} #{info_hash.unpack("H*")} #{peer_id.unpack("H*")}"
	end
end

class KeepAlive
	attr_reader :id, :connection

	def explode(conn)
		@id = -1
		@connection = conn
		self
	end

	def to_s
		"KeepAlive"
	end
end

class Choke
	attr_reader :id, :connection

	def explode(conn)
		@id = 0
		@connection = conn
		self
	end

	def to_s
		"Choke"
	end
end

class Unchoke
	attr_reader :id, :connection

	def explode(conn)
		@id = 1
		@connection = conn
		self
	end

	def to_s
		"Unchoke"
	end
end

class Interested
	attr_reader :id, :connection

	def initialize
		@id = 2
	end

	def explode(conn)
		@connection = conn
		self
	end

	def implode
		"#{[1].pack("N")}#{[@id].pack("C*")}"		
	end

	def to_s
		"Interested"
	end
end

class NotInterested
	attr_reader :id, :connection

	def explode(conn)
		@id = 3
		@connection = conn
		self
	end

	def to_s
		"NotInterested"
	end
end

class Have
	attr_reader :id, :index, :connection

	def explode(conn, content)
		@id = 4
		@index = content.unpack("N")[0]
		@connection = conn
		self
	end

	def to_s
		"Have #{index}"
	end
end

class Bitfield
	attr_reader :id, :bitfield, :connection

	def initialize
		@id = 5
	end

	def explode(conn, content)
		@bitfield = content
		@connection = conn
		self
	end

	def implode(bitset)
		packed = bitset.to_binary
		len = [(1 + packed.length)]
		"#{len.pack("N")}#{[@id].pack("C*")}#{packed}"
	end

	def to_s
		"Bitfield: #{bitfield.unpack("B*")}"
	end
end

class Request
	attr_reader :id, :index, :start, :length, :connection

	def explode(conn, content)
		@id = 6
		@index, @start, @length = content.unpack("N*")
		@connection = conn
		self
	end

	def to_s
		"Request: #{index} #{start} #{length}"
	end
end

class Piece
	attr_reader :id, :index, :start, :block, :connection

	def explode(conn, content)
		@id = 7
		@index, @start = content.slice(0, 8).unpack("N*")
		@block = content.slice(8, content.length - 8)
		@connection = conn
		self
	end

	def to_s
		"Piece: #{index} #{start}"
	end
end

class Cancel
	attr_reader :id, :index, :start, :length, :connection

	def explode(conn, content)
		@id = 8
		@index, @start, @length = content.unpack("N*")
		@connection = conn
		self
	end

	def to_s
		"Cancel: #{index} #{start} #{length}"
	end
end

class Port
	attr_reader :id, :port, :connection

	def explode(conn, content)
		@id = 9
		@port = content.unpack("N")[0]
		@connection = conn
		self
	end

	def to_s
		"Port: #{port}"
	end
end

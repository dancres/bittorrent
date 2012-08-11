require './io.rb'
require 'observer'

class Connection < Handler
	include Observable

	# Use this state to start a server socket
	#
	HANDSHAKE_WAIT = -2
	HANDSHAKE_RCVD = -1

	# Use this state to start a client socket
	#
	SEND_HANDSHAKE = 1
	HANDSHAKE_SENT = 2
	OPEN = 3

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
		@metadata = []

		@lock.synchronize {
			process(nil)
		}
	end

	def metadata(&block)
		@lock.synchronize {
			block.call(metadata)
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
			puts "Queuing handshake[client]"

			@queue.insert(
				0, 
				"\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00#{@info_hash}#{@peer_id}"
				)

			@interests = "rw"
			@warden = HandshakeWarden.new
			@state = HANDSHAKE_SENT
			@selector.add(self)

		when HANDSHAKE_SENT
			handshake = Unpacker.explode_handshake(self, msg)
			puts "Handshake received[client]: #{handshake}"	

			@state = OPEN
			@warden = OpenWarden.new
			@interests = "r"

			notify_observers(handshake)

		when OPEN
			len = msg.slice(0, 4).unpack("N")[0]
			id = msg.slice(4, 1).unpack("c")[0]

			puts "Got a message: #{len} #{id} #{msg.unpack("H*")}"
			
			exploded = Unpacker.explode(self, msg)
			puts "Unpacked: #{exploded}"

			notify_observers(exploded)

		else
			puts "Unknown state :( #{@state}"
		end
	end

	def read
		puts "In read"
		@lock.synchronize {
			begin
				@buffer << @socket.read_nonblock(1520)

				puts "Buffer: #{@buffer.unpack("H*")}"

				consumption = @warden.consume(@buffer)
				if (consumption != 0)
					message = @buffer.slice!(0, consumption)
					process(message)
				end
			rescue IO::WaitReadable
				puts "Read failed"
			end
		}
	end

	def write
		@lock.synchronize {
			if (@queue.length != 0)
				puts "Writing from queue"

				data = @queue.pop

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
					puts "Write failed"
					@data.insert(0)
				end
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
		Handshake.new(conn, msg)
	end

	def self.explode(conn, msg)
		len = msg.slice(0, 4).unpack("N")[0]

		if (len == 0)
			KeepAlive.new
		else
			id = msg.slice(4, 1).unpack("c")[0]

			case id
			when 0
				Choke.new(conn)
			when 1
				Unchoke.new(conn)
			when 2
				Interested.new(conn)
			when 3
				NotInterested.new(conn)
			when 4
				Have.new(conn, msg.slice(5, msg.length - 5))
			when 5
				Bitfield.new(conn, msg.slice(5, msg.length - 5))
			when 6
				Request.new(conn, msg.slice(5, msg.length - 5))
			when 7
				Piece.new(conn, msg.slice(5, msg.length - 5))
			when 8
				Cancel.new(conn, msg.slice(5, msg.length - 5))
			when 9
				Port.new(conn, msg.slice(5, msg.length - 5))
			else
				puts "Unknown message: #{id}"
			end
		end
	end
end

class Handshake
	attr_reader :protocol, :extensions, :info_hash, :peer_id, :connection

	def initialize(conn, msg)
		len = msg.unpack("C")[0]
		@protocol = msg.slice(1, len)
		@extensions = msg.slice(1 + len, 8)
		@info_hash = msg.slice(1 + len + 8, 20)
		@peer_id = msg.slice(1 + len + 8 + 20, 20)
		@connection = conn
	end

	def to_s
		"Handshake: #{protocol} #{extensions.unpack("B*")} #{info_hash.unpack("H*")} #{peer_id.unpack("H*")}"
	end
end

class KeepAlive
	attr_reader :id, :connection

	def initialize(conn)
		@id = -1
		@connection = conn
	end

	def to_s
		"KeepAlive"
	end
end

class Choke
	attr_reader :id, :connection

	def initialize(conn)
		@id = 0
		@connection = conn
	end

	def to_s
		"Choke"
	end
end

class Unchoke
	attr_reader :id, :connection

	def initialize(conn)
		@id = 1
		@connection = conn
	end

	def to_s
		"Unchoke"
	end
end

class Interested
	attr_reader :id, :connection

	def initialize(conn)
		@id = 2
		@connection = conn
	end

	def to_s
		"Interested"
	end
end

class NotInterested
	attr_reader :id, :connection

	def initialize(conn)
		@id = 3
		@connection = conn
	end

	def to_s
		"NotInterested"
	end
end

class Have
	attr_reader :id, :index, :connection

	def initialize(conn, content)
		@id = 4
		@index = content.unpack("N")[0]
		@connection = conn
	end

	def to_s
		"Have #{index}"
	end
end

class Bitfield
	attr_reader :id, :bitfield, :connection

	def initialize(conn, content)
		@id = 5
		@bitfield = content
		@connection = conn
	end

	def to_s
		"Bitfield: #{bitfield.unpack("B*")}"
	end
end

class Request
	attr_reader :id, :index, :start, :length, :connection

	def initialize(conn, content)
		@id = 6
		@index, @start, @length = content.unpack("N*")
		@connection = conn
	end

	def to_s
		"Request: #{index} #{start} #{length}"
	end
end

class Piece
	attr_reader :id, :index, :start, :block, :connection

	def initialize(conn, content)
		@id = 7
		@index, @start = content.slice(0, 8).unpack("N*")
		@block = content.slice(8, content.length - 8)
		@connection = conn
	end

	def to_s
		"Piece: #{index} #{start}"
	end
end

class Cancel
	attr_reader :id, :index, :start, :length, :connection

	def initialize(conn, content)
		@id = 8
		@index, @start, @length = content.unpack("N*")
		@connection = conn
	end

	def to_s
		"Cancel: #{index} #{start} #{length}"
	end
end

class Port
	attr_reader :id, :port, :connection

	def initialize(conn, content)
		@id = 9
		@port = content.unpack("N")[0]
		@connection = conn
	end

	def to_s
		"Port: #{port}"
	end
end

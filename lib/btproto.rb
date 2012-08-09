require './io.rb'

class Connection < Handler
	# Use this state to start a server socket
	#
	HANDSHAKE_WAIT = -2
	HANDSHAKE_RCVD = -1

	# Use this state to start a client socket
	#
	SEND_HANDSHAKE = 1
	HANDSHAKE_SENT = 2
	OPEN = 3

	def initialize(socket, initial_state, meta, core)
		@metainfo = meta
		@core = core
		@lock = Mutex.new
		@socket = socket
		@socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
		@queue = []
		@state = initial_state
		@warden = nil
		@buffer = ""

		@lock.synchronize {
			process(nil)
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
				"\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00#{@metainfo.info.sha1_hash}#{@core.client_details.peer_id}"
				)

			@interests = "rw"
			@warden = HandshakeWarden.new
			@state = HANDSHAKE_SENT
			@core.selector.add(self)

		when HANDSHAKE_SENT
			puts "Handshake received[client]: #{Unpacker.explode_handshake(msg)}"	

			@state = OPEN
			@warden = OpenWarden.new
			@interests = "r"

		when OPEN
			len = msg.slice(0, 4).unpack("N")[0]
			id = msg.slice(4, 1).unpack("c")[0]

			puts "Got a message: #{len} #{id} #{msg.unpack("H*")}"
			
			puts "Unpacked: #{Unpacker.explode(msg)}"
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
	def self.explode_handshake(msg) 
		Handshake.new(msg)
	end

	def self.explode(msg)
		len = msg.slice(0, 4).unpack("N")[0]

		if (len == 0)
			KeepAlive.new
		else
			id = msg.slice(4, 1).unpack("c")[0]

			case id
			when 0
				Choke.new
			when 1
				Unchoke.new
			when 2
				Interested.new
			when 3
				NotInterested.new
			when 4
				Have.new(msg.slice(5, msg.length - 5))
			when 5
				Bitfield.new(msg.slice(5, msg.length - 5))
			when 6
				Request.new(msg.slice(5, msg.length - 5))
			when 7
				Piece.new(msg.slice(5, msg.length - 5))
			when 8
				Cancel.new(msg.slice(5, msg.length - 5))
			when 9
				Port.new(msg.slice(5, msg.length - 5))
			else
				puts "Unknown message: #{id}"
			end
		end
	end
end

class Handshake
	attr_reader :protocol, :extensions, :info_hash, :peer_id

	def initialize(msg)
		len = msg.unpack("C")[0]
		@protocol = msg.slice(1, len)
		@extensions = msg.slice(1 + len, 8)
		@info_hash = msg.slice(1 + len + 8, 20)
		@peer_id = msg.slice(1 + len + 8 + 20, 20)
	end

	def to_s
		"Handshake: #{protocol} #{extensions.unpack("B*")} #{info_hash.unpack("H*")} #{peer_id.unpack("H*")}"
	end
end

class KeepAlive
	attr_reader :id

	def initialize
		@id = -1
	end

	def to_s
		"KeepAlive"
	end
end

class Choke
	attr_reader :id

	def initialize
		@id = 0
	end

	def to_s
		"Choke"
	end
end

class Unchoke
	attr_reader :id

	def initialize
		@id = 1
	end

	def to_s
		"Unchoke"
	end
end

class Interested
	attr_reader :id

	def initialize
		@id = 2
	end

	def to_s
		"Interested"
	end
end

class NotInterested
	attr_reader :id

	def initialize
		@id = 3
	end

	def to_s
		"NotInterested"
	end
end

class Have
	attr_reader :id, :index

	def initialize(content)
		@id = 4
		@index = content.unpack("N")[0]
	end

	def to_s
		"Have #{index}"
	end
end

class Bitfield
	attr_reader :id, :bitfield

	def initialize(content)
		@id = 5
		@bitfield = content
	end

	def to_s
		"Bitfield: #{bitfield.unpack("B*")}"
	end
end

class Request
	attr_reader :id, :index, :start, :length

	def initialize(content)
		@id = 6
		@index, @start, @length = content.unpack("N*")
	end

	def to_s
		"Request: #{index} #{start} #{length}"
	end
end

class Piece
	attr_reader :id, :index, :start, :block

	def initialize(content)
		@id = 7
		@index, @start = content.slice(0, 8).unpack("N*")
		@block = content.slice(8, content.length - 8)
	end

	def to_s
		"Piece: #{index} #{start}"
	end
end

class Cancel
	attr_reader :id, :index, :start, :length

	def initialize(content)
		@id = 8
		@index, @start, @length = content.unpack("N*")
	end

	def to_s
		"Cancel: #{index} #{start} #{length}"
	end
end

class Port
	attr_reader :id, :port

	def initialize(content)
		@id = 9
		@port = content.unpack("N")[0]
	end

	def to_s
		"Port: #{port}"
	end
end

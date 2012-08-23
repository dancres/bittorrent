require_relative 'selector.rb'
require_relative '../configure/environment.rb'
require 'observer'

class Acceptor < Handler
	include Observable

	def initialize(selector, server_socket)
		@server_socket = server_socket
		@selector = selector
	end

	def start
		@selector.add(self)
	end

	def io
		@server_socket
	end

	def interests
		"re"
	end

	# TODO: Accept in a loop?
	#
	def read
		CONNECTION_LOGGER.debug("In Accept")

		begin
			client_socket, client_addrinfo = @server_socket.accept_nonblock

			CONNECTION_LOGGER.info("Accepting connection: #{client_socket}, #{client_addrinfo}")

			changed
			notify_observers(Client.new(client_socket))

		rescue IO::WaitReadable
			CONNECTION_LOGGER.warn("Read failed")
		rescue EOFError
			CONNECTION_LOGGER.warn("Server socket has died")
		end
	end	
end

class Client
	attr_reader :socket

	def initialize(s)
		@socket = s
	end
end


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

		when HANDSHAKE_WAIT
			@interests = "r"
			@warden = HandshakeWarden.new
			@state = HANDSHAKE_RCVD
			@selector.add(self)

		when HANDSHAKE_RCVD
			handshake = Unpacker.explode_handshake(self, msg)

			@queue.insert(
				0, 
				Handshake.new.implode(@info_hash, @peer_id)
				)

			@state = OPEN
			@warden = OpenWarden.new
			@interests = "rw"

			changed
			notify_observers(handshake)			

		when OPEN
			len = msg.slice(0, 4).unpack("N")[0]

			CONNECTION_LOGGER.debug("Conn: Message arrived with length #{len}")

			exploded = Unpacker.explode(self, msg)

			changed
			notify_observers(exploded)

		when CLOSED
			CONNECTION_LOGGER.info("Channel closed -- cleanup #{self}")
			@interests = nil
			@queue = []
			@socket.close

			changed
			notify_observers(Closed.new(self))
		else
			CONNECTION_LOGGER.error("Unknown state :( #{@state}")
		end
	end

	def close
		CONNECTION_LOGGER.debug("Closing #{self}")
		@lock.synchronize {
			@state = CLOSED
			process(nil)
		}
	end

	def send(message)
		CONNECTION_LOGGER.debug("Sending: #{message.unpack("H*")}")
		@lock.synchronize {
			@interests = "rw"
			@queue.insert(0, message)
		}
	end

	def read
		CONNECTION_LOGGER.debug("In read")
		@lock.synchronize {
			begin
				@buffer << @socket.read_nonblock(1520)

				consumption = @warden.consume(@buffer)
				if (consumption != 0)
					message = @buffer.slice!(0, consumption)
					process(message)
				end
			rescue IO::WaitReadable
				CONNECTION_LOGGER.warn("Read failed")
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

				CONNECTION_LOGGER.debug("Attempting send of: #{data.unpack("H*")} #{@queue.length}")

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
					CONNECTION_LOGGER.warn("Write failed")
					@data.insert(0)
				end
			else
				@interests = "r"
			end
		}
	end

	def to_s
		"Ctn #{@peer_id.unpack("H*")} hash: #{@info_hash.unpack("H*")}"
	end
end

# TODO: Need to do validation and close connection if handshake is broken
#
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
		"Closed #{connection}"
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
		"Handshake: #{protocol} #{extensions.unpack("B*")} #{info_hash.unpack("H*")} #{peer_id.unpack("H*")} #{connection}"
	end
end

class KeepAlive
	attr_reader :id, :connection

	def explode(conn)
		@id = -1
		@connection = conn
		self
	end

	def implode
		"#{[0].pack("N")}"
	end

	def to_s
		"KeepAlive #{connection}"
	end
end

class Choke
	attr_reader :id, :connection

	def initialize
		@id = 0
	end

	def explode(conn)
		@connection = conn
		self
	end

	def implode
		"#{[1].pack("N")}#{[@id].pack("C*")}"		
	end
	
	def to_s
		"Choke #{connection}"
	end
end

class Unchoke
	attr_reader :id, :connection

	def initialize
		@id = 1
	end

	def explode(conn)
		@connection = conn
		self
	end

	def implode
		"#{[1].pack("N")}#{[@id].pack("C*")}"		
	end

	def to_s
		"Unchoke #{connection}"
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
		"Interested #{connection}"
	end
end

class NotInterested
	attr_reader :id, :connection

	def initialize
		@id = 3
	end

	def explode(conn)
		@connection = conn
		self
	end

	def implode
		"#{[1].pack("N")}#{[@id].pack("C*")}"		
	end

	def to_s
		"NotInterested #{connection}"
	end
end

class Have
	attr_reader :id, :index, :connection

	def initialize
		@id = 4
	end

	def explode(conn, content)
		@index = content.unpack("N")[0]
		@connection = conn
		self
	end

	def implode(piece_index)
		"#{[5].pack("N")}#{[@id].pack("C*")}#{[piece_index].pack("N")}"				
	end

	def to_s
		"Have #{index} #{connection}"
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
		"Bitfield: #{bitfield.unpack("B*")} #{connection}"
	end
end

class Request
	attr_reader :id, :index, :start, :length, :connection

	def initialize
		@id = 6
	end

	def explode(conn, content)
		@index, @start, @length = content.unpack("N*")
		@connection = conn
		self
	end

	def implode(index, start, length)
		"#{[13].pack("N")}#{[@id].pack("C*")}#{[index].pack("N")}#{[start].pack("N")}#{[length].pack("N")}"
	end

	def to_s
		"Request: #{index} #{start} #{length} #{connection}"
	end
end

class Piece
	attr_reader :id, :index, :start, :block, :connection

	def initialize
		@id = 7		
	end

	def explode(conn, content)
		@index, @start = content.slice(0, 8).unpack("N*")
		@block = content.slice(8, content.length - 8)
		@connection = conn
		self
	end

	def implode(piece, offset, data)
		"#{[(9 + data.length)].pack("N")}#{[@id].pack("C*")}#{[piece].pack("N")}#{[offset].pack("N")}#{data}"
	end

	def to_s
		"Piece: #{index} #{start} #{connection}"
	end
end

class Cancel
	attr_reader :id, :index, :start, :length, :connection

	def initialize
		@id = 8
	end

	def explode(conn, content)
		@index, @start, @length = content.unpack("N*")
		@connection = conn
		self
	end

	def to_s
		"Cancel: #{index} #{start} #{length} #{connection}"
	end
end

class Port
	attr_reader :id, :port, :connection

	def initialize
		@id = 9
	end
	
	def explode(conn, content)
		@port = content.unpack("N")[0]
		@connection = conn
		self
	end

	def to_s
		"Port: #{port} #{connection}"
	end
end

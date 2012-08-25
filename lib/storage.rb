require_relative 'bitset.rb'
require_relative '../configure/environment.rb'
require 'thread'
require 'fcntl'
require 'digest/sha1'

=begin
	TODO: Add piece verification	
=end
class Storage
	BLOCK_SIZE = 16384

	def initialize(directory, metainfo)
		@metainfo = metainfo
		@size = metainfo.info.pieces.pieces.length
		@got = Bitset.new(@size).fill(0)
		@piece_length = metainfo.info.pieces.piece_length
		@overall_bytes = @metainfo.info.directory.files.inject(0) { |base, f| base + f.length}
		@current_bytes = 0

		offset = 0
		@handles = {}

		@metainfo.info.directory.files.each { | f |
			current = offset
			offset += f.length

			exists = File.exists?("#{directory}#{File::SEPARATOR}#{f.name}")
			handle = File.new("#{directory}#{File::SEPARATOR}#{f.name}", 
				Fcntl::O_RDWR | Fcntl::O_CREAT)

			# If file doesn't exist, we want to create it with the correct length
			# this helps with piece verification and gap assessment as we can
			# guarantee the length of a file and the presence of bytes for blocks
			#
			if (! exists)
				handle.seek(f.length - 1, IO::SEEK_SET)
				handle.write("\x00")
			end

			@handles[ current..current + f.length - 1 ] = handle
		}

		@lock = Mutex.new
		@queue = Queue.new

		update_got

		STORAGE_LOGGER.info("Storage has: #{@got} in bytes: #{@current_bytes} out of #{@overall_bytes}")

		@queue_thread = Thread.new { run }		
	end

	def update_got
		(0...@size).each do | p |
			digester = Digest::SHA1.new

			byte_count = 0
			blks = blocks(p)

			STORAGE_LOGGER.debug("Piece #{p} has blocks #{blks}")

			while (blks.length > 0)
				buffer = read_block_impl(p, blks.take(1).flatten)

				STORAGE_LOGGER.debug("Buffer for piece is #{buffer.length} #{blks}")

				digester.update(buffer)

				byte_count += blks.take(1).flatten[1]
				blks = blks.drop(1)
			end

			digest = digester.digest

			if (digest == @metainfo.info.pieces.pieces[p])
				@got.set(p)
				@current_bytes += byte_count
			else
				STORAGE_LOGGER.debug("Digest failed: #{digest.unpack("H*")} #{@metainfo.info.pieces.pieces[p].unpack("H*")}")
			end			
		end
	end

	def run
		Thread.current.abort_on_exception = true

		until false do
			process(@queue.deq)
		end
	end

	def process(message)

		case message

		when :poison
			Thread::exit

		when SaveBlock
			save_block_impl(message.piece, message.block_range, message.data)

		when VerifyPiece
			@lock.synchronize {
				@got.set(message.piece)
			}

			message.block.call(true)

		when ReadBlock
			message.block.call(read_block_impl(message.piece, message.block_range))
		end			
	end

	def locate(offset)
		STORAGE_LOGGER.debug("Locating on: #{offset}")

		@handles.keys.inject(nil) { | chosen, r |
			if (r.cover?(offset))
				r
			else
				chosen
			end
		}
	end

	def close
		@queue.enq(:poison)
		@queue_thread.join

		@handles.values.each { | f | f.close }
		@handles = {}
	end

	def blocks(piece)
		length_of_piece = (piece == (@size - 1)) ? (@overall_bytes % @piece_length) : @piece_length
		total = length_of_piece / BLOCK_SIZE

		requests = (0...total).map { |b| [b * BLOCK_SIZE, BLOCK_SIZE]}

		if ((length_of_piece % BLOCK_SIZE) != 0)
			requests << [total * BLOCK_SIZE, length_of_piece % BLOCK_SIZE]
		end

		requests
	end

	def overall_bytes
		@lock.synchronize {
			@overall_bytes
		}
	end

	def current_bytes
		@lock.synchronize {
			@current_bytes
		}
	end

	def got
		@lock.synchronize {
			@got.dup
		}
	end

	def needed
		@lock.synchronize {
			@got.invert
		}
	end

	def complete?
		@lock.synchronize {
			return (@current_bytes == @overall_bytes)
		}
	end

	def piece_complete(piece, &block)
		@queue.enq(VerifyPiece.new(piece, block))
	end

	class VerifyPiece
		attr_reader :piece, :block

		def initialize(piece, block)
			@piece = piece
			@block = block
		end
	end

	def save_block(piece, block_range, data)
		@queue.enq(SaveBlock.new(piece, block_range, data))
	end

	class SaveBlock
		attr_reader :piece, :block_range, :data

		def initialize(piece, block_range, data)
			@piece = piece
			@block_range = block_range
			@data = data
		end
	end

	def read_block(piece, block_range, &callback)
		@queue.enq(ReadBlock.new(piece, block_range, callback))
	end

	class ReadBlock
		attr_reader :piece, :block_range, :block

		def initialize(piece, block_range, callback)
			@piece = piece
			@block_range = block_range
			@block = callback
		end
	end

	def read_block_impl(piece, block_range)
		abs_blk_pos = (piece * @piece_length) + block_range[0]
		range = locate(abs_blk_pos)
		file_blk_pos = abs_blk_pos - range.begin
		bytes_to_read = [range.end + 1 - file_blk_pos, block_range[1]].min

		STORAGE_LOGGER.debug "Seeking to: #{file_blk_pos} to read #{bytes_to_read} => #{abs_blk_pos} #{range} #{block_range}"

		handle = @handles[range]
		handle.seek(file_blk_pos, IO::SEEK_SET)
		buffer = handle.read(bytes_to_read)

		while (buffer.length < block_range[1])
			range = locate(range.end + 1)
			bytes_to_read = [range.end - range.begin + 1, block_range[1] - buffer.length].min
			handle = @handles[range]

			STORAGE_LOGGER.debug "Seeking to: 0 to read #{bytes_to_read} => #{abs_blk_pos} #{range} #{block_range}"

			handle.seek(0, IO::SEEK_SET)
			buffer << handle.read(bytes_to_read)
		end

		buffer
	end

	def save_block_impl(piece, block_range, data)
		buffer = data.dup

		abs_blk_pos = (piece * @piece_length) + block_range[0]
		range = locate(abs_blk_pos)
		file_blk_pos = abs_blk_pos - range.begin
		bytes_to_write = [range.end + 1 - file_blk_pos, buffer.length].min

		STORAGE_LOGGER.debug "Seeking to: #{file_blk_pos} to write #{bytes_to_write} => #{abs_blk_pos} #{range}"

		write_block(@handles[range], file_blk_pos, buffer, bytes_to_write)

		while (buffer.length != 0)
			# Whatever is left will be allocated across the other files in the torrent from offset 0 in each case
			#
			range = locate(range.end + 1)
			bytes_to_write = [range.end - range.begin + 1, buffer.length].min

			STORAGE_LOGGER.debug "Seeking to: 0 to write #{bytes_to_write} => #{abs_blk_pos} #{range}"

			write_block(@handles[range], 0, buffer, bytes_to_write)
		end

		@lock.synchronize {
			@current_bytes += data.length
		}
	end

	def write_block(handle, pos, buffer, num)
		chunk = buffer.slice!(0, num)

		handle.seek(pos, IO::SEEK_SET)
		handle.write(chunk)
	end

	private :read_block_impl, :save_block_impl, :write_block, :locate, :run

	def to_s
		"Storage: Pieces = #{@size} Piece Length: #{@piece_length} Total Bytes: #{@overall_bytes}"
	end
end

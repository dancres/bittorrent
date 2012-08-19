require_relative 'bitset.rb'

class Storage
	BLOCK_SIZE = 16384

	attr_reader :got, :overall_bytes, :current_bytes, :handles

	def initialize(directory, metainfo)
	    @logger = Logger.new(STDOUT)
	    @logger.level = Logger::DEBUG
	    formatter = Logger::Formatter.new
	      @logger.formatter = proc { |severity, datetime, progname, msg|
	        formatter.call(severity, datetime, progname, msg.dump)
	      }		

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
			@handles[ current..current + f.length - 1 ] = File.new("#{directory}#{File::SEPARATOR}#{f.name}", "a+b")
		}
	end

	def locate(offset)
		handles.keys.inject(nil) { | chosen, r |
			if (r.cover?(offset))
				r
			else
				chosen
			end
		}
	end

	def close
		@handles.values.each { | f | f.close }
		@handles = {}
	end

	def needed
		@got.invert
	end

	def complete?
		return (current_bytes == overall_bytes)
	end

	def save_block(piece, block_range, data)
		buffer = data.dup

		abs_blk_pos = (piece * @piece_length) + block_range[0]
		range = locate(abs_blk_pos)
		file_blk_pos = abs_blk_pos - range.begin
		bytes_to_write = [range.end + 1 - file_blk_pos, buffer.length].min

		@logger.debug "Seeking to: #{file_blk_pos} to write #{bytes_to_write} => #{abs_blk_pos} #{range}"

		write_block(@handles[range], file_blk_pos, buffer, bytes_to_write)

		while (buffer.length != 0)
			# Whatever is left will be allocated across the other files in the torrent from offset 0 in each case
			#
			range = locate(range.end + 1)
			bytes_to_write = range.end - range.begin + 1

			@logger.debug "Seeking to: 0 to write #{bytes_to_write} => #{range}"

			write_block(@handles[range], 0, buffer, bytes_to_write)
		end

		@current_bytes += data.length
	end

	def write_block(handle, pos, buffer, num)
		chunk = buffer.slice!(0, num)

		handle.seek(pos, IO::SEEK_SET)
		handle.write(chunk)
	end

	def piece_complete(piece)
		@got.set(piece)
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

	def to_s
		"Storage: Pieces = #{@size} Piece Length: #{@piece_length} Total Bytes: #{@overall_bytes}"
	end
end

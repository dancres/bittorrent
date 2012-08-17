require_relative 'bitset.rb'

class Storage
	BLOCK_SIZE = 16384

	attr_reader :got, :overall_bytes, :current_bytes

	def initialize(metainfo)
		@metainfo = metainfo
		@size = metainfo.info.pieces.pieces.length
		@got = Bitset.new(@size).fill(0)
		@piece_length = metainfo.info.pieces.piece_length
		@overall_bytes = @metainfo.info.directory.files.inject(0) { |base, f| base + f.length}
		@current_bytes = 0
	end

	def needed
		@got.invert
	end

	def complete?
		return (current_bytes == overall_bytes)
	end

	def save_block(piece, block, data)
		@current_bytes += data.length
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
require_relative 'bitset.rb'

class Storage
	BLOCK_SIZE = 16384

	attr_reader :got

	def initialize(size, piece_length)
		@size = size
		@got = Bitset.new(size).fill(0)
		@piece_length = piece_length
	end

	def needed
		@got.invert
	end

	def blocks
		total = @piece_length / BLOCK_SIZE

		requests = (0...total).map { |b| [b * BLOCK_SIZE, BLOCK_SIZE]}

		if ((@piece_length % BLOCK_SIZE) != 0)
			requests << [total * BLOCK_SIZE, @piece_length % BLOCK_SIZE]
		end

		requests
	end

end
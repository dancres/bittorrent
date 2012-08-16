require_relative 'bitset.rb'

class Storage
	attr_reader :got

	def initialize(size)
		@size = size
		@got = Bitset.new(size).fill(0)
	end

	def needed
		@got.invert
	end
end
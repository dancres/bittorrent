require 'set'
require_relative 'bitset.rb'

=begin

Picker tracks availability of all pieces for a torrent.

When asked to select the next piece to download it selects based on scarcity, what pieces a peer
has and what we need.

=end

class Picker
	def initialize(size)
		@piece_freq = {}
		@booked_out = Set.new
		@size = size
	end

	# Announces to Picker the loss of an available client's bitmap
	#
	def unavailable(bitmap)
		bitmap.bits.each_with_index { | b, i |
			if (b == 1)
				count = @piece_freq[i]
				count -= 1

				if (count == 0)
					@piece_freq.delete(i)
				else
					@piece_freq[i] = count
				end
			end
		}
	end

	# Announces to Picker a client's current bitmap
	#
	def available(bitmap)
		bitmap.bits.each_with_index { | b, i |
			if (b == 1)
				count = @piece_freq[i]
				if (count == nil)
					count = 1
				else
					count += 1
				end

				@piece_freq[i] = count
			end
		}
	end

	def infrequent
		min = 2^32
		@piece_freq.values.each { | c |
			min = c unless (c >= min)
		}

		@piece_freq.rassoc(min)[0]
	end

	def next_piece(needed_bitset = Bitset.new(@size).from_binary(nil, 1), peer_bitset = Bitset.new(@size).from_binary(nil, 1))
		mask = needed_bitset.and(peer_bitset)

		min = 2^32
		key = nil

		@piece_freq.keys.each { | k |
			if ((@piece_freq[k] < min) && (@booked_out.include?(k) == false) && 
				(mask.bits[k] != 0))
				key = k
				min = @piece_freq[k]
			end
		}

		@booked_out << key unless (key == nil)
		key
	end

	def release_piece(key)
		@booked_out.delete(key)
	end

	def finished(key)
		@piece_freq.delete(key)
		@booked_out.delete(key)
	end

	def frequencies
		@piece_freq
	end
end


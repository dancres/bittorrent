require 'test/unit'

=begin

Picker tracks availability of all pieces for a torrent.

When asked to select the next piece to download it selects based on scarcity, what pieces a peer
has and what we need.

Available and unavailable calls should all be masked by negating what storage says we have got.
This confines our field of interest to what we don't have. This implies we only call Picker.finished
after storage has the piece recorded etc.

=end

class Bitset
	attr_reader :bits, :size

	def initialize(size, bits = [])
		@size = size
		@bits = bits
	end

	def from_binary(binary, default_fill = 0)
		if (binary == nil)
			fill(default_fill)
		else
			binary.each_byte.with_index { | b, i |
				mask = 0x80
				base = i * 8
				offset = 0

				while ((mask != 0) && (base + offset < @size)) do
					if ((b & mask) != 0)
						@bits[(base + offset)] = 1
					else
						@bits[(base + offset)] = 0					
					end

					offset += 1
					mask >>= 1
				end
			}	
		end	
	end

	def fill(bitvalue)
		if (! ((bitvalue == 0) || (bitvalue == 1)))
			raise ArgumentError.new("1 or 0 only")
		end

		for i in 0...size
			@bits[i] = bitvalue
		end
	end

	def and(bitset)
		if (size != bitset.size)
			raise ArgumentError.new("Bitsizes aren't the same")
		end

		result = bits.each_with_index.map { | b, i|
			b & bitset.bits[i]
		}

		Bitset.new(size, result)
	end
end

class Picker
	def initialize(size)
		@piece_freq = {}
		@booked_out = {}
		@size = size
	end

	# Announces to Picker the loss of an available client's bitmap
	#
	def unavailable(bitmap)
		bitmap.each_byte.with_index { | b, i |
			mask = 0x80
			base = i * 8
			offset = 0

			while ((mask != 0) && (base + offset < @size)) do
				if ((b & mask) != 0)
					count = @piece_freq[(base + offset)]
					count -= 1

					if (count == 0)
						@piece_freq.delete(base + offset)
					else
						@piece_freq[(base + offset)] = count
					end
				end

				offset += 1
				mask >>= 1
			end
		}
	end

	# Announces to Picker a client's current bitmap
	#
	def available(bitmap)
		bitmap.each_byte.with_index { | b, i |
			mask = 0x80
			base = i * 8
			offset = 0

			while ((mask != 0) && (base + offset < @size)) do
				if ((b & mask) != 0)
					count = @piece_freq[(base + offset)]
					if (count == nil)
						count = 1
					else
						count += 1
					end

					@piece_freq[(base + offset)] = count
				end

				offset += 1
				mask >>= 1
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

	def next_piece(peer_bitmap = nil)
		bitmask = Bitset.new(@size)
		bitmask.from_binary(peer_bitmap, 1)

		min = 2^32
		key = nil

		@piece_freq.keys.each { | k |
			if ((@piece_freq[k] < min) && (@booked_out[k] == nil) && (bitmask.bits[k] != 0))
				key = k
				min = @piece_freq[k]
			end
		}

		@booked_out[key] = key unless (key == nil)
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

class TestPicker < Test::Unit::TestCase
	def test_bitmask_length
		p = Picker.new(8)

		p.available("\xff\xff")
		assert_equal(p.frequencies.length, 8, "Wrong number of pieces")

		p = Picker.new(12)

		p.available("\xff\xff")
		assert_equal(p.frequencies.length, 12, "Wrong number of pieces")
	end

	def test_bitmask
		p = Picker.new(16)

		p.available("\x01\x10")

		assert_equal(p.frequencies[7], 1, "Missing entry")
		assert_equal(p.frequencies[11], 1, "Missing entry")		

		p.available("\x01\x00")
		assert_equal(p.frequencies[7], 2, "Wrong freq")		
		assert_equal(p.frequencies[11], 1, "Wrong freq")		
	end

	def test_infrequent
		p = Picker.new(16)

		p.available("\x01\x10")
		p.available("\x01\x00")

		assert_equal(p.infrequent, 11, "Infrequent is broken")		
	end

	def test_lost
		p = Picker.new(16)

		p.available("\x01\x10")
		p.available("\x01\x00")
		p.available("\x01\x10")

		assert_equal(p.next_piece, 11, "Available is broken (maybe next_piece)")

		p.release_piece(11)

		p.unavailable("\x01\x10")
		p.unavailable("\x01\x10")

		assert_equal(p.next_piece, 7, "Unavailable is broken (maybe available)")
	end

	def test_piece_handling
		p = Picker.new(16)

		p.available("\x01\x10")
		p.available("\x01\x00")

		assert_equal(p.next_piece, 11, "next_piece is broken")				
		assert_equal(p.next_piece, 7, "next_piece is broken")				
		assert_equal(p.next_piece, nil, "next_piece is broken")

		p.release_piece(11)
		assert_equal(p.next_piece,11, "release is broken (maybe next_piece)")

		p.finished(7)
		p.release_piece(11)

		f = p.frequencies

		assert_equal(f.length, 1, "Wrong number of pieces left")
		assert_equal(p.next_piece,11, "finished is broken (maybe next_piece)")
	end

	def test_filter_by_peer
		p = Picker.new(16)
		b = "\x01\x00"

		p.available("\x01\x10")
		p.available("\x01\x00")

		assert_equal(p.next_piece, 11, "next_piece didn't filter on bitmap (maybe next_piece is broken)")
		p.release_piece(11)

		assert_equal(p.next_piece(b), 7, "next_piece didn't filter on bitmap")		
	end
end


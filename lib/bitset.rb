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

		self
	end

	def fill(bitvalue)
		if (! ((bitvalue == 0) || (bitvalue == 1)))
			raise ArgumentError.new("1 or 0 only")
		end

		for i in 0...size
			@bits[i] = bitvalue
		end

		self
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

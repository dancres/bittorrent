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

	def to_binary
		bytes = []
		bits = @bits.dup

		while ((nxt = bits.slice!(0, 8)).length != 0)
			nxt.fill(0, nxt.length...8)
			bytes << nxt.inject {| byte , bit | (byte << 1) | bit}			
		end

		bytes.pack("C*")
	end

	def invert
		Bitset.new(@size, @bits.map { | bit | bit ^ 1})
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

	def set(bit_index)
		@bits[bit_index] = 1
		
		self
	end

	def get(bit_index)
		@bits[bit_index]
	end	

	def and(bitset)
		if (size != bitset.size)
			raise ArgumentError.new("Bitsizes aren't the same")
		end

		result = @bits.each_with_index.map { | b, i|
			b & bitset.bits[i]
		}

		Bitset.new(size, result)
	end

	def allOne
		for i in 0...size
			if (@bits[i] == 0)
				return false
			end
		end

		true
	end

	def nonZero
		for i in 0...size
			if (@bits[i] != 0)
				return true
			end
		end

		false
	end

	def to_s
		"Bitset #{to_binary.unpack("B*")}"
	end
end


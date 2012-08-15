require_relative '../lib/picker.rb'
require 'test/unit'

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

		assert_equal(p.next_piece(nil, b), 7, "next_piece didn't filter on bitmap")		
	end
end


class ClientDetails
	attr_reader :port, :peer_id

	def initialize(port)
		@port = port
		time = (Time.now.to_f * 1000).to_i.to_s.reverse
		@peer_id = "DC0001-#{time}".slice(0, 20).ljust(20, "-")
	end
end

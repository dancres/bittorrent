class ClientDetails
	attr_reader :port, :peer_id

	def initialize(port)
		@port = port
		@peer_id = "DC0001-#{(Time.now.to_f * 1000.0).to_i}".slice(0, 20).ljust(20, "-")
	end
end

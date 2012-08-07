require 'socket'
require './tracker.rb'
require './connection.rb'

class Downloader

	def initialize(metainfo, tracker, client_details)
		@meta = metainfo
		@tracker = tracker
		@client_details = client_details
	end

	def run
		response = @tracker.ping({Tracker::UPLOADED => 0, Tracker::DOWNLOADED => 0, 
			Tracker::LEFT => @meta.info.directory.files[0].length,
			Tracker::EVENT => Tracker::STATUS_STARTED})

		puts response

		if (response.code == 200)
			puts "Good"

			tr = Tracker::AnnounceResponse.new(response.body)

			puts tr

			# Start connection for each peer that isn't us (as identified by Socket)
			my_addresses = Socket.ip_address_list.map { |addr| addr.ip_address}

			tr.peers.each { |peer|
				if (my_addresses.include?(peer.ip.ip_address) && (peer.port == @client_details.port))
					puts "Discarding: #{peer}"
				else
					puts "Connecting: #{peer}"

				end
			}

		else
			puts "Bad #{response.code}"
			return
		end
	end	
end

require_relative '../configure/environment.rb'
require 'socket'

=begin

Choking
=======

A client must maintain state information for each connection that it has with a remote peer:

choked: Whether or not the remote peer has choked this client. When a peer chokes the client,
it is a notification that no requests will be answered until the client is unchoked. The client
should not attempt to send requests for blocks, and it should consider all pending (unanswered)
requests to be discarded by the remote peer.

interested: Whether or not the remote peer is interested in something this client has to offer.
This is a notification that the remote peer will begin requesting blocks when the client
unchokes them.

Note that this also implies that the client will also need to keep track of whether or not it
is interested in the remote peer, and if it has the remote peer choked or unchoked. So, the
real list looks something like this:

am_choking: this client is choking the peer
am_interested: this client is interested in the peer

peer_choking: peer is choking this client
peer_interested: peer is interested in this client

Client connections start out as "choked" and "not interested". In other words:

am_choking = 1
am_interested = 0
peer_choking = 1
peer_interested = 0

Queuing
=======

"When data is being transferred, downloaders should keep several piece requests queued 
up at once in order to get good TCP performance (this is called 'pipelining'.) On the
other side, requests which can't be written out to the TCP buffer immediately should 
be queued up in memory rather than kept in an application-level network buffer, so 
they can all be thrown out when a choke happens."

We will maintain a stack with contents derived from a sufficient number of indexes that
when divided by blocks we get enough possible requests to maintain a queue. The stack
itself will consist of all the blocks for each index "booked out" from the Picker. One or
more of those blocks will be marked as "in-flight". When an "in-flight" request is
completed we'll clear it off and dispatch another. Should the stack size be less than
the desired number of requests, we'll "book out" another index. Should we complete the
last request for a particular index we inform the picker it is "complete". If we are
choked or otherwise determine "in-flight" requests are no longer viable, we clear the
queue and "release" all indexes back to the picker.

Maximum size of a block is 16k traditionally. Notably mainline allows config override. 
libtorrent also does 16k

=end

class Selector	
	def initialize
		@lock = Mutex.new
		@handlers = {}
		@terminate = false
		@selector_thread = Thread.new { run }
	end

	def terminate
		@lock.synchronize {
			@terminate = true
		}

		@selector_thread.join
	end

	def terminate?
		@lock.synchronize {
			@terminate
		}
	end

	def add(handler)
		SELECTOR_LOGGER.debug("Selector adding: #{handler}")

		@lock.synchronize {
			@handlers[handler.io] = handler
		}
	end

	def run
		Thread.current.abort_on_exception = true

		until terminate? do
			readers = []
			writers = []
			errors = []
			discards = []

			@lock.synchronize {
				@handlers.values.each { |handler|
					if (handler.interests == nil)
						discards << handler
					else
						interests = handler.interests

						if (interests.include?("r"))
							readers << handler.io
						end

						if (interests.include?("w"))
							writers << handler.io
						end

						if (interests.include?("e"))
							errors << handler.io
						end						
					end
				}

				discards.each { |handler| @handlers.delete(handler.io)}
			}

			begin
				readers, writers, errors = IO.select(readers, writers, errors, 0.1)

				readers.each { |io| @handlers[io].read } unless (readers == nil)

				writers.each { |io| @handlers[io].write } unless (writers == nil)

				errors.each { |io| handlers[io].error } unless (errors == nil)
			rescue Exception => e
				SELECTOR_LOGGER.warn("Exception #{e} #{((e.backtrace != nil) && (e.backtrace.length > 0)) ? e.backtrace[0] : "no trace"}")
  			end
		end
	end
end

class Handler
	def io
	end

	# Return one or more of r, w, and e or merely d to indicate the selector
	# should remove this instance
	def interests
		"rwe"
	end

	def read
		puts "Handler read"
	end	

	def write
		puts "Handler write"
	end

	def error
		puts "Handler error"
	end
end

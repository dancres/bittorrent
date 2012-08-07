require 'socket'

=begin

Shared state
============

Stuff shared across connections[info_hash]: 
	meta-block, 
	picker (needs access to all connections[info_has])
	file_state (what we have and don't, will determine what we send in a bitfield),
	tracker

Stuff shared across connections[global]: 
	Choking

Stuff that is local to a connection: 
	Peer-id
	Info-hash
	Keep-alive, 
	bitfield (updated by have messages, we pass this to picker to help it select a piece 
		to request of a remote peer. We also use it to filter our own have messages such that
		we don't tell a peer about something we know it has already.)

On connection we wait for handshake then send ours. At this point we'd know the info_hash and
peer_id of the process at the other end and we can store those in the Connection instance.

We'll adopt a chain of responsibility with a stack of filters that accept messages as they
are presented and can send messages in response or indeed bycott further movement of the
received message up the stack.

This arrangement allows us to send heartbeat response and also then send a bitfield.
It also allows for processing of chokes where we wish to note what's happening and
possibly dump requests etc.

A separate filter can use received bitfields and have messages to assemble a view
of what each process has. This filter might also constitute the picker as it can
track what is rarest and what other processes have. What it wouldn't have is
the ability to know what we have unless it snoops on all blocks and for pieces.
If it were to know how many blocks to a piece it could detect the arrival of the
last block of a piece and designate it received. Note that the picker can also tell
us which peers have a piece we require thus it can also control the interest flags
per peer. A picker might be shared across a number of connections (there'd be one
picker per info_hash we're interested in or serving).

Timeouts are typically 20 seconds according to libtorrent but spec says 2 minutes.
Notably anti-snub seems to activate after a minute of no response from a peer.

Alternative to Filters
======================

We could write a single state machine which, once info_hash is established, grabs
all the bits it needs via static/factory methods and then locks e.g. the info object
before processing any state. Or we could have one container that holds all relevant
bits for the stuff key'd off info_hash and lock that.

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

Message Queue
=============

We will have a queue of messages which are gradually streamed out onto the network
using the approach outlined in "Streaming" below. This queue will take messages
produced from the request queue and other elements of the state machine and emit them
in the order received.

Picker
======

Will need to know what indexes are held at a peer in order to select an appropriate
index to fill the request queue.

=end

class Core
	attr_reader :selector, :serversocket

	def initialize(client_details)
		@selector = Selector.new
		@serversocket = TCPServer.new(client_details.port)
	end

	def terminate
	end
end

class Selector
	def initialize
		@lock = Mutex.new
		@handlers = []
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
		@lock.synchronize {
			@handlers << handler
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
				@handlers.each { |handler|
					if (handler.interests == nil)
						discard << handler
					else
						interests = handler.interests

						if (interests.include?("r"))
							readers << handler
						end

						if (interests.include?("w"))
							writers << handler
						end

						if (interests.include?("e"))
							errors << handler
						end						
					end
				}

				discards.each { |handler| @handlers.delete(handler)}
			}

			readers, writers, errors = IO.select(readers, writers, errors, 0.1)

			readers.each { |handler| handler.read } unless (readers == nil)

			writers.each { |handler| handler.write } unless (writers == nil)

			errors.each { |handler| handler.error } unless (errors == nil)
		end
	end
end

class Handler
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

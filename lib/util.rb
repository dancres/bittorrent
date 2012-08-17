require 'timers'
require 'thread'
require 'set'

class Scheduler
	def initialize
		@timers = Timers.new
		@lock = Mutex.new
		@terminate = false		
		@thread = Thread.new { run }
	end

	def terminate
		@lock.synchronize {
			@terminate = true
		}

		@thread.join
	end

	def terminate?
		@lock.synchronize {
			@terminate
		}
	end

	def run
		Thread.current.abort_on_exception = true

		until terminate? do
			sleep 0.1

			@lock.synchronize {
				@timers.fire
			}
		end
	end

	def add(&block)
		@lock.synchronize {
			block.call(@timers)
		}
	end
end

class Pool
	def initialize
		@pool = Set.new
		@lock = Mutex.new
	end

	def add(obj)
		@lock.synchronize {
			@pool.add(obj)
		}
	end

	def remove(obj)
		@lock.synchronize {
			@pool.delete(obj)
		}
	end

	def each &block
		@lock.synchronize {
			@pool.each{ |obj| block.call(obj) }
		}
	end	
end
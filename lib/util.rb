require 'timers'
require 'thread'

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

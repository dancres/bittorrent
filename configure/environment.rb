require 'logger'

$stdout.sync = true

DEFAULT_OUTPUT = STDOUT

original_formatter = Logger::Formatter.new

def dumpLogger(stack)
	offset = 0
	while (stack[offset].include?("logger.rb"))
		offset += 1
	end

	stack.drop(offset)[0]
end

COLLECTOR_LOGGER = Logger.new(DEFAULT_OUTPUT)
COLLECTOR_LOGGER.level = Logger::DEBUG
COLLECTOR_LOGGER.formatter = proc { |severity, datetime, progname, msg|
	trace = Kernel::caller
	trace = (trace != nil) ? dumpLogger(trace) : "--xxx--"
	original_formatter.call(severity, datetime, progname, "#{trace} #{msg.dump}")
}

CHOKER_LOGGER = Logger.new(DEFAULT_OUTPUT)
CHOKER_LOGGER.level = Logger::DEBUG
CHOKER_LOGGER.formatter = proc { |severity, datetime, progname, msg|
	trace = Kernel::caller
	trace = (trace != nil) ? dumpLogger(trace) : "--xxx--"
	original_formatter.call(severity, datetime, progname, "#{trace} #{msg.dump}")
}

CONNECTION_LOGGER = Logger.new(DEFAULT_OUTPUT)
CONNECTION_LOGGER.level = Logger::DEBUG
CONNECTION_LOGGER.formatter = proc { |severity, datetime, progname, msg|
	trace = Kernel::caller
	trace = (trace != nil) ? dumpLogger(trace) : "--xxx--"
	original_formatter.call(severity, datetime, progname, "#{trace} #{msg.dump}")
}

STORAGE_LOGGER = Logger.new(DEFAULT_OUTPUT)
STORAGE_LOGGER.level = Logger::INFO
STORAGE_LOGGER.formatter = proc { |severity, datetime, progname, msg|
	trace = Kernel::caller
	trace = (trace != nil) ? dumpLogger(trace) : "--xxx--"
	original_formatter.call(severity, datetime, progname, "#{trace} #{msg.dump}")
}

SELECTOR_LOGGER = Logger.new(DEFAULT_OUTPUT)
SELECTOR_LOGGER.level = Logger::INFO
SELECTOR_LOGGER.formatter = proc { |severity, datetime, progname, msg|
	trace = Kernel::caller
	trace = (trace != nil) ? dumpLogger(trace) : "--xxx--"
	original_formatter.call(severity, datetime, progname, "#{trace} #{msg.dump}")
}

TRACKER_LOGGER = Logger.new(DEFAULT_OUTPUT)
TRACKER_LOGGER.level = Logger::INFO
TRACKER_LOGGER.formatter = proc { |severity, datetime, progname, msg|
	trace = Kernel::caller
	trace = (trace != nil) ? dumpLogger(trace) : "--xxx--"
	original_formatter.call(severity, datetime, progname, "#{trace} #{msg.dump}")
}

PICKER_LOGGER = Logger.new(DEFAULT_OUTPUT)
PICKER_LOGGER.level = Logger::INFO
PICKER_LOGGER.formatter = proc { |severity, datetime, progname, msg|
	trace = Kernel::caller
	trace = (trace != nil) ? dumpLogger(trace) : "--xxx--"
	original_formatter.call(severity, datetime, progname, "#{trace} #{msg.dump}")
}

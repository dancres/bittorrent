require 'logger'

DEFAULT_OUTPUT = STDOUT

COLLECTOR_LOGGER = Logger.new(DEFAULT_OUTPUT)
COLLECTOR_LOGGER.level = Logger::DEBUG

CHOKER_LOGGER = Logger.new(DEFAULT_OUTPUT)
CHOKER_LOGGER.level = Logger::INFO

CONNECTION_LOGGER = Logger.new(DEFAULT_OUTPUT)
CONNECTION_LOGGER.level = Logger::INFO

STORAGE_LOGGER = Logger.new(DEFAULT_OUTPUT)
STORAGE_LOGGER.level = Logger::INFO

SELECTOR_LOGGER = Logger.new(DEFAULT_OUTPUT)
SELECTOR_LOGGER.level = Logger::INFO

TRACKER_LOGGER = Logger.new(DEFAULT_OUTPUT)
TRACKER_LOGGER.level = Logger::INFO

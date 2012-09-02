A BitTorrent library written in Ruby.

For a simple example to get started see lib/download.rb

The library supports seeding and downloading but does not yet support any extensions e.g. DHT or Fast.

Next steps:

* More tests
* Package as a gem
* Add support for Fast extension
* Add request pipelining for greater download speed
* Explicit support for parallel activity across multiple torrents

If you wish to help develop the library, the chances are you will want to create some test torrents and run them against a private tracker. Creating torrents can be done via most of the existing clients such as Vuze and OpenTracker (http://erdgeist.org/arts/software/opentracker/) works reasonably well as a test tracker.

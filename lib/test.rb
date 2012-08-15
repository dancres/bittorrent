require_relative 'tracker.rb'
require_relative 'meta.rb'

# If our require worked, this will be available
#
puts Tracker::STATUS_STARTED
puts Tracker::INFO_HASH

#m = MetaInfo.new("../metas/eclipse-SDK-3.7-linux-gtk-x86_64.torrent")

#m = MetaInfo.new("../metas/cluj.torrent")

#m = MetaInfo.new("../metas/aaron.torrent")

m = MetaInfo.new("/Users/dan/Desktop/Sublime Text 2.0.1.dmg.torrent")

puts m.tracker
puts m.info
m.info.pieces.dump

#t = Tracker.new(m.tracker, m.info.sha1_hash, nil, 8080)
#puts t.ping({Tracker::DOWNLOADED => "12345"}).code

require './tracker.rb'
require './meta.rb'
require './downloader.rb'
require './client.rb'

#m = MetaInfo.new("../metas/cluj.torrent")
# m = MetaInfo.new("../metas/aaron.torrent")
#m = MetaInfo.new("../metas/eclipse-SDK-3.7-linux-gtk-x86_64.torrent")
#m = MetaInfo.new("../metas/jdk-7u4-macosx-x64.dmg.torrent")
#m = MetaInfo.new("../metas/Aquamacs Manual.pdf.torrent")
m = MetaInfo.new("/Users/dan/Desktop/Sublime Text 2.0.1.dmg.torrent")

c = ClientDetails.new(8080)
t = Tracker.new(m.tracker, m.info.sha1_hash, c)
d = Downloader.new(m, t, c)
d.run

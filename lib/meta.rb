require 'bencode'
require 'digest/sha1'

class MetaInfo
  ANNOUNCE = "announce"
  INFO = "info"
  
  attr_reader :tracker, :info
  
  def initialize(filename)
    block = BEncode.load_file(filename)
    
    # A tracker that supports scape will have /announce in its URL which can be replaced with /scrape
    # A tracker which doesn't support scrape won't have an /announce present
    # In either case the URL should not finish with a slash so http://tracker.org/announce/ would be wrong
    # it should be http://tracker.org/announce
    #
    @tracker = block[ANNOUNCE]
    @info = Info.new(block[INFO])
  end
end

class Info
  FILES = "files"
  PATH = "path"
  LENGTH = "length"
  MD5_SUM = "md5sum"
  NAME = "name"
  
  attr_reader :pieces, :directory, :hash
  
  def initialize(info)
    # FIX THIS - We need the original info string from the file to hash not the hashmap
    #
    # hash is required by Trackers
    #
    @hash = Digest::SHA1.digest(info.bencode)
        
    @pieces = Pieces.new(info)
    
    if info.key?(FILES)
      # multi
      entrys = []
      files = info[FILES]
      files.each {|file| 
        entrys << Entry.new(file[PATH].inject("") {|base, part| "#{base}/#{part}"}, file[LENGTH], 
          file[MD5_SUM])
        }
      
      @directory = Directory.new(info[NAME], entrys)
    else
      # single
      @directory = Directory.new(nil, [Entry.new(info[NAME], info[LENGTH], info[MD5_SUM])])
    end
  end
  
  def to_s
    "Info: #{hash.unpack("H*")} #{pieces} #{directory}"
  end
end

class Pieces
  PIECE_LENGTH = "piece length"
  PIECES = "pieces"
  
  attr_reader :pieces, :piece_length
  
  def initialize(info)
    @piece_length = info[PIECE_LENGTH]
    @pieces = []
    
    pieces = info[PIECES]
    count = 0
    while pieces.size > 0
      count = count + 1
      digest = pieces.slice!(0, 20)  #(offset, length)
      @pieces << digest
    end    
  end
  
  def dump
    pieces.each {|digest| puts digest.unpack("H*")}
    puts "Piece length: #{piece_length}"
    puts "Total pieces: #{pieces.length}"
  end
  
  def to_s
    "Pieces: #{pieces.length} each #{piece_length}"
  end
end

class Entry
  attr_reader :name, :length, :md5_sum
  
  def initialize(name, length, md5_sum = nil)
    @name = name
    @length = length
    @md5_sum = md5_sum # optional
  end
  
  def to_s
    "Entry: #{name} length: #{length}"
  end  
end

class Directory
  attr_reader :root, :files
  
  def initialize(root, files)
    @root = root
    @files = files # optional
  end
  
  def to_s
    "Directory: #{root} total files: #{files.length} " + 
      files.inject("") {|base, file| "#{base}, #{file}"}
  end
end


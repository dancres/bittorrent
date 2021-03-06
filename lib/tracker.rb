require_relative '../configure/environment.rb'
require 'cgi'
require 'net/http'
require 'uri'
require 'rest_client'
require 'bencode'
require 'resolv'
require 'ipaddr'
require 'socket'

class Tracker
  STATUS_STARTED = "started"
  STATUS_STOPPED = "stopped"
  STATUS_COMPLETED = "completed"
  STATUS_UPDATE = ""

  INFO_HASH = :info_hash
  PEER_ID = :peer_id
  PORT = :port
  UPLOADED = :uploaded
  DOWNLOADED = :downloaded
  LEFT = :left
  NO_PEER_ID = :no_peer_id
  EVENT = :event
  NUMWANT = :numwant
  
  attr_reader :tracker_url, :info_hash
  
  def initialize(tracker_url, info_hash, core)
    @tracker_url = tracker_url
    @info_hash = info_hash
    @core = core
    RestClient.log = TRACKER_LOGGER
  end  
  
  def ping(param_map)
    http_get(tracker_url, "", param_map.merge({INFO_HASH => info_hash, PEER_ID => @core.peer_id, 
      PORT => @core.port}))
  end
  
  def http_get(domain,path,params)
      URI.parse(tracker_url + path + "?".concat(params.collect { |k,v| "#{k}=#{CGI::escape(v.to_s)}" }.join('&')))
      
      begin
        RestClient.get "#{domain}#{path}", {:params => params}
      rescue
        FailResponse.new
      end
  end

  class FailResponse
    attr_reader :code

    def initialize
      @code = 500
    end
  end

  class AnnounceResponse
    FAILURE_REASON = "failure reason"
    WARNING_MESSAGE = "warning message"
    INTERVAL = "interval"
    MIN_INTERVAL = "min interval"
    COMPLETE = "complete"
    INCOMPLETE = "incomplete"
    PEERS = "peers"

    PEER_ID = "peer id"
    IP = "ip"
    PORT = "port"

    attr_reader :failure, :warning, :interval, :minimum_interval, :complete, :incomplete, :peers

    def initialize(response)
      # Dealing in the web means 8-bit ASCII
      #
      parsed = BEncode.load(response.force_encoding("BINARY"))

      @failure = (parsed.has_key?(FAILURE_REASON)) ? parsed[FAILURE_REASON] : nil
      @warning = (parsed.has_key?(WARNING_MESSAGE)) ? parsed[WARNING_MESSAGE] : nil
      @interval = (parsed.has_key?(INTERVAL)) ? parsed[INTERVAL].to_i : 1800
      @minimum_interval = (parsed.has_key?(MIN_INTERVAL)) ? parsed[MIN_INTERVAL].to_i : @interval
      @complete = (parsed.has_key?(COMPLETE)) ? parsed[COMPLETE].to_i : 0
      @incomplete = (parsed.has_key?(INCOMPLETE)) ? parsed[INCOMPLETE].to_i : 0

      @peers = []

      if ((parsed.has_key?(PEERS)))
        if (parsed[PEERS].class.eql?(String))
          peerstring = parsed[PEERS]

          count = 0
          while peerstring.size > 0
            count = count + 1
            peeraddr = peerstring.slice!(0, 6)  #(offset, length)
            addr = Addrinfo.ip(IPAddr.new_ntoh(peeraddr.slice!(0, 4)).to_s)
            port = peeraddr.slice(0, 2)

            @peers << Peer.new(nil, addr, port.unpack("n")[0])
          end    
        else
          parsed[PEERS].each { |peer|
            ip = Addrinfo.ip(peer[IP])
            id = peer[PEER_ID]
            port = peer[PORT]

            @peers << Peer.new(id, ip, port)
          }
        end
      end      
    end

    def to_s
      "TrackerResponse => Fail: #{failure} Warn: #{warning}" + 
      " Seeds: #{complete} Leeches: #{incomplete} Interval: #{interval} Min Interval: #{minimum_interval} " +
      peers.inject("") {|base, p| "#{base}, #{p}"}
    end

    class Peer
      attr_reader :id, :ip, :port

      def initialize(id, ip, port)
        @id = id
        @ip = ip
        @port = port
      end

      def to_s
        "Peer => #{id} #{ip.ip_address} #{port}"
      end
    end    
  end
end

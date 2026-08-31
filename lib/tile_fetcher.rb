# frozen_string_literal: true

require "net/http"
require "uri"
require "fileutils"

# Fetches OSM (or a custom XYZ) tile server, caching every tile to disk so
# it is only ever downloaded once across repeated runs (including --nframes
# test iterations).
class TileFetcher
  USER_AGENT = "dashcam-gps-overlay/1.0 (personal project; contact via GitHub)"
  MIN_REQUEST_INTERVAL = 0.2 # seconds, be polite to the tile server

  def initialize(cache_dir:, provider: "osm", custom_url_template: nil, custom_api_key: nil)
    @cache_dir = cache_dir
    @provider = provider
    @custom_url_template = custom_url_template
    @custom_api_key = custom_api_key
    @last_request_at = nil
    FileUtils.mkdir_p(@cache_dir)
  end

  # Returns the local file path for tile (zoom, x, y), downloading it first
  # if not already cached.
  def fetch(zoom, x, y)
    path = cache_path(zoom, x, y)
    return path if File.exist?(path)

    FileUtils.mkdir_p(File.dirname(path))
    data = download(zoom, x, y)
    File.binwrite(path, data)
    path
  end

  private

  def cache_path(zoom, x, y)
    File.join(@cache_dir, @provider, zoom.to_s, x.to_s, "#{y}.png")
  end

  def tile_url(zoom, x, y)
    case @provider
    when "osm"
      subdomain = %w[a b c][(x + y) % 3]
      "https://#{subdomain}.tile.openstreetmap.org/#{zoom}/#{x}/#{y}.png"
    when "custom"
      raise "map.custom_tile_url_template is not set in config" unless @custom_url_template

      url = @custom_url_template.gsub("{z}", zoom.to_s).gsub("{x}", x.to_s).gsub("{y}", y.to_s)
      url = "#{url}#{url.include?('?') ? '&' : '?'}key=#{@custom_api_key}" if @custom_api_key && !@custom_api_key.empty?
      url
    else
      raise "Unknown tile provider #{@provider.inspect}"
    end
  end

  def download(zoom, x, y)
    throttle!
    uri = URI(tile_url(zoom, x, y))
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = USER_AGENT

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
    raise "Tile fetch failed (#{response.code}) for #{uri}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  def throttle!
    if @last_request_at
      elapsed = Time.now - @last_request_at
      sleep(MIN_REQUEST_INTERVAL - elapsed) if elapsed < MIN_REQUEST_INTERVAL
    end
    @last_request_at = Time.now
  end
end

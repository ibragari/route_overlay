# frozen_string_literal: true

require "net/http"
require "uri"
require "fileutils"
require "chunky_png"

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
    @image_cache = {}
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

  # Same as fetch, but returns a decoded ChunkyPNG::Image, kept in an
  # in-memory cache for the lifetime of this TileFetcher. Consecutive local
  # mosaics built for a clip's reveal runs (see MosaicRenderer) overlap
  # heavily -- the same handful of tiles get reused across most of them --
  # so without this, the same on-disk PNG gets re-read and re-decoded from
  # scratch every time it's needed, which was dwarfing the actual render
  # time. ChunkyPNG's Canvas#replace! only ever reads from its source image,
  # never mutates it, so sharing one decoded instance across many canvases
  # is safe.
  def fetch_image(zoom, x, y)
    key = [zoom, x, y]
    @image_cache[key] ||= ChunkyPNG::Image.from_file(fetch(zoom, x, y))
  end

  # Same idea as fetch_image, but returns a decoded Vips::Image instead, for
  # VipsMosaicRenderer. Only ever called once vips is confirmed available
  # (see VipsSupport) -- doesn't require "vips" itself.
  def fetch_vips_image(zoom, x, y)
    key = [zoom, x, y]
    @vips_image_cache ||= {}
    @vips_image_cache[key] ||= Vips::Image.new_from_file(fetch(zoom, x, y))
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

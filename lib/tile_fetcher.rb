# frozen_string_literal: true

require "net/http"
require "uri"
require "fileutils"
require_relative "web_mercator"

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

  # Ensures every tile in [x_from..x_to] x [y_from..y_to] is downloaded and
  # cached on disk (a no-op per-tile if already cached). Called up front, so
  # mosaic construction (VipsMosaicRenderer#initialize) reads from an
  # already-warm cache and is pure stitching -- letting the caller time and
  # report tile-fetch time and stitch time separately instead of them being
  # interleaved (and thus indistinguishable) tile by tile.
  def prefetch(zoom, x_from, x_to, y_from, y_to)
    (y_from..y_to).each { |ty| (x_from..x_to).each { |tx| fetch(zoom, tx, ty) } }
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

  # Same as fetch, but returns a decoded Vips::Image, kept in an in-memory
  # cache for the lifetime of this TileFetcher. Consecutive mosaics built
  # for a clip overlap heavily -- the same handful of tiles get reused
  # across most of them -- so without this, the same on-disk PNG gets
  # re-read and re-decoded from scratch every time it's needed, which was
  # dwarfing the actual render time. Only ever called once vips is
  # confirmed available (see VipsSupport) -- doesn't require "vips" itself.
  def fetch_image(zoom, x, y)
    key = [zoom, x, y]
    @image_cache[key] ||= Vips::Image.new_from_file(fetch(zoom, x, y))
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
    # A 404 for one specific tile means the provider genuinely has no data
    # there -- confirmed a real, permanent gap (not a transient error): at
    # high zoom, a tile can 404 even though its lower-zoom parent exists.
    # That's a content-level response, not a fetch failure, so it shouldn't
    # abort the whole render -- but leaving it fully blank turned out to be
    # a real visual problem in practice: at a deep zoom, missing tiles
    # cluster (a whole area a renderer skipped, not one random gap), so a
    # clip whose crop window happens to overlap that cluster showed a large
    # blank patch instead of a small one. Falling back to the tile's parent
    # (see fallback_from_parent) -- cropping the matching quadrant and
    # upscaling it 2x -- is what every serious map client does for exactly
    # this case, and gives real (just lower-resolution) content instead of
    # nothing. Any other non-success status (5xx, network trouble, etc.)
    # still raises as before -- those aren't "no data here", they're
    # something actually wrong.
    return fallback_from_parent(zoom, x, y) if response.is_a?(Net::HTTPNotFound)
    raise "Tile fetch failed (#{response.code}) for #{uri}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  # zoom 0 has no parent to fall back to -- true dead end, use a transparent
  # placeholder. Otherwise fetch(...) on the parent (zoom-1, x/2, y/2) --
  # itself falling back further if THAT'S missing too, so a whole cluster of
  # missing zoom levels still bottoms out on real content eventually -- then
  # crop the quarter of it this tile corresponds to and scale that back up
  # to a full TILE_SIZE tile.
  def fallback_from_parent(zoom, x, y)
    return blank_tile_png if zoom.zero?

    parent_path = fetch(zoom - 1, x / 2, y / 2)
    parent = Vips::Image.new_from_file(parent_path)
    half = WebMercator::TILE_SIZE / 2
    quadrant = parent.extract_area((x % 2) * half, (y % 2) * half, half, half)
    quadrant.resize(2).write_to_buffer(".png")
  end

  def blank_tile_png
    @blank_tile_png ||= Vips::Image.black(WebMercator::TILE_SIZE, WebMercator::TILE_SIZE, bands: 4)
                                    .cast(:uchar).write_to_buffer(".png")
  end

  def throttle!
    if @last_request_at
      elapsed = Time.now - @last_request_at
      sleep(MIN_REQUEST_INTERVAL - elapsed) if elapsed < MIN_REQUEST_INTERVAL
    end
    @last_request_at = Time.now
  end
end

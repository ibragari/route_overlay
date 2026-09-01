# frozen_string_literal: true

require "vips"
require_relative "web_mercator"

# Builds one small stitched-tile mosaic centered on a lon/lat point (see
# tile_radius), and draws the route on it in a single color -- one instance
# covers one clip's own portion of the trip, not the whole trip, so a long
# multi-hour trip doesn't blow this up. Backed by libvips throughout this
# project (see vips_support.rb, overlay_generator.rb's startup check) for
# the tile-stitching + route-drawing + PNG-encoding this does once per clip.
#
# vips images are immutable -- operations like `insert` return a new image
# rather than modifying one in place, and drawing requires an explicit
# `mutate` block (a temporary writable copy, yielding a new immutable image
# once it ends) -- so with_route never modifies @canvas itself, no
# defensive clone needed.
class VipsMosaicRenderer
  attr_reader :canvas, :zoom, :origin_tile_x, :origin_tile_y

  def initialize(tile_fetcher, zoom:, center_lon:, center_lat:, tile_radius:)
    @tile_fetcher = tile_fetcher
    @zoom = zoom

    @origin_tile_x, @origin_tile_y, last_tile_x, last_tile_y = WebMercator.tile_range(zoom, center_lon, center_lat,
                                                                                       tile_radius)

    width = (last_tile_x - @origin_tile_x + 1) * WebMercator::TILE_SIZE
    height = (last_tile_y - @origin_tile_y + 1) * WebMercator::TILE_SIZE
    canvas = Vips::Image.black(width, height, bands: 4).cast(:uchar)

    (@origin_tile_y..last_tile_y).each do |ty|
      (@origin_tile_x..last_tile_x).each do |tx|
        tile_image = @tile_fetcher.fetch_image(zoom, tx, ty)
        tile_image = tile_image.bandjoin(255) if tile_image.bands == 3
        canvas = canvas.insert(tile_image, (tx - @origin_tile_x) * WebMercator::TILE_SIZE,
                                (ty - @origin_tile_y) * WebMercator::TILE_SIZE)
      end
    end
    @canvas = canvas
  end

  def to_pixel(lon, lat)
    x = WebMercator.lon_to_x(lon, @zoom) - (@origin_tile_x * WebMercator::TILE_SIZE)
    y = WebMercator.lat_to_y(lat, @zoom) - (@origin_tile_y * WebMercator::TILE_SIZE)
    [x, y]
  end

  # Draws the route (in a single color) on this mosaic and returns a new
  # image. pixel_point_runs is an array of point-arrays, each drawn as its
  # own connected polyline -- more than one run happens when
  # route.privacy_zones splits the trip's points around a zone (see
  # overlay_generator.rb's route_runs), so the line stops before it and
  # resumes after rather than jumping straight across the gap. Typically
  # covers the whole trip's points; ones outside this mosaic's bounds are
  # silently dropped by vips' drawing ops, so there's no need to pre-filter
  # for that.
  #
  # alpha (route.track_line_alpha, 0.0-1.0) is applied to the whole route at
  # once: below 1.0, the route is drawn fully opaque onto a separate
  # transparent layer first, that layer's alpha is scaled uniformly, and
  # only then is it composited onto the mosaic -- not by drawing with a
  # semi-transparent color directly, which would visibly "build up" darker
  # wherever the line/rect stamps in draw_thick_polyline overlap.
  def with_route(pixel_point_runs, color, width_px, alpha = 1.0)
    if alpha >= 1.0
      return pixel_point_runs.reduce(@canvas) { |canvas, points| draw_thick_polyline(canvas, points, color, width_px) }
    end

    blank = Vips::Image.black(@canvas.width, @canvas.height, bands: 4).cast(:uchar)
    route_layer = pixel_point_runs.reduce(blank) { |canvas, points| draw_thick_polyline(canvas, points, color, width_px) }
    route_layer = scale_alpha(route_layer, alpha)
    @canvas.copy(interpretation: :srgb).composite(route_layer.copy(interpretation: :srgb), :over)
  end

  private

  def scale_alpha(image, alpha)
    rgb = image.extract_band(0, n: image.bands - 1)
    a = (image.extract_band(image.bands - 1) * alpha).cast(:uchar)
    rgb.bandjoin(a)
  end

  def draw_thick_polyline(canvas, pixel_points, color, width_px)
    half = (width_px / 2.0).floor
    rgba = parse_hex_color(color)

    canvas.mutate do |m|
      pixel_points.each_cons(2) do |(x0, y0), (x1, y1)|
        m.draw_line!(rgba, x0.round, y0.round, x1.round, y1.round)
        next if half.zero?

        steps = [(x1 - x0).abs.round, (y1 - y0).abs.round, 1].max
        steps.times do |i|
          t = i / steps.to_f
          stamp_square!(m, rgba, x0 + ((x1 - x0) * t), y0 + ((y1 - y0) * t), half)
        end
      end
      last = pixel_points.last
      stamp_square!(m, rgba, last[0], last[1], half) if last && !half.zero?
    end
  end

  def stamp_square!(mutable, rgba, x, y, half)
    x, y = x.round, y.round
    mutable.draw_rect!(rgba, x - half, y - half, (2 * half) + 1, (2 * half) + 1, fill: true)
  end

  def parse_hex_color(hex)
    h = hex.delete("#")
    [h[0, 2].to_i(16), h[2, 2].to_i(16), h[4, 2].to_i(16), h.length >= 8 ? h[6, 2].to_i(16) : 255]
  end
end

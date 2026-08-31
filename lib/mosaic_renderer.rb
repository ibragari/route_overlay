# frozen_string_literal: true

require "chunky_png"
require_relative "web_mercator"

# Builds one small stitched-tile canvas centered on a lon/lat point, covering
# tile_radius tiles in every direction, and draws the route on it in a single
# color -- one instance covers one clip's own portion of the trip (sized to
# comfortably contain it plus the visible pan radius), not the whole trip,
# so a long multi-hour trip doesn't blow this up the way rendering the whole
# trip as one mosaic would.
#
# The route color is expected to be fully opaque. Route/marker drawing works
# by drawing a connecting line for each path segment, stamping filled
# squares on top of it for width beyond 1px (see draw_thick_polyline!) --
# with a semi-transparent color, overlapping stamps would visibly "build up"
# darker at every overlap, so opacity is applied once, at compositing time,
# rather than baked into these colors.
class MosaicRenderer
  attr_reader :canvas, :zoom, :origin_tile_x, :origin_tile_y

  def initialize(tile_fetcher, zoom:, center_lon:, center_lat:, tile_radius:)
    @tile_fetcher = tile_fetcher
    @zoom = zoom

    center_tile_x = (WebMercator.lon_to_x(center_lon, zoom) / WebMercator::TILE_SIZE).floor
    center_tile_y = (WebMercator.lat_to_y(center_lat, zoom) / WebMercator::TILE_SIZE).floor

    @origin_tile_x = center_tile_x - tile_radius
    @origin_tile_y = center_tile_y - tile_radius
    last_tile_x = center_tile_x + tile_radius
    last_tile_y = center_tile_y + tile_radius

    @canvas = ChunkyPNG::Canvas.new(
      (last_tile_x - @origin_tile_x + 1) * WebMercator::TILE_SIZE,
      (last_tile_y - @origin_tile_y + 1) * WebMercator::TILE_SIZE,
      ChunkyPNG::Color::TRANSPARENT
    )

    (@origin_tile_y..last_tile_y).each do |ty|
      (@origin_tile_x..last_tile_x).each do |tx|
        tile_image = @tile_fetcher.fetch_image(zoom, tx, ty)
        @canvas.replace!(tile_image, (tx - @origin_tile_x) * WebMercator::TILE_SIZE,
                          (ty - @origin_tile_y) * WebMercator::TILE_SIZE)
      end
    end
  end

  # Converts a lon/lat to this mosaic's local pixel coordinates, in the
  # NATIVE (non-supersampled) canvas -- used for drawing directly onto
  # @canvas. For crop positions in the ffmpeg-upscaled stream, multiply by
  # supersample separately (see overlay_generator.rb).
  def to_pixel(lon, lat)
    x = WebMercator.lon_to_x(lon, @zoom) - @origin_tile_x * WebMercator::TILE_SIZE
    y = WebMercator.lat_to_y(lat, @zoom) - @origin_tile_y * WebMercator::TILE_SIZE
    [x, y]
  end

  # Draws a solid connecting line for each segment (a real line-drawing
  # algorithm, so it's always fully connected -- no gaps, no degenerate
  # cases) and, for any width beyond a bare 1px line, additionally stamps
  # filled squares along the path to thicken it. Deliberately a square via
  # `rect` rather than `circle`: ChunkyPNG's circle algorithm has a
  # degenerate case at radius 1 (only 4 disconnected corner pixels around an
  # empty, unfilled center) -- stamping that repeatedly along a path is what
  # produced a perforated, "dashed" look for a thin (line_width_px: 2)
  # route; `rect`'s fill has no such small-size edge case.
  def draw_thick_polyline!(canvas, pixel_points, color, width_px)
    half = (width_px / 2.0).floor
    pixel_points.each_cons(2) do |(x0, y0), (x1, y1)|
      canvas.line(x0.round, y0.round, x1.round, y1.round, color)
      next if half.zero?

      steps = [(x1 - x0).abs.round, (y1 - y0).abs.round, 1].max
      steps.times do |i|
        t = i / steps.to_f
        x = (x0 + ((x1 - x0) * t)).round
        y = (y0 + ((y1 - y0) * t)).round
        canvas.rect(x - half, y - half, x + half, y + half, color, color)
      end
    end
    last = pixel_points.last
    if last && !half.zero?
      x, y = last[0].round, last[1].round
      canvas.rect(x - half, y - half, x + half, y + half, color, color)
    end
    canvas
  end

  # Draws the route (in a single color) on a fresh copy of this mosaic and
  # returns it. pixel_points is typically the whole trip's points -- ones
  # that land outside this mosaic's bounds are silently dropped by
  # ChunkyPNG's drawing ops, so there's no need to pre-filter them.
  def with_route(pixel_points, color, width_px)
    variant = @canvas.crop(0, 0, @canvas.width, @canvas.height) # non-mutating clone
    draw_thick_polyline!(variant, pixel_points, color, width_px)
    variant
  end
end

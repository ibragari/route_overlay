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

    @origin_tile_x, @origin_tile_y, last_tile_x, last_tile_y = WebMercator.tile_range(zoom, center_lon, center_lat,
                                                                                       tile_radius)

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
  # returns it. pixel_point_runs is an array of point-arrays, each drawn as
  # its own connected polyline -- more than one run happens when
  # route.privacy_zones splits the trip's points around a zone (see
  # overlay_generator.rb's route_runs), so the line stops before it and
  # resumes after rather than jumping straight across the gap. Typically
  # covers the whole trip's points -- ones that land outside this mosaic's
  # bounds are silently dropped by ChunkyPNG's drawing ops, so there's no
  # need to pre-filter for that.
  #
  # alpha (route.track_line_alpha, 0.0-1.0) is applied to the whole route at
  # once: below 1.0, the route is drawn fully opaque onto a separate
  # transparent layer first, that layer's alpha is scaled uniformly, and
  # only then is it composited onto the mosaic -- not by drawing with a
  # semi-transparent color directly, which would visibly "build up" darker
  # wherever the line/rect stamps in draw_thick_polyline! overlap.
  def with_route(pixel_point_runs, color, width_px, alpha = 1.0)
    variant = @canvas.crop(0, 0, @canvas.width, @canvas.height) # non-mutating clone
    if alpha >= 1.0
      pixel_point_runs.each { |points| draw_thick_polyline!(variant, points, color, width_px) }
      return variant
    end

    route_layer = ChunkyPNG::Canvas.new(@canvas.width, @canvas.height, ChunkyPNG::Color::TRANSPARENT)
    pixel_point_runs.each { |points| draw_thick_polyline!(route_layer, points, color, width_px) }
    scale_alpha!(route_layer, alpha)
    variant.compose!(route_layer)
    variant
  end

  private

  def scale_alpha!(canvas, alpha)
    canvas.pixels.map! do |pixel|
      a = pixel & 0xff
      next pixel if a.zero?

      (pixel & 0xffffff00) | (a * alpha).round
    end
  end
end

# frozen_string_literal: true

require "chunky_png"
require_relative "web_mercator"

# Builds one small stitched-tile canvas centered on a lon/lat point, covering
# tile_radius tiles in every direction (so every instance built with the same
# tile_radius is pixel-for-pixel the same size, regardless of where it's
# centered -- needed so ffmpeg's concat demuxer can splice a sequence of
# these together as one uniform-frame-size stream), and draws whatever
# portion of the route falls within it in two tones, traveled vs upcoming.
#
# One instance covers one "reveal run" (see FramePlanner.reveal_runs) rather
# than the whole trip -- a run's pan only ever needs the area around that
# run's own couple of GPS points, not the entire route, so building one
# mosaic per run keeps each one small no matter how long the overall trip is.
#
# Route colors are expected to be fully opaque. Route/marker drawing works by
# stamping many overlapping circles along the path (see draw_thick_polyline!)
# -- with a semi-transparent color, overlapping stamps would visibly "build
# up" darker at every overlap, so opacity is applied once, at compositing
# time, rather than baked into these colors.
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
        tile_path = @tile_fetcher.fetch(zoom, tx, ty)
        tile_image = ChunkyPNG::Image.from_file(tile_path)
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

  def draw_thick_polyline!(canvas, pixel_points, color, width_px)
    radius = [(width_px / 2.0).round, 1].max
    pixel_points.each_cons(2) do |(x0, y0), (x1, y1)|
      steps = [(x1 - x0).abs.round, (y1 - y0).abs.round, 1].max
      steps.times do |i|
        t = i / steps.to_f
        x = (x0 + ((x1 - x0) * t)).round
        y = (y0 + ((y1 - y0) * t)).round
        canvas.circle(x, y, radius, color, color)
      end
    end
    last = pixel_points.last
    canvas.circle(last[0].round, last[1].round, radius, color, color) if last
    canvas
  end

  # Renders whichever nearby route points fall in this mosaic in
  # upcoming_color onto a fresh copy of it and returns it -- points outside
  # the canvas are silently dropped by ChunkyPNG's drawing ops, so passing in
  # more points than strictly fit is harmless.
  def base_with_upcoming_route(nearby_pixel_points, color, width_px)
    base = @canvas.crop(0, 0, @canvas.width, @canvas.height) # non-mutating clone
    draw_thick_polyline!(base, nearby_pixel_points, color, width_px)
    base
  end

  # Given the shared base (from base_with_upcoming_route) and the pixel
  # points traveled so far (a prefix of nearby_pixel_points), returns a new
  # canvas with the traveled portion highlighted on top.
  def with_traveled_route(base, traveled_pixel_points, color, width_px)
    variant = base.crop(0, 0, base.width, base.height)
    draw_thick_polyline!(variant, traveled_pixel_points, color, width_px) if traveled_pixel_points.size > 1
    variant
  end
end

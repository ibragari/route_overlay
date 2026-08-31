# frozen_string_literal: true

require "chunky_png"

# Builds the static, once-per-render PNG assets for the map inset: an alpha
# mask (for clipping the map's corners to the chosen shape via ffmpeg's
# alphamerge), a border ring, and the fixed center position marker.
module InsetAssets
  module_function

  # True if pixel (x, y) on a `size`x`size` canvas falls inside a rounded
  # rectangle of corner radius `radius`, itself inset by `inset` pixels from
  # every edge (inset > 0 shrinks the shape inward -- used to carve the ring
  # for the border by subtracting an inner shape from the outer one).
  def inside_rounded_rect?(x, y, size, radius, inset)
    lo = inset
    hi = size - 1 - inset
    return false if x < lo || x > hi || y < lo || y > hi

    r = [radius - inset, 0].max
    dx = x < lo + r ? (lo + r) - x : (x > hi - r ? x - (hi - r) : 0)
    dy = y < lo + r ? (lo + r) - y : (y > hi - r ? y - (hi - r) : 0)
    dx.zero? || dy.zero? || ((dx * dx) + (dy * dy) <= r * r)
  end

  def corner_radius_for(shape, size, configured_radius)
    case shape
    when "circle" then size / 2
    when "rect" then 0
    else configured_radius # rounded_rect
    end
  end

  # Grayscale (opaque) mask: white = map visible, black = clipped away.
  # Consumed by ffmpeg's alphamerge, which reads luma regardless of alpha.
  def build_mask(size, shape, corner_radius, supersample: 2)
    big = size * supersample
    big_radius = corner_radius * supersample
    canvas = ChunkyPNG::Canvas.new(big, big, ChunkyPNG::Color::BLACK)
    (0...big).each do |y|
      (0...big).each do |x|
        canvas[x, y] = ChunkyPNG::Color::WHITE if inside_rounded_rect?(x, y, big, big_radius, 0)
      end
    end
    canvas.resample_bilinear(size, size)
  end

  # Transparent RGBA ring in border_color, border_width_px wide, following
  # the same shape as the mask.
  def build_border(size, shape, corner_radius, border_width_px, border_color, supersample: 2)
    big = size * supersample
    big_radius = corner_radius * supersample
    big_width = [border_width_px * supersample, 1].max
    color = ChunkyPNG::Color.parse(border_color)
    canvas = ChunkyPNG::Canvas.new(big, big, ChunkyPNG::Color::TRANSPARENT)
    (0...big).each do |y|
      (0...big).each do |x|
        outer = inside_rounded_rect?(x, y, big, big_radius, 0)
        inner = inside_rounded_rect?(x, y, big, big_radius, big_width)
        canvas[x, y] = color if outer && !inner
      end
    end
    canvas.resample_bilinear(size, size)
  end

  # Chevron/arrow marker pointing due "up" (i.e. toward course 0 degrees),
  # meant to be rotated per-frame by ffmpeg's `rotate` filter to match
  # current heading. Canvas is sized so the shape stays fully inside it at
  # any rotation angle (half-size >= farthest vertex distance from center),
  # so `rotate`'s fillcolor for exposed corners is never actually sampled.
  def build_marker(radius_px, color, outline_color, outline_width_px)
    canvas_size = (2 * (radius_px + outline_width_px)) + 2
    center = canvas_size / 2.0
    canvas = ChunkyPNG::Canvas.new(canvas_size, canvas_size, ChunkyPNG::Color::TRANSPARENT)
    fill = ChunkyPNG::Color.parse(color)
    outline = ChunkyPNG::Color.parse(outline_color)

    outer = chevron_path(center, radius_px + outline_width_px)
    inner = chevron_path(center, radius_px)
    canvas.polygon(outer, outline, outline)
    canvas.polygon(inner, fill, fill)
    canvas
  end

  # Isoceles chevron/arrow path pointing "up": a sharp tip, swept-back wings,
  # and a concave notch at the back (the classic nav-arrow silhouette).
  # Flat [x1, y1, x2, y2, ...] array -- ChunkyPNG::Vector's array parser
  # relies on Object#=~ for anything but a flat numeric array or a string,
  # and that method no longer exists as of Ruby 3.2, so [[x,y], ...] pairs
  # crash; a flat numeric array takes the (working) numeric-array path.
  def chevron_path(center, radius)
    [
      center, center - radius,
      center + (radius * 0.75), center + (radius * 0.6),
      center, center + (radius * 0.25),
      center - (radius * 0.75), center + (radius * 0.6)
    ]
  end
end

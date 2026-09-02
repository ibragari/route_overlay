# frozen_string_literal: true

# Builds the static, once-per-render assets for the map inset: an alpha
# mask (for clipping the map's corners to the chosen shape via ffmpeg's
# alphamerge), a border ring, and the fixed center position marker. All via
# libvips (draw ops for the mask/border, SVG rendering for the marker's
# chevron polygon) -- these were originally pure-Ruby chunky_png, measured
# at ~2.5s/clip combined (build_mask + build_border) for a 650px inset,
# almost entirely pixel-loop and resample overhead that vips does in a
# fraction of the time.
module InsetAssets
  module_function

  def corner_radius_for(shape, size, configured_radius)
    case shape
    when "circle" then size / 2
    when "rect" then 0
    else configured_radius # rounded_rect
    end
  end

  # A rounded rect of corner radius r, inset by `inset` pixels from every
  # edge of a big x big canvas (inset > 0 shrinks the whole shape inward,
  # not just the corner radius -- mirrors the old pixel-formula's `inset`
  # parameter, used by build_border to carve the ring by subtracting an
  # inner shape from the outer one), is the union of two rects (full-span
  # horizontally inset by r, and full-span vertically inset by r, both
  # within the inset-shrunk [inset, big-inset) bounds) plus 4 filled
  # circles of radius r at each corner center. Degenerates correctly at
  # both extremes corner_radius_for can produce: r=0 (rect -- circles
  # vanish, the two rects collapse into one full inset-bounded square) and
  # r=span/2 (circle -- all 4 corner centers coincide at the shape's own
  # center, so the 4 circles collapse into one full circle). Verified
  # against the pixel-exact old formula (inside_rounded_rect?) before this
  # was wired in, at several (r, inset) combinations including a real
  # border case -- matches everywhere except right at the outer boundary
  # (vips' circle rasterizer rounds the edge slightly differently),
  # invisible after the supersample-then-downsample step below.
  def rounded_rect_mask(big, r, inset: 0)
    canvas = Vips::Image.black(big, big, bands: 1).cast(:uchar)
    canvas.mutate do |m|
      lo = inset
      span = big - (2 * inset)
      in_w = span - (2 * r)
      if in_w.positive?
        m.draw_rect!([255], lo + r, lo, in_w, span, fill: true)
        m.draw_rect!([255], lo, lo + r, span, in_w, fill: true)
      elsif !r.positive? && span.positive?
        # Only the true rect case (r <= 0) wants this full-square fallback.
        # r == span/2 (circle) also lands here since in_w is exactly 0 then,
        # but must NOT fill the square -- it relies entirely on the 4
        # corner circles below, which coincide into one full circle.
        m.draw_rect!([255], lo, lo, span, span, fill: true)
      end
      next unless r.positive?

      [[lo + r, lo + r], [big - lo - r, lo + r], [lo + r, big - lo - r], [big - lo - r, big - lo - r]].each do |cx, cy|
        m.draw_circle!([255], cx, cy, r, fill: true)
      end
    end
  end
  private_class_method :rounded_rect_mask

  # Grayscale (opaque) mask: white = map visible, black = clipped away.
  # Consumed by ffmpeg's alphamerge, which reads luma regardless of alpha.
  def build_mask(size, shape, corner_radius, supersample: 2)
    big = size * supersample
    big_radius = corner_radius * supersample
    rounded_rect_mask(big, big_radius).thumbnail_image(size, height: size, size: :force)
  end

  # Transparent RGBA ring in border_color, border_width_px wide, following
  # the same shape as the mask -- the outer shape minus a shape shrunk
  # inward by border_width_px, recolored to border_color via the ring
  # (0/255) as the alpha band.
  def build_border(size, shape, corner_radius, border_width_px, border_color, supersample: 2)
    big = size * supersample
    big_radius = corner_radius * supersample
    big_width = [border_width_px * supersample, 1].max

    outer = rounded_rect_mask(big, big_radius)
    inner = rounded_rect_mask(big, [big_radius - big_width, 0].max, inset: big_width)
    ring = outer & ~inner # boolean AND-NOT: opaque exactly where outer is set and inner is not

    r, g, b = parse_rgb(border_color)
    rgba = (Vips::Image.black(big, big, bands: 3) + [r, g, b]).cast(:uchar)
    rgba.bandjoin(ring).thumbnail_image(size, height: size, size: :force)
  end

  # Chevron/arrow marker pointing due "up" (i.e. toward course 0 degrees),
  # meant to be rotated per-frame by ffmpeg's `rotate` filter to match
  # current heading. Canvas is sized so the shape stays fully inside it at
  # any rotation angle (half-size >= farthest vertex distance from center),
  # so `rotate`'s fillcolor for exposed corners is never actually sampled.
  def build_marker(radius_px, color, outline_color, outline_width_px)
    canvas_size = (2 * (radius_px + outline_width_px)) + 2
    center = canvas_size / 2.0
    outer = chevron_path(center, radius_px + outline_width_px)
    inner = chevron_path(center, radius_px)

    svg = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{canvas_size}" height="#{canvas_size}">
        <polygon points="#{points_str(outer)}" fill="#{outline_color}"/>
        <polygon points="#{points_str(inner)}" fill="#{color}"/>
      </svg>
    SVG
    Vips::Image.svgload_buffer(svg)
  end

  # Isoceles chevron/arrow path pointing "up": a sharp tip, swept-back wings,
  # and a concave notch at the back (the classic nav-arrow silhouette).
  # Flat [x1, y1, x2, y2, ...] array, paired up into "x,y x,y ..." for SVG
  # <polygon points="...">  by points_str below.
  def chevron_path(center, radius)
    [
      center, center - radius,
      center + (radius * 0.75), center + (radius * 0.6),
      center, center + (radius * 0.25),
      center - (radius * 0.75), center + (radius * 0.6)
    ]
  end

  def points_str(flat)
    flat.each_slice(2).map { |x, y| "#{x},#{y}" }.join(" ")
  end
  private_class_method :points_str

  def parse_rgb(hex)
    h = hex.delete("#")
    [h[0, 2].to_i(16), h[2, 2].to_i(16), h[4, 2].to_i(16)]
  end
  private_class_method :parse_rgb
end

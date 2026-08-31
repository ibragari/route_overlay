# frozen_string_literal: true

# Standard Web Mercator / OSM slippy-map tile math: lon/lat <-> global pixel
# coordinates at a given zoom level (256px tiles), plus helpers for picking
# an integer zoom level that best matches a desired real-world scale.
module WebMercator
  TILE_SIZE = 256
  EARTH_CIRCUMFERENCE_M = 40_075_016.686

  module_function

  def lon_to_x(lon, zoom)
    (lon + 180.0) / 360.0 * (2**zoom) * TILE_SIZE
  end

  def lat_to_y(lat, zoom)
    lat_rad = lat * Math::PI / 180.0
    n = 2**zoom
    (1.0 - Math.log(Math.tan(lat_rad) + 1.0 / Math.cos(lat_rad)) / Math::PI) / 2.0 * n * TILE_SIZE
  end

  def x_to_lon(x, zoom)
    x / (TILE_SIZE.to_f * 2**zoom) * 360.0 - 180.0
  end

  def y_to_lat(y, zoom)
    n = Math::PI - 2.0 * Math::PI * y / (TILE_SIZE.to_f * 2**zoom)
    (Math.atan(Math.sinh(n))) * 180.0 / Math::PI
  end

  def meters_per_pixel(lat, zoom)
    (EARTH_CIRCUMFERENCE_M * Math.cos(lat * Math::PI / 180.0)) / (TILE_SIZE * 2**zoom)
  end

  # Returns [zoom, actual_meters_per_pixel] for the integer zoom whose scale
  # is closest to desired_mpp at the given latitude, clamped to OSM's usual
  # 0..19 range.
  def best_zoom_for_scale(desired_mpp, lat)
    ideal_zoom = Math.log2((EARTH_CIRCUMFERENCE_M * Math.cos(lat * Math::PI / 180.0)) / (TILE_SIZE * desired_mpp))
    zoom = ideal_zoom.round.clamp(0, 19)
    [zoom, meters_per_pixel(lat, zoom)]
  end
end

# frozen_string_literal: true

# Computes, for each output frame of a clip's overlay, the interpolated
# lon/lat of the current position and the index of the last real GPX
# trackpoint reached (reveal_index -- -1 before the trip's very first fix,
# see overlay_generator.rb's blank leading frames). Both are derived from a
# single monotonic sweep since frame time only ever increases.
class FramePlanner
  FrameState = Struct.new(:frame_index, :lon, :lat, :speed_kmh, :course_deg, :reveal_index, keyword_init: true)

  def initialize(trip_points)
    @points = trip_points
  end

  # Returns an Array of FrameState, one per frame, for frames
  # start_time + i/fps, i in 0...total_frames.
  def frame_states(start_time, fps, total_frames)
    idx = 0
    last_idx = @points.size - 1

    Array.new(total_frames) do |i|
      t_abs = start_time + (i / fps.to_f)

      idx += 1 while idx < last_idx && @points[idx + 1].time <= t_abs

      if t_abs <= @points.first.time
        p = @points.first
        FrameState.new(frame_index: i, lon: p.lon, lat: p.lat, speed_kmh: p.speed_kmh || 0.0,
                        course_deg: p.course || 0.0, reveal_index: -1)
      elsif idx == last_idx
        p = @points[idx]
        FrameState.new(frame_index: i, lon: p.lon, lat: p.lat, speed_kmh: p.speed_kmh || 0.0,
                        course_deg: p.course || 0.0, reveal_index: idx)
      else
        p0, p1 = @points[idx], @points[idx + 1]
        span = p1.time - p0.time
        frac = span.zero? ? 0.0 : (((t_abs - p0.time) / span).clamp(0.0, 1.0))
        lon = p0.lon + ((p1.lon - p0.lon) * frac)
        lat = p0.lat + ((p1.lat - p0.lat) * frac)
        speed = (p0.speed_kmh || 0.0) + (((p1.speed_kmh || 0.0) - (p0.speed_kmh || 0.0)) * frac)
        course = lerp_angle_deg(p0.course || 0.0, p1.course || 0.0, frac)
        FrameState.new(frame_index: i, lon: lon, lat: lat, speed_kmh: speed, course_deg: course, reveal_index: idx)
      end
    end
  end

  private

  # Interpolates between two compass bearings (0..360) the short way around,
  # so e.g. 350 -> 10 sweeps through 360/0 (a 20-degree turn) instead of
  # wrongly averaging through 180 (a naive lerp would treat it as a
  # 340-degree turn the other way).
  def lerp_angle_deg(a0, a1, frac)
    diff = ((a1 - a0 + 540) % 360) - 180
    (a0 + (diff * frac)) % 360
  end
end

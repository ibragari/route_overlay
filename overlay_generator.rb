#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders a transparent map-inset overlay video (route + moving position,
# north-up, panning under a fixed center marker) for one dashcam clip, or
# for every clip in a trip, from the settings in overlay_config.yml.
#
# See README-ish comments in lib/*.rb for the mechanics: Ruby builds one
# static map image per clip (tiles stitched, route drawn on top once), then
# ffmpeg does all the per-frame compositing -- panning via a generated
# sendcmd script driving its crop position, marker rotation the same way.

require "optparse"
require "fileutils"
require_relative "lib/overlay_config"
require_relative "lib/novatek_gps"
require_relative "lib/gpx_reader"
require_relative "lib/web_mercator"
require_relative "lib/tile_fetcher"
require_relative "lib/mosaic_renderer"
require_relative "lib/vips_support"
require_relative "lib/frame_planner"
require_relative "lib/inset_assets"

# Mosaic building (tile stitching, route drawing, PNG encoding) is by far
# the hottest path in this script, run hundreds of times per clip -- vips is
# dramatically faster at it than pure-Ruby chunky_png, so use it whenever
# it's actually available (see lib/vips_support.rb for what that requires)
# and silently fall back to the always-available chunky_png-based
# MosaicRenderer otherwise. Both classes share the same interface.
if VipsSupport.available?
  require_relative "lib/vips_mosaic_renderer"
  MOSAIC_RENDERER_CLASS = VipsMosaicRenderer
  puts "[mosaic backend] libvips"
else
  MOSAIC_RENDERER_CLASS = MosaicRenderer
  puts "[mosaic backend] chunky_png (pure Ruby, slower -- see lib/vips_support.rb to speed this up)"
end

def ffprobe_duration_seconds(path)
  out = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "#{path}"`
  raise "ffprobe failed for #{path}" unless $CHILD_STATUS&.success?

  out.strip.to_f
end

def resolve(base_dir, relative_or_absolute)
  File.expand_path(relative_or_absolute, base_dir)
end

# Makes sure trip.gpx_file exists and is at least as new as every clip in
# trip.clips_dir, (re-)running the same extraction gps_extractor.rb does if
# not -- so a fresh set of clips, or clips added/replaced since the last
# extraction, doesn't silently render against a stale track.
def ensure_trip_gpx(config, run_dir)
  gpx_path = resolve(run_dir, config.trip.gpx_file)
  clips_dir = resolve(run_dir, config.trip.clips_dir)
  clip_paths = Dir.glob(File.join(clips_dir, "*.MP4"), File::FNM_CASEFOLD).sort
  raise "No MP4 clips found in #{clips_dir}" if clip_paths.empty?

  newest_clip_mtime = clip_paths.map { |p| File.mtime(p) }.max
  return gpx_path if File.exist?(gpx_path) && File.mtime(gpx_path) >= newest_clip_mtime

  puts "#{File.exist?(gpx_path) ? 'Re-extracting' : 'Extracting'} GPS from #{clip_paths.size} clip(s) in " \
       "#{clips_dir} -> #{gpx_path}"
  points = NovatekGps.collect_trip(clips_dir, utc_offset_hours: config.trip.utc_offset_hours)
  NovatekGps.write_gpx(points, gpx_path)
  puts "#{points.size} trackpoints (#{points.first.time} to #{points.last.time}) -> #{gpx_path}"

  gpx_path
end

def in_privacy_zone?(point, zones)
  zones.any? do |z|
    dlat = (point.lat - z.center_lat) * 111_320
    dlon = (point.lon - z.center_lon) * 111_320 * Math.cos(point.lat * Math::PI / 180.0)
    Math.sqrt((dlat**2) + (dlon**2)) <= z.radius_meters
  end
end

# Splits trip_points into maximal runs of consecutive points that fall
# outside every configured route.privacy_zones circle, dropping any point
# that falls inside one entirely -- so the route line stops before a zone
# and resumes after it, rather than being drawn through it or jumping
# straight across the gap as one continuous line.
def route_runs(trip_points, zones)
  return [trip_points] if zones.empty?

  runs = []
  current = []
  trip_points.each do |p|
    if in_privacy_zone?(p, zones)
      runs << current unless current.empty?
      current = []
    else
      current << p
    end
  end
  runs << current unless current.empty?
  runs
end

# crop's x/y must land on whole mosaic pixels, so panning precision is
# capped at one mosaic pixel. At realistic (slow) speeds and a tight radius,
# one real second of movement can be under one mosaic pixel, making the pan
# visibly freeze for many frames then jump. Fixed by locally upscaling the
# already-fetched mosaic bitmap (see MosaicRenderer#supersample!) rather
# than fetching genuinely finer tiles -- that would multiply tile-fetch
# cost with the whole trip's bounding box; this is a one-time local resize.
# Applies to any window_mode that pans continuously by vehicle position
# (fixed_radius and dynamic_speed) -- not fixed_zoom, which doesn't pan a
# variable-radius window at all.
PAN_SUPERSAMPLE = 4

# Comfortable margin under the ~2^31-byte (2 GiB) ceiling that trips a
# 32-bit size-overflow guard somewhere in ffmpeg's own image-size validation
# -- found empirically: a dynamic_speed clip whose actual speed profile
# produced a 23x23-tile (5888px) native mosaic failed outright with
# "Picture size 23552x23552 is invalid" at 4x supersample (23552^2*4 bytes
# is ~2.07 GiB, just over that ceiling). fixed_radius's typically small
# configured radius never gets close to this in practice, but dynamic_speed
# mosaics are sized for max_radius_meters, which can be large enough to
# reach it on some clips/trips.
MAX_SUPERSAMPLED_CANVAS_BYTES = 1_500_000_000

# Picks the largest supersample no larger than desired_supersample that
# keeps the final (native_dim_px * supersample) square RGBA canvas under
# MAX_SUPERSAMPLED_CANVAS_BYTES -- falling back to a smaller supersample
# (in the worst case, none at all) instead of crashing. Panning precision
# degrades gracefully rather than failing outright.
def safe_supersample(native_dim_px, desired_supersample)
  candidates = [4, 2, 1].select { |s| s <= desired_supersample }
  candidates.find { |s| (((native_dim_px * s)**2) * 4) <= MAX_SUPERSAMPLED_CANVAS_BYTES } || 1
end

# Picks the mosaic zoom level and the real-world radius (meters) that the
# margin around the trip bbox must cover so panning/zooming never runs past
# the edge of the fetched tiles.
def zoom_and_max_radius(config, avg_lat, inset_size_px)
  case config.map.window_mode
  when "fixed_radius"
    radius = config.map.fixed_radius.radius_meters
    desired_mpp = (2.0 * radius) / inset_size_px
    zoom, actual_mpp = WebMercator.best_zoom_for_scale(desired_mpp, avg_lat)
    [zoom, actual_mpp, radius]
  when "fixed_zoom"
    zoom = config.map.fixed_zoom.zoom_level
    actual_mpp = WebMercator.meters_per_pixel(avg_lat, zoom)
    radius = (actual_mpp * inset_size_px) / 2.0
    [zoom, actual_mpp, radius]
  when "dynamic_speed"
    radius = config.map.dynamic_speed.min_radius_meters
    desired_mpp = (2.0 * radius) / inset_size_px
    zoom, actual_mpp = WebMercator.best_zoom_for_scale(desired_mpp, avg_lat)
    [zoom, actual_mpp, config.map.dynamic_speed.max_radius_meters]
  else
    raise "Unknown map.window_mode #{config.map.window_mode.inspect}"
  end
end

# Real-world radius (meters) to show for the current speed, in dynamic_speed mode.
def current_radius_meters(config, speed_kmh)
  d = config.map.dynamic_speed
  t = (speed_kmh / d.max_speed_kmh.to_f).clamp(0.0, 1.0)
  d.min_radius_meters + ((d.max_radius_meters - d.min_radius_meters) * t)
end

# dynamic_speed only: computes each point's target zoom radius from a
# CENTERED, real-time-windowed average of speed_kmh (not a causal filter),
# then maps that through current_radius_meters. Centering lets the zoom
# start widening/narrowing slightly ahead of a real speed change rather
# than only reacting after it. Computed once, globally, over the whole
# trip's continuous point sequence -- not per clip -- so there is no reset
# and therefore no discontinuity at clip boundaries (clips are just
# different frame ranges over this same, already-smoothed sequence).
# window_seconds <= 0 disables smoothing (uses raw speed_kmh per point).
def assign_dynamic_radii!(trip_points, config, window_seconds)
  trip_points.each_with_index do |p, i|
    speed = if window_seconds.to_f <= 0
              p.speed_kmh || 0.0
            else
              lo = i
              lo -= 1 while lo.positive? && (p.time - trip_points[lo - 1].time) <= window_seconds / 2.0
              hi = i
              hi += 1 while hi < trip_points.size - 1 && (trip_points[hi + 1].time - p.time) <= window_seconds / 2.0
              window_points = trip_points[lo..hi]
              window_points.sum { |wp| wp.speed_kmh || 0.0 } / window_points.size
            end
    p.dynamic_radius_m = current_radius_meters(config, speed)
  end
end

# Crop window size (mosaic pixels) for a given frame, honoring window_mode.
# For dynamic_speed this is the *desired* window for the current speed -- it
# feeds the scale stage, not the crop stage (see outer_crop_size_px).
def crop_size_px(config, actual_mpp, inset_size_px, speed_kmh)
  case config.map.window_mode
  when "fixed_radius"
    ((2.0 * config.map.fixed_radius.radius_meters) / actual_mpp).round
  when "fixed_zoom"
    inset_size_px
  when "dynamic_speed"
    ((2.0 * current_radius_meters(config, speed_kmh)) / actual_mpp).round
  end
end

# dynamic_speed only: the crop filter's window must stay a CONSTANT size
# across all frames (sized for the widest view, max_radius_meters) -- only
# x/y may vary per frame via sendcmd. A varying crop *size* feeding directly
# into alphamerge/overlay hangs ffmpeg outright (reproduced in isolation).
# The actual zoom effect is instead done by a separate, varying `scale`
# stage after this constant crop, followed by a second constant-size crop
# back down to inset_size -- see render_clip's filter_graph.
def outer_crop_size_px(config, actual_mpp)
  ((2.0 * config.map.dynamic_speed.max_radius_meters) / actual_mpp).round
end

# dynamic_speed only: the `scale` stage's per-frame output size that,
# combined with the constant outer crop above, produces an effective window
# of radius_m (the frame's precomputed, already-smoothed target radius --
# see assign_dynamic_radii!) across the final inset_size crop.
def zoom_scale_size_px(config, inset_size_px, radius_m)
  ((inset_size_px.to_f * config.map.dynamic_speed.max_radius_meters) / radius_m).round
end

# ffmpeg's image2 demuxer re-decodes the source file on every single output
# frame under `-loop 1 -r fps -t duration -i path` -- fine for the tiny
# marker/mask/border assets, but 30-60x slower than necessary for the much
# bigger map mosaic (confirmed by isolated timing: 9.7s vs 0.3s for the same
# 600 frames at our real mosaic size). The concat demuxer decodes a file
# once and duplicates the already-decoded frame for its `duration` instead,
# so feed it a single-entry list for the whole clip's length rather than
# looping the file directly.
def write_single_image_concat(path, image_path, duration)
  File.open(path, "w") do |f|
    f.puts "file '#{image_path.gsub('\\', '/')}'"
    f.puts "duration #{format('%.6f', duration)}"
    # concat demuxer quirk: the last (only) image's duration is only honored
    # if the file is listed once more, without a following duration line.
    f.puts "file '#{image_path.gsub('\\', '/')}'"
  end
end

def write_sendcmd(path, frame_states, mosaic, fps, config, actual_mpp, inset_size_px, supersample, stream_w, stream_h)
  dynamic = config.map.window_mode == "dynamic_speed"
  outer_size = dynamic ? [outer_crop_size_px(config, actual_mpp), [stream_w, stream_h].min].min : nil

  File.open(path, "w") do |f|
    frame_states.each do |fs|
      px, py = mosaic.to_pixel(fs.lon, fs.lat)
      px *= supersample
      py *= supersample
      size = dynamic ? outer_size : crop_size_px(config, actual_mpp, inset_size_px, fs.speed_kmh)
      size = [size, [stream_w, stream_h].min].min
      x = (px - (size / 2.0)).round.clamp(0, stream_w - size)
      y = (py - (size / 2.0)).round.clamp(0, stream_h - size)
      t = format("%.6f", fs.frame_index / fps.to_f)
      angle_rad = fs.course_deg * Math::PI / 180.0
      cmds = [+"crop x #{x}", +"crop y #{y}", format("rotate angle %.6f", angle_rad)]
      if dynamic
        scale_size = zoom_scale_size_px(config, inset_size_px, fs.dynamic_radius_m)
        cmds += ["scale w #{scale_size}", "scale h #{scale_size}"]
      end
      f.puts "#{t} #{cmds.join(', ')};"
    end
  end
end

# dynamic_speed only: renders one inset_size x inset_size RGBA raw frame
# (ready for ffmpeg's rawvideo stdin) for a single frame state, by cropping
# variant (the route-drawn, NATIVE-resolution Vips::Image mosaic -- no
# supersampling needed here, see desired_supersample's comment) to the
# exact real-world radius fs.dynamic_radius_m around (fs.lon, fs.lat), then
# resizing that window down to exactly inset_size x inset_size, in a single
# `affine` call with an explicit oarea (rather than extract_area+affine+
# extract_area+thumbnail_image, which was measured to be catastrophically
# slower -- ~48ms/frame vs ~1-2ms/frame -- almost certainly because it
# builds and evaluates a full native-resolution intermediate region on
# every frame before downsampling, instead of letting vips compute only the
# inset_size x inset_size output pixels it actually needs).
#
# Sub-pixel accuracy (the reason PAN_SUPERSAMPLE exists for the ffmpeg-side
# mechanism fixed_radius/fixed_zoom still use) comes from vips' `affine`
# with bilinear interpolation, not from any oversized canvas.
#
# affine's matrix/odx convention here is the INVERSE of what a naive
# "multiply by the forward scale factor" reading suggests -- verified
# empirically against a known gradient image before trusting this (see the
# plan this was built from): matrix entries are 1/scale (not scale), and
# odx/ody are -x0f/scale (not -x0f), i.e. everything is expressed in
# *output*-relative terms, not source-relative terms.
def render_dynamic_frame(variant, mosaic, native_mpp, inset_size, fs, bilinear)
  cx, cy = mosaic.to_pixel(fs.lon, fs.lat)
  size_f = (2.0 * fs.dynamic_radius_m) / native_mpp
  size_f = [size_f, variant.width, variant.height].min # never request a window bigger than the mosaic

  x0f = (cx - (size_f / 2.0)).clamp(0.0, variant.width - size_f)
  y0f = (cy - (size_f / 2.0)).clamp(0.0, variant.height - size_f)

  inv_scale = inset_size / size_f
  frame = variant.affine([inv_scale, 0, 0, inv_scale], odx: -x0f * inv_scale, ody: -y0f * inv_scale,
                          interpolate: bilinear, oarea: [0, 0, inset_size, inset_size], background: [0, 0, 0, 0])
  frame = frame.bandjoin(255) if frame.bands == 3 # defensive -- variant is 4-band RGBA throughout this codebase
  frame.write_to_memory
end

# dynamic_speed only: with Ruby now owning per-frame crop position/size
# (see render_dynamic_frame), the marker's rotate angle is the ONLY thing
# still driven by ffmpeg's sendcmd for this path -- no more crop x/y or
# scale w/h commands (those belonged to the now-removed ffmpeg-side zoom
# mechanism; see write_sendcmd, still used unchanged by fixed_radius/
# fixed_zoom).
def write_rotate_sendcmd(path, frame_states, fps)
  File.open(path, "w") do |f|
    frame_states.each do |fs|
      t = format("%.6f", fs.frame_index / fps.to_f)
      angle_rad = fs.course_deg * Math::PI / 180.0
      f.puts "#{t} rotate angle #{format('%.6f', angle_rad)};"
    end
  end
end

# variant is a ChunkyPNG::Canvas (MosaicRenderer) or a Vips::Image
# (VipsMosaicRenderer) depending on which backend is active -- each has its
# own save API, so dispatch here rather than giving the two renderer
# classes a fake shared method.
def save_variant_image(variant, path)
  if defined?(Vips::Image) && variant.is_a?(Vips::Image)
    variant.write_to_file(path)
  else
    variant.save(path, :fast_rgba)
  end
end

def corner_offset(corner, out_w, out_h, size_px, margin_px)
  case corner
  when "bottom_right" then [out_w - size_px - margin_px, out_h - size_px - margin_px]
  when "bottom_left" then [margin_px, out_h - size_px - margin_px]
  when "top_right" then [out_w - size_px - margin_px, margin_px]
  when "top_left" then [margin_px, margin_px]
  else raise "Unknown inset.corner #{corner.inspect}"
  end
end

def codec_args(codec, output_path)
  case codec
  when "prores4444"
    ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", output_path]
  when "png_sequence"
    FileUtils.mkdir_p(output_path)
    ["-pix_fmt", "rgba", File.join(output_path, "frame_%06d.png")]
  else
    raise "Unknown output.codec #{codec.inspect}"
  end
end

# dynamic_speed only: spawns ffmpeg with its map input as a writable
# rawvideo stdin pipe instead of a static concat-demuxer image, and streams
# one already-correct (Ruby/vips-cropped+resized) RGBA frame per output
# frame into it. alphamerge (shape clipping), border overlay, and marker
# rotate+overlay stay exactly the fixed-size, always-reliable operations
# they are today -- only the map layer's *source* changes, so this needs no
# fps-duplication or crop/scale filter stages for the map at all.
def encode_dynamic_speed_main(config, clip_name, work_dir, variant, mosaic, native_mpp, inset_size,
                               main_frame_states, fps, total_duration, main_total_frames,
                               mask_path, border_path, marker_path, main_output, main_codec_args, blank_frames)
  f0 = main_frame_states.first
  angle0 = f0.course_deg * Math::PI / 180.0

  rotate_sendcmd_path = File.join(work_dir, "sendcmd.txt")
  write_rotate_sendcmd(rotate_sendcmd_path, main_frame_states, fps)

  border_stage = if config.inset.border.enabled
                   "[mapclipped][3:v]overlay=0:0:format=auto[bordered];\n"
                 else
                   "[mapclipped]copy[bordered];\n"
                 end

  filter_graph = <<~FILTER
    [0:v][2:v]alphamerge[mapclipped];
    #{border_stage}[1:v]sendcmd=f='#{rotate_sendcmd_path.gsub('\\', '/').gsub(':', '\:')}'[markercmd];
    [markercmd]rotate=angle=#{format('%.6f', angle0)}:fillcolor=black@0.0:ow=iw:oh=ih[markerrot];
    [bordered][markerrot]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2:format=auto[final]
  FILTER
  File.write(File.join(work_dir, "filter_complex.txt"), filter_graph) # debugging only, same as the other path

  cmd = [
    "ffmpeg", "-y",
    "-f", "rawvideo", "-pix_fmt", "rgba", "-video_size", "#{inset_size}x#{inset_size}",
    "-framerate", fps.to_s, "-i", "pipe:0",
    "-loop", "1", "-r", fps.to_s, "-t", total_duration.to_s, "-i", marker_path,
    "-loop", "1", "-r", fps.to_s, "-t", total_duration.to_s, "-i", mask_path,
    "-loop", "1", "-r", fps.to_s, "-t", total_duration.to_s, "-i", (config.inset.border.enabled ? border_path : mask_path),
    "-filter_complex", filter_graph,
    "-map", "[final]",
    "-frames:v", main_total_frames.to_s
  ]
  cmd += ["-start_number", blank_frames.to_s] if config.output.codec == "png_sequence" && blank_frames.positive?
  cmd += main_codec_args

  puts "[#{clip_name}] encoding (dynamic_speed, Ruby-side per-frame crop+resize) -> #{main_output}"
  encode_started_at = Time.now

  # variant is still a lazy vips pipeline (every tile insert + the drawn
  # route line) -- without materializing it once here, each frame's
  # extract_area below would re-walk/recompute that whole pipeline from
  # scratch (confirmed: 120 frames took 75s before this fix, vs. under a
  # second per frame expected). copy_memory forces evaluation once into a
  # real in-memory buffer, so every subsequent per-frame crop is a cheap
  # random-access read.
  materialized = variant.copy_memory
  bilinear = Vips::Interpolate.new("bilinear")
  io = IO.popen(cmd, "wb")
  begin
    main_frame_states.each { |fs| io.write(render_dynamic_frame(materialized, mosaic, native_mpp, inset_size, fs, bilinear)) }
  rescue Errno::EPIPE
    puts "[#{clip_name}] ffmpeg closed its input early (broken pipe) -- checking exit status"
  ensure
    begin
      io.close unless io.closed?
    rescue Errno::EPIPE, IOError
      # exit status (checked below) is the authoritative signal either way
    end
  end

  status = $?
  raise "ffmpeg failed for #{clip_name} (exit status #{status&.exitstatus.inspect})" unless status&.success?

  puts "[#{clip_name}] encoded in #{format('%.1f', Time.now - encode_started_at)}s"
end

def render_clip(config, config_dir, run_dir, trip_points, clip_path, start_time, duration_seconds, nframes, work_root)
  fps = config.output.fps
  if config.map.window_mode == "dynamic_speed" && MOSAIC_RENDERER_CLASS != VipsMosaicRenderer
    raise "map.window_mode: dynamic_speed requires the libvips backend for fast per-frame sub-pixel " \
          "crop+resize -- chunky_png has no fast primitive for this (see lib/vips_support.rb for how to " \
          "install libvips), or switch map.window_mode to fixed_radius/fixed_zoom."
  end
  total_frames = nframes || (duration_seconds * fps).round
  raise "Computed 0 output frames for #{clip_path}" if total_frames <= 0

  out_w, out_h = config.output.resolution.split("x").map(&:to_i)
  inset_size = config.inset.size_px

  clip_name = clip_path ? File.basename(clip_path, ".*") : "trip"
  work_dir = File.join(work_root, clip_name)
  FileUtils.mkdir_p(work_dir)

  puts "[#{clip_name}] planning #{total_frames} frames @ #{fps}fps from #{start_time}"

  planner = FramePlanner.new(trip_points)
  frame_states = planner.frame_states(start_time, fps, total_frames)

  # Frames before the trip's very first GPS fix (only possible for a trip's
  # first clip, recorded before the GPS chip locked) have no real position to
  # show -- FramePlanner tags them reveal_index: -1, and since frame time
  # only increases, they're always one leading run. Render those as fully
  # transparent frames instead of a frozen marker, so the overlay still
  # matches the source clip's length without implying the camera sat still.
  blank_frames = frame_states.take_while { |fs| fs.reveal_index == -1 }.size
  puts "[#{clip_name}] #{blank_frames} leading frame(s) have no GPS fix yet -- will render transparent" if blank_frames.positive?
  main_frame_states = frame_states[blank_frames..].each_with_index.map do |fs, i|
    FramePlanner::FrameState.new(frame_index: i, lon: fs.lon, lat: fs.lat, speed_kmh: fs.speed_kmh,
                                  course_deg: fs.course_deg, reveal_index: fs.reveal_index,
                                  dynamic_radius_m: fs.dynamic_radius_m)
  end
  main_total_frames = main_frame_states.size

  FileUtils.mkdir_p(resolve(run_dir, config.output.directory))
  output_base = File.join(resolve(run_dir, config.output.directory), clip_name)
  output_target = config.output.codec == "png_sequence" ? "#{output_base}_frames" : "#{output_base}.mov"
  main_output = blank_frames.positive? && config.output.codec != "png_sequence" ? File.join(work_dir, "main.mov") : output_target

  if main_total_frames.positive?
    avg_lat = trip_points.sum(&:lat) / trip_points.size
    zoom, native_mpp, max_radius = zoom_and_max_radius(config, avg_lat, inset_size)

    tile_fetcher = TileFetcher.new(
      cache_dir: resolve(config_dir, config.map.tile_cache_dir),
      provider: config.map.tile_provider,
      custom_url_template: config.map.custom_tile_url_template,
      custom_api_key: config.map.custom_tile_api_key
    )

    # One mosaic covers this whole clip -- big enough (in whole tiles) to
    # contain every point the clip's own portion of the route touches, plus
    # the visible pan radius, so panning never runs past its edge. Sized to
    # the clip, not the whole trip, so a long multi-hour trip doesn't blow
    # this up the way a single whole-trip mosaic once did.
    last_idx = trip_points.size - 1
    clip_lo = main_frame_states.map(&:reveal_index).min
    clip_hi = [main_frame_states.map(&:reveal_index).max + 1, last_idx].min
    clip_points = trip_points[clip_lo..clip_hi]

    clip_min_lat = clip_points.map(&:lat).min
    clip_max_lat = clip_points.map(&:lat).max
    clip_min_lon = clip_points.map(&:lon).min
    clip_max_lon = clip_points.map(&:lon).max
    clip_center_lat = (clip_min_lat + clip_max_lat) / 2.0
    clip_center_lon = (clip_min_lon + clip_max_lon) / 2.0
    clip_half_span_m = [
      (clip_max_lat - clip_min_lat) * 111_320,
      (clip_max_lon - clip_min_lon) * 111_320 * Math.cos(clip_center_lat * Math::PI / 180.0)
    ].max / 2.0

    half_extent_m = clip_half_span_m + max_radius + 50 # a little slack beyond the largest window ever shown
    tile_radius = (half_extent_m / (native_mpp * WebMercator::TILE_SIZE)).ceil + 1
    native_stream_dim = ((2 * tile_radius) + 1) * WebMercator::TILE_SIZE

    # Native mosaic size (tile_radius above) never depends on supersample,
    # so it's computed first, then used here to pick the largest supersample
    # that still keeps the final canvas safe -- see safe_supersample's
    # comment for why this check exists. dynamic_speed no longer needs
    # ffmpeg-side supersampling -- its sub-pixel accuracy now comes from
    # vips' bilinear `affine` in render_dynamic_frame, operating directly
    # on the native-resolution mosaic.
    desired_supersample = config.map.window_mode == "fixed_radius" ? PAN_SUPERSAMPLE : 1
    supersample = safe_supersample(native_stream_dim, desired_supersample)
    actual_mpp = native_mpp / supersample.to_f
    stream_w = native_stream_dim * supersample
    stream_h = stream_w

    origin_tile_x, origin_tile_y, last_tile_x, last_tile_y = WebMercator.tile_range(zoom, clip_center_lon,
                                                                                     clip_center_lat, tile_radius)
    puts "[#{clip_name}] fetching #{(2 * tile_radius) + 1}x#{(2 * tile_radius) + 1} map tiles at zoom #{zoom} " \
         "(#{format('%.2f', actual_mpp)} m/px effective, supersample #{supersample}x)"
    fetch_started_at = Time.now
    tile_fetcher.prefetch(zoom, origin_tile_x, last_tile_x, origin_tile_y, last_tile_y)
    puts "[#{clip_name}] fetched tiles in #{format('%.1f', Time.now - fetch_started_at)}s"

    puts "[#{clip_name}] stitching map mosaic"
    stitch_started_at = Time.now
    mosaic = MOSAIC_RENDERER_CLASS.new(tile_fetcher, zoom: zoom, center_lon: clip_center_lon,
                                                      center_lat: clip_center_lat, tile_radius: tile_radius)

    pixel_point_runs = route_runs(trip_points, config.route.privacy_zones || []).map do |run|
      run.map { |p| mosaic.to_pixel(p.lon, p.lat) }
    end
    variant = mosaic.with_route(pixel_point_runs, config.route.color, config.route.line_width_px,
                                 config.route.track_line_alpha || 1.0)
    dynamic = config.map.window_mode == "dynamic_speed"
    unless dynamic
      variant_path = File.join(work_dir, "route.png")
      save_variant_image(variant, variant_path)
    end
    puts "[#{clip_name}] stitched map mosaic in #{format('%.1f', Time.now - stitch_started_at)}s"

    # dynamic_speed writes its own rotate-only sendcmd.txt (see
    # encode_dynamic_speed_main/write_rotate_sendcmd) -- Ruby now owns
    # per-frame crop position/size for that mode, so there's nothing left
    # for this crop/scale-driving sendcmd script to do there.
    sendcmd_path = File.join(work_dir, "sendcmd.txt")
    unless dynamic
      write_sendcmd(sendcmd_path, main_frame_states, mosaic, fps, config, actual_mpp, inset_size, supersample,
                    stream_w, stream_h)
    end

    shape = config.inset.shape
    corner_radius = InsetAssets.corner_radius_for(shape, inset_size, (inset_size * 0.15).round)
    mask_path = File.join(work_dir, "mask.png")
    InsetAssets.build_mask(inset_size, shape, corner_radius).save(mask_path, :fast_rgba)

    border_path = File.join(work_dir, "border.png")
    InsetAssets.build_border(inset_size, shape, corner_radius, config.inset.border.width_px,
                              config.inset.border.color).save(border_path, :fast_rgba) if config.inset.border.enabled

    marker_path = File.join(work_dir, "marker.png")
    InsetAssets.build_marker(config.position_marker.radius_px, config.position_marker.color,
                              config.position_marker.outline_color,
                              config.position_marker.outline_width_px).save(marker_path, :fast_rgba)

    total_duration = main_total_frames / fps.to_f
    unless dynamic
      map_concat_path = File.join(work_dir, "map_concat.txt")
      write_single_image_concat(map_concat_path, variant_path, total_duration)
    end

    inset_x, inset_y = corner_offset(config.inset.corner, out_w, out_h, inset_size, config.inset.margin_px)
    center_dx = (inset_x + (inset_size / 2.0)) - (out_w / 2.0)
    center_dy = (inset_y + (inset_size / 2.0)) - (out_h / 2.0)
    puts "[#{clip_name}] rendering #{inset_size}x#{inset_size} inset only -- in Resolve, place it at " \
         "Pan #{center_dx.round}, #{center_dy.round} (center-relative offset) for a #{out_w}x#{out_h} timeline"

    main_codec_args = config.output.codec == "png_sequence" ? codec_args(config.output.codec, output_target) :
                                                                codec_args(config.output.codec, main_output)

    if dynamic
      encode_dynamic_speed_main(config, clip_name, work_dir, variant, mosaic, native_mpp, inset_size,
                                 main_frame_states, fps, total_duration, main_total_frames,
                                 mask_path, border_path, marker_path, main_output, main_codec_args, blank_frames)
    else
      f0 = main_frame_states.first
      px0, py0 = mosaic.to_pixel(f0.lon, f0.lat)
      px0 *= supersample
      py0 *= supersample
      angle0 = f0.course_deg * Math::PI / 180.0
      size0 = crop_size_px(config, actual_mpp, inset_size, f0.speed_kmh)
      size0 = [size0, [stream_w, stream_h].min].min
      x0 = (px0 - (size0 / 2.0)).round.clamp(0, stream_w - size0)
      y0 = (py0 - (size0 / 2.0)).round.clamp(0, stream_h - size0)

      scale_stage = "[cropped]scale=#{inset_size}:#{inset_size}[mapscaled];\n"

      # fixed_radius's sub-pixel positioning precision (PAN_SUPERSAMPLE)
      # comes from upscaling the mosaic here, in ffmpeg (fast C code) -- doing
      # it in Ruby (ChunkyPNG's pure-Ruby bilinear resample) was far too slow
      # at mosaic scale. Scaling before `fps` means each unique concat-demuxer
      # image is upscaled once; `fps` then cheaply duplicates the already-
      # scaled frame for held frames instead of re-scaling every duplicate.
      # flags=neighbor (nearest-neighbor): this upscale exists purely to create
      # more addressable pixel positions for crop to snap to, not to add
      # interpolated detail -- a smoothing algorithm here would blur the source
      # tiles once on the way up and again on the final downscale to inset_size,
      # visibly softening the map for no benefit.
      upscale_stage = supersample > 1 ? "[0:v]scale=w=#{stream_w}:h=#{stream_h}:flags=neighbor[upscaled];\n" : ""
      source_label = supersample > 1 ? "upscaled" : "0:v"

      filter_graph = <<~FILTER
        #{upscale_stage}[#{source_label}]fps=#{fps},sendcmd=f='#{sendcmd_path.gsub('\\', '/').gsub(':', '\:')}'[bg];
        [bg]crop=w=#{size0}:h=#{size0}:x=#{x0}:y=#{y0}[cropped];
        #{scale_stage}[mapscaled][2:v]alphamerge[mapclipped];
        #{config.inset.border.enabled ? "[mapclipped][3:v]overlay=0:0:format=auto[bordered];" : "[mapclipped]copy[bordered];"}
        [1:v]sendcmd=f='#{sendcmd_path.gsub('\\', '/').gsub(':', '\:')}'[markercmd];
        [markercmd]rotate=angle=#{format('%.6f', angle0)}:fillcolor=black@0.0:ow=iw:oh=ih[markerrot];
        [bordered][markerrot]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2:format=auto[final]
      FILTER
      # Written for debugging only -- newer ffmpeg builds dropped
      # -filter_complex_script entirely, so the graph is now passed inline via
      # -filter_complex below (system(*cmd)'s array form sends it straight to
      # ffmpeg's argv, no shell involved, so embedded newlines are safe).
      filter_path = File.join(work_dir, "filter_complex.txt")
      File.write(filter_path, filter_graph)

      cmd = [
        "ffmpeg", "-y",
        "-f", "concat", "-safe", "0", "-i", map_concat_path,
        "-loop", "1", "-r", fps.to_s, "-t", total_duration.to_s, "-i", marker_path,
        "-loop", "1", "-r", fps.to_s, "-t", total_duration.to_s, "-i", mask_path,
        "-loop", "1", "-r", fps.to_s, "-t", total_duration.to_s, "-i", (config.inset.border.enabled ? border_path : mask_path),
        "-filter_complex", filter_graph,
        "-map", "[final]",
        "-frames:v", main_total_frames.to_s
      ]
      cmd += ["-start_number", blank_frames.to_s] if config.output.codec == "png_sequence" && blank_frames.positive?
      cmd += main_codec_args

      puts "[#{clip_name}] encoding -> #{main_output}"
      encode_started_at = Time.now
      ok = system(*cmd)
      raise "ffmpeg failed for #{clip_name}" unless ok

      puts "[#{clip_name}] encoded in #{format('%.1f', Time.now - encode_started_at)}s"
    end
  end

  if blank_frames.positive?
    puts "[#{clip_name}] generating #{blank_frames} transparent leading frame(s)"
    if config.output.codec == "png_sequence"
      FileUtils.mkdir_p(output_target)
      blank_png = File.join(work_dir, "blank.png")
      ChunkyPNG::Canvas.new(inset_size, inset_size, ChunkyPNG::Color::TRANSPARENT).save(blank_png, :fast_rgba)
      (0...blank_frames).each { |i| FileUtils.cp(blank_png, File.join(output_target, format("frame_%06d.png", i))) }
    else
      # Two identical opaque-black lavfi sources fed through alphamerge (the
      # same mechanism used elsewhere in this file) force alpha to exactly 0
      # everywhere -- more robust than relying on a color=...@0.0 source's
      # alpha surviving straight through to the encoder.
      leadin_path = File.join(work_dir, "leadin.mov")
      leadin_filter = "[0:v][1:v]alphamerge,format=yuva444p10le[out]"
      leadin_cmd = [
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", "color=c=black:s=#{inset_size}x#{inset_size}:r=#{fps}",
        "-f", "lavfi", "-i", "color=c=black:s=#{inset_size}x#{inset_size}:r=#{fps}",
        "-filter_complex", leadin_filter,
        "-map", "[out]",
        "-frames:v", blank_frames.to_s,
        *codec_args(config.output.codec, leadin_path)
      ]
      ok = system(*leadin_cmd)
      raise "ffmpeg failed generating leading transparent frames for #{clip_name}" unless ok

      if main_total_frames.positive?
        concat_final_path = File.join(work_dir, "concat_final.txt")
        File.open(concat_final_path, "w") do |f|
          f.puts "file '#{leadin_path.gsub('\\', '/')}'"
          f.puts "file '#{main_output.gsub('\\', '/')}'"
        end
        ok = system("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat_final_path, "-c", "copy", output_target)
        raise "ffmpeg failed joining transparent lead-in for #{clip_name}" unless ok

        # leadin.mov and main.mov are fully superseded by output_target now
        # that they've been copy-concatenated into it -- keeping them around
        # would just double the disk space this render uses for no benefit.
        File.delete(leadin_path, main_output)
      else
        FileUtils.cp(leadin_path, output_target)
        File.delete(leadin_path)
      end
    end
  end

  puts "[#{clip_name}] done: #{output_target}"
end

if __FILE__ == $PROGRAM_NAME
  require "English"

  options = { config: nil, nframes: nil }
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby overlay_generator.rb [clip.mp4] [options]"
    opts.on("--config PATH", "Path to overlay_config.yml (default: overlay_config.yml next to this script)") { |v| options[:config] = v }
    opts.on("--nframes N", Integer, "Render only the first N output frames (for quick testing)") { |v| options[:nframes] = v }
  end.parse!

  # No --config given: use the shared overlay_config.yml that ships next to
  # this script, regardless of the directory you're running from -- so you
  # can invoke this from inside any trip's clip folder. trip.clips_dir,
  # trip.gpx_file and output.directory are then resolved against *that*
  # folder (run_dir, i.e. Dir.pwd), not against wherever the script/config
  # live -- only map.tile_cache_dir stays next to the script, as a cache
  # shared across every trip you render.
  config_path = options[:config] ? File.expand_path(options[:config]) : File.expand_path("overlay_config.yml", __dir__)
  config_dir = File.dirname(config_path)
  run_dir = Dir.pwd
  config = OverlayConfig.load(config_path)

  trip_points = GpxReader.read(ensure_trip_gpx(config, run_dir))
  assign_dynamic_radii!(trip_points, config, config.map.dynamic_speed.speed_smoothing_seconds) if config.map.window_mode == "dynamic_speed"
  work_root = File.join(resolve(run_dir, config.output.directory), "work")

  explicit_clip = ARGV.shift

  if explicit_clip
    clip_path = File.expand_path(explicit_clip)
    start_time, = NovatekGps.clip_time_range(clip_path, utc_offset_hours: config.trip.utc_offset_hours)
    duration = ffprobe_duration_seconds(clip_path)
    render_clip(config, config_dir, run_dir, trip_points, clip_path, start_time, duration, options[:nframes], work_root)
  elsif config.output.mode == "merged"
    start_time = trip_points.first.time
    duration = trip_points.last.time - trip_points.first.time
    render_clip(config, config_dir, run_dir, trip_points, nil, start_time, duration, options[:nframes], work_root)
  else
    clips_dir = resolve(run_dir, config.trip.clips_dir)
    clip_paths = Dir.glob(File.join(clips_dir, "*.MP4"), File::FNM_CASEFOLD).sort
    raise "No MP4 clips found in #{clips_dir}" if clip_paths.empty?

    clip_paths.each do |clip_path|
      start_time, = NovatekGps.clip_time_range(clip_path, utc_offset_hours: config.trip.utc_offset_hours)
      duration = ffprobe_duration_seconds(clip_path)
      render_clip(config, config_dir, run_dir, trip_points, clip_path, start_time, duration, options[:nframes], work_root)
    end
  end
end

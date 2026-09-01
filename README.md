# RouteOverlay

RouteOverlay extracts the GPS data embedded in dashcam video files and turns
it into a small, transparent "mini-map" video clip — a route line, a
moving/rotating position marker, panning to follow the car — meant to be
composited as a picture-in-picture inset over the dashcam footage in a video
editor (developed against DaVinci Resolve).

It was built and tested against a **Viofo A119 Mini 2** (Novatek chipset).
It should work unmodified with any dashcam that embeds GPS the same way
(Novatek's proprietary `freeGPS` record format inside the MP4), but that's
unverified beyond the one camera model.

## How it works

The project is two steps joined by a GPX file — extraction, then rendering —
but `overlay_generator.rb` runs the first step for you automatically, so in
practice you usually only invoke the second one directly (see Usage below).

### 1. Extraction — `gps_extractor.rb` + `lib/novatek_gps.rb`

Dashcam clips carry no standard GPS metadata track — instead, Novatek-chipset
cameras stamp a proprietary `freeGPS` binary record into the file roughly
once a second. `lib/novatek_gps.rb` scans a clip for these records via
chunked, seek-based reads (it never loads a full clip into memory), decodes
each one (timestamp, lat/lon, speed, compass course), and drops duplicates
the camera re-embeds when a new record slot comes up before the GPS chip has
a fresh reading.

`gps_extractor.rb` runs this over every clip in a folder, in filename order,
and merges the result into one continuous `trip.gpx` — with speed (km/h) and
course (degrees) written as GPX `<extensions>`. You can run it by hand (e.g.
to pass `--utc-offset`, or to point at a differently-named GPX), but you
don't have to — see the next section.

Some clips carry `freeGPS` records stamped **before** the GPS chip has ever
locked (`active` flag `'V'` instead of `'A'`) — usually just the first
second or two of a trip's very first clip. Occasionally the camera's RTC
hasn't synced yet at that point either, so those pre-lock records carry a
stale/bogus timestamp (observed: off by a fixed ~3 hours, corrected the
instant the first real fix comes in) instead of a merely-imprecise one.
`NovatekGps.clip_time_range` (used to work out a clip's true start time —
see below) detects this as a >10 minute jump between consecutive record
timestamps within the same file and discards everything before the jump,
so it never anchors a clip to the wrong clock. This is self-contained to
each file's own embedded records — it doesn't rely on filenames or any
other clock.

### 2. Overlay rendering — `overlay_generator.rb` + `lib/*`

`overlay_generator.rb` first makes sure `trip.gpx_file` exists and is at
least as new as every clip in `trip.clips_dir` — if it's missing, or a clip
was added/replaced since it was last generated, it (re-)runs the same
extraction `gps_extractor.rb` does before continuing, so you don't have to
run that step yourself first. It then reads that GPX and, per clip (or once
for the whole trip), renders a small square, transparent video:

- Fetches and stitches OpenStreetMap tiles (or a custom XYZ tile server)
  covering that clip's own portion of the route, caching every tile to disk
  (`lib/tile_fetcher.rb`, `lib/mosaic_renderer.rb`) — one mosaic per clip,
  sized to just that clip plus the visible pan radius, not the whole trip
  (a long trip with many clips would otherwise force one huge, slow mosaic).
- Draws the whole known route on that mosaic once, in a single color.
- Works out, frame-by-frame, the car's interpolated position, speed and
  heading between the nearest two GPX points (`lib/frame_planner.rb`).
- Hands all of that to `ffmpeg`: a generated `sendcmd` script drives
  per-frame pan (`crop` position) and marker rotation, and a small local
  supersample-then-downscale step keeps the pan smooth instead of visibly
  snapping between whole map pixels at low speed / tight zoom.
- Composites a rotating chevron marker (`lib/inset_assets.rb`) — Google
  Maps-style, always pointing in the current direction of travel — a
  rounded/rect/circle clipping mask, and an optional border ring.
- Outputs a small inset-only clip (ProRes 4444 with alpha, or a PNG
  sequence) — not a full-canvas video — since the inset is meant to be
  placed and scaled once in the editor rather than baked into position.
  The script prints the pixel offset to use for that placement.

Everything about the look (zoom radius, colors, line width, marker style,
inset size/corner/shape, codec, etc.) is driven by `overlay_config.yml`,
not hardcoded.

## Requirements

- Ruby (developed on 3.4). On Windows, install with winget:
  ```
  winget install RubyInstallerTeam.RubyWithDevKit.3.4
  ```
  (the `WithDevKit` variant includes the MSYS2/gcc toolchain — not needed
  for the project itself, but useful to have up front since `ruby-vips`
  below is required, not optional). Open a *new* terminal afterward and
  confirm it worked with `ruby -v`.
- `ffmpeg` and `ffprobe` on your `PATH`
- Network access to fetch map tiles the first time (cached locally after that)
- **`libvips` is required** — mosaic stitching, route drawing, the inset
  mask/border/marker, and `dynamic_speed`'s per-frame crop+resize all
  depend on it; there's no pure-Ruby fallback. Install it with
  `gem install ruby-vips` (installs cleanly on its own — it's ffi-based, no
  compiler needed), plus the native libvips library itself: either
  installed system-wide, or a Windows build's `bin` folder dropped at
  `vendor/vips_bin` (see `lib/vips_support.rb`'s comment for where to get
  one). If it's missing, the tool prints a clear message and exits rather
  than failing partway through a render.

## Usage

`overlay_config.yml` is one shared settings file that lives next to the
scripts — it's read from there automatically no matter which folder you run
the tool from, so you don't keep a copy per trip. Everything *trip-specific*
(clips, the generated `trip.gpx`, the rendered `overlays/` folder) is instead
resolved relative to **the folder you run the command from** — the intended
workflow is: `cd` into a trip's folder of dashcam clips, then run the tool
right there.

**1. (One-time, optional) put the scripts on your `PATH`:**

Run `add_to_path.bat` once (double-click it, or run it from a terminal) — it
adds this folder to your user `PATH`. Open a *new* terminal window afterward
for that to take effect. This isn't required — you can always invoke the
scripts by their full path instead — but it's what makes step 3 below just
`routeoverlay` instead of `ruby "D:\...\route_overlay\overlay_generator.rb"`.

**2. Create your settings file, then edit it:**

`overlay_config.yml` itself isn't tracked in git (it's your personal copy,
and can end up holding real locations via `route.privacy_zones`). The repo
ships `overlay_config.yml.default` as a template — copy it once:

```
copy overlay_config.yml.default overlay_config.yml
```

Then edit `overlay_config.yml` (in this folder, applies to every trip):

- `trip.clips_dir` — leave as `.` to mean "the folder I'm running this
  from"; `trip.utc_offset_hours` — your camera clock's UTC offset (0 if
  it's already UTC). Leave `trip.gpx_file` as `trip.gpx` — it gets generated
  for you (see below), one per trip folder, you don't create it yourself.
- `map.window_mode: fixed_radius` and `map.fixed_radius.radius_meters` —
  the primary, recommended zoom mode: a constant real-world radius shown
  around the car regardless of speed. Smaller = more zoomed in.
- `map.window_mode: dynamic_speed` — an alternative mode where the radius
  scales with current speed instead of staying constant: `min_radius_meters`
  is shown at or below `min_speed_kmh` (a "dead zone" before zooming out
  starts — `0` disables it, same as leaving `min_speed_kmh` unset), ramping
  up to `max_radius_meters` once speed reaches `max_speed_kmh` (capped
  there, doesn't zoom out further above it). `curve_exponent` shapes that
  ramp: `1` (the default) is a straight line; higher values keep the radius
  close to `min_radius_meters` through low/mid speeds and only grow it
  quickly near `max_speed_kmh` (useful if, e.g., the radius otherwise feels
  too large already at ordinary city speeds); values below `1` do the
  opposite, growing fast early and flattening out later. Before that
  speed-to-radius mapping is applied, speed is smoothed by averaging it
  over a *centered* real-time window
  around each moment — `speed_smoothing_seconds` sets that window's total
  width (e.g. `4` averages ±2s around each point) — so the zoom doesn't
  jitter on noisy raw GPS speed and can start widening/narrowing slightly
  ahead of a real speed change rather than only reacting after it; `0`
  disables smoothing. Mechanically, Ruby crops and resizes the map mosaic
  itself (via libvips) for every output frame and pipes the finished frames
  straight into ffmpeg — no new tiles are fetched as it zooms, ffmpeg is
  never asked to resize anything itself. Works correctly, but is noticeably
  slower to render per clip than `fixed_radius` — see "What's not done yet"
  — so it's opt-in,
  not the default.
- `inset.size_px`, `inset.shape`, `inset.border.*` — size and look of the
  rendered square.
- `route.color`, `route.line_width_px`, `position_marker.*` — route line and
  marker colors/width.
- `route.track_line_alpha` — route line opacity, `0.0` (invisible) to `1.0`
  (fully opaque, the default).
- `route.privacy_zones` — zero or more `{center_lat, center_lon,
  radius_meters}` circles the route line is never drawn inside (e.g. to hide
  it near home) — the line stops before entering one and resumes after.
- `output.codec` — `prores4444` (alpha video) or `png_sequence`.
- `output.parallel_clips` — how many clips of a trip to render at once
  (default `1`, today's one-at-a-time behavior); only applies when
  rendering every clip in a folder (not a single explicit clip, not
  `merged` mode). Each clip beyond the first spawns its own
  `ruby overlay_generator.rb` process (Ruby has no `fork` on Windows), so
  raising this only helps if your machine actually has CPU/RAM headroom to
  spare — watch usage and tune from there rather than maxing it out.

**3. `cd` into your trip's clips folder, then render:**

```
routeoverlay                              # every clip in the current folder
routeoverlay some_clip.MP4                # just one clip
routeoverlay some_clip.MP4 --nframes 120  # quick test, first 120 frames only
```

(No `routeoverlay` on your `PATH`? Same commands work as
`ruby "D:\path\to\route_overlay\overlay_generator.rb" ...`.)

The first run extracts and merges GPS from every clip in the current folder
into a `trip.gpx` written there too (printing progress as it does); later
runs reuse it unless a clip has been added or changed since. Rendered
overlays land in `overlays\` under the current folder. Each render also
prints a suggested pixel offset (`Pan X, Y`) for that clip — place the
rendered inset at that position in your timeline, at 1:1 scale.

You can still run extraction by hand if you want (e.g. to point it at a
different filename glob than `*.MP4`, or generate a GPX without rendering
anything yet) — `trip.utc_offset_hours` in the config is used either way:

```
routeextract . -o trip.gpx --utc-offset 3
```

The one thing that's *not* per-trip-folder is `map.tile_cache_dir`: it stays
next to the scripts by default, since it's a downloaded-map-tile cache
that's worth sharing across every trip you render, not duplicating per
folder.

## What's done

- Binary `freeGPS` parsing and multi-clip GPX merge, with speed/course
  extensions and duplicate-fix filtering.
- `overlay_generator.rb` auto-extracts/refreshes `trip.gpx` when it's
  missing or older than the clips in `trip.clips_dir` — no separate manual
  step needed for the common case.
- Config-driven rendering — no hardcoded look/behavior.
- Inset-only (not full-canvas) alpha video output, ProRes 4444 or PNG
  sequence.
- Single-color route line, drawn once per clip onto a mosaic sized to that
  clip's own portion of the trip (not the whole trip) plus the visible pan
  radius — kept simple and fast on purpose; see "What's not done yet" for
  the two-tone traveled/upcoming reveal this replaced.
- `route.privacy_zones`: circular no-draw zones for the route line (e.g. to
  hide it near home) — the line stops before a zone and resumes after,
  rather than being drawn through it or jumping straight across the gap.
- `route.track_line_alpha`: translucent route line, applied once to the
  whole assembled line rather than baked into the draw color, so overlapping
  segment stamps don't double-blend and build up darker.
- Rotating chevron position marker matching the GPX-derived compass course.
- North-up map orientation with smooth, sub-pixel-accurate panning
  (no visible per-second "jump" between map positions).
- `fixed_radius` (constant real-world zoom) and `fixed_zoom` (constant tile
  zoom level) window modes.
- `dynamic_speed` window mode (zoom radius scales with current speed,
  tight when stopped, wide at highway speed, smoothly interpolated and
  smoothed against noisy raw GPS speed — see `map.dynamic_speed.*` above).
  ffmpeg cannot actually resize a filter's output at runtime in a way this
  project could get working (confirmed by direct testing across ffmpeg
  versions spanning 2023-2026, including an isolated reproduction that
  segfaults ffmpeg outright), so this mode instead crops and resizes the
  map mosaic itself, in Ruby via libvips, for every output frame, and pipes
  the finished frames straight into ffmpeg over stdin — ffmpeg only ever
  does the fixed-size compositing (shape mask, border, marker) it's always
  been reliable at. Meaningfully slower per clip than `fixed_radius` (its
  mosaic covers a wider area and every frame does a real image resize), so
  it stays opt-in, not the default.
- OSM and custom XYZ tile server support, with on-disk tile caching, plus an
  in-memory decoded-tile cache so a clip's many overlapping tile reads don't
  each re-decode the same PNG from scratch.
- All rendering — mosaic stitching, route drawing, the inset mask/border/
  marker, `dynamic_speed`'s per-frame crop+resize — runs on `libvips`
  (`lib/vips_support.rb`, `lib/vips_mosaic_renderer.rb`, `lib/inset_assets.rb`),
  which is required, not optional (see Requirements above) — there's no
  pure-Ruby fallback path to keep in sync or fall behind.
- Leading frames before the trip's very first GPS fix (e.g. a clip recorded
  before the GPS chip locked) render as fully transparent instead of a
  frozen marker, keeping the overlay's length matched to the source clip.
- A clip whose pre-lock records carry a stale/bogus RTC timestamp (seen as
  a multi-hour jump right before the first real fix) no longer gets
  anchored to the wrong clock and rendered fully blank — see "Extraction"
  above.
- A clip with no usable GPS at all renders as a fully transparent clip
  instead of crashing the whole batch.
- Intermediate per-clip render files (map mosaic, sendcmd script, mask/
  border/marker assets) live under `overlays/work/<clip>/` and are small;
  the one genuinely large intermediate (`main.mov`, produced only for a
  clip with leading transparent frames) is deleted automatically once it's
  been merged into the final output.
- `--nframes` flag for fast iteration while tuning config.

## What's not done yet

- **`rotation_mode: heading_up`** — only `north_up` is actually implemented;
  the config option exists but heading-up rotation isn't wired up.
- **`speed_hud`** — config section exists (`enabled: false`) but there's no
  code reading or rendering it yet.
- **`extras` (`north_arrow`, `scale_bar`, `timestamp`)** — listed as config
  options but not implemented.
- **Two-tone route (traveled vs. upcoming)** — this project had it working
  at one point (one small local mosaic per GPS point reached), but it was
  the direct cause of the worst performance problems encountered building
  this, and was deliberately dropped in favor of one single-color route
  drawn once per clip. Could come back as an opt-in `route.style` later,
  but isn't planned for now.
- **Trailing no-GPS frames** (a clip ending after the trip's last GPS fix)
  still freeze the marker at the last known position, unlike the leading
  case above — not requested/changed yet.
- **Mid-clip GPS gaps** (temporary signal loss, e.g. a tunnel) are bridged
  by straight-line interpolation between the two surrounding real fixes —
  a deliberate simplification, not a bug, but it means the marker can glide
  in a way that doesn't match the real road path during a long gap.
- No automated test suite — correctness has been checked by hand
  (frame-accurate pixel/alpha comparisons and visual review of renders),
  not by a repeatable test harness.

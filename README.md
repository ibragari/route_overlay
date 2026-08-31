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

### 2. Overlay rendering — `overlay_generator.rb` + `lib/*`

`overlay_generator.rb` first makes sure `trip.gpx_file` exists and is at
least as new as every clip in `trip.clips_dir` — if it's missing, or a clip
was added/replaced since it was last generated, it (re-)runs the same
extraction `gps_extractor.rb` does before continuing, so you don't have to
run that step yourself first. It then reads that GPX and, per clip (or once
for the whole trip), renders a small square, transparent video:

- Fetches and stitches OpenStreetMap tiles (or a custom XYZ tile server)
  covering the trip's bounding box, caching every tile to disk
  (`lib/tile_fetcher.rb`, `lib/mosaic_renderer.rb`).
- Draws the full route on it in two tones — muted "upcoming" road ahead,
  highlighted "traveled" road behind — and pre-renders one image per point
  where the traveled/upcoming split changes (a "reveal" variant).
- Works out, frame-by-frame, the car's interpolated position, speed and
  heading between the nearest two GPX points (`lib/frame_planner.rb`).
- Hands all of that to `ffmpeg`: a generated `sendcmd` script drives
  per-frame pan (`crop` position) and marker rotation, a generated
  concat-demuxer list drives the traveled/upcoming reveal, and a small
  local supersample-then-downscale step keeps the pan smooth instead of
  visibly snapping between whole map pixels at low speed / tight zoom.
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

- Ruby (developed on 3.4, no native gems required — `chunky_png` is pure Ruby)
- `ffmpeg` and `ffprobe` on your `PATH`
- Network access to fetch map tiles the first time (cached locally after that)

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

**2. Edit `overlay_config.yml`** (in this folder, applies to every trip):

- `trip.clips_dir` — leave as `.` to mean "the folder I'm running this
  from"; `trip.utc_offset_hours` — your camera clock's UTC offset (0 if
  it's already UTC). Leave `trip.gpx_file` as `trip.gpx` — it gets generated
  for you (see below), one per trip folder, you don't create it yourself.
- `map.window_mode: fixed_radius` and `map.fixed_radius.radius_meters` —
  the primary, recommended zoom mode: a constant real-world radius shown
  around the car regardless of speed. Smaller = more zoomed in.
- `inset.size_px`, `inset.shape`, `inset.border.*` — size and look of the
  rendered square.
- `route.*`, `position_marker.*` — colors and line/marker width.
- `output.codec` — `prores4444` (alpha video) or `png_sequence`.

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
- Two-tone route reveal (traveled vs. upcoming) that updates per GPS fix.
- Rotating chevron position marker matching the GPX-derived compass course.
- North-up map orientation with smooth, sub-pixel-accurate panning
  (no visible per-second "jump" between map positions).
- `fixed_radius` (constant real-world zoom) and `fixed_zoom` (constant tile
  zoom level) window modes.
- OSM and custom XYZ tile server support, with on-disk tile caching.
- Leading frames before the trip's very first GPS fix (e.g. a clip recorded
  before the GPS chip locked) render as fully transparent instead of a
  frozen marker, keeping the overlay's length matched to the source clip.
- A clip with no usable GPS at all renders as a fully transparent clip
  instead of crashing the whole batch.
- `--nframes` flag for fast iteration while tuning config.

## What's not done yet

- **`dynamic_speed` window mode** (zoom radius scales with current speed) —
  implemented and no longer hangs ffmpeg, but the marker positioning and
  visual quality during the zoom transition were unresolved and it's
  currently shelved in favor of `fixed_radius`. Present in the config but
  not recommended for use.
- **`rotation_mode: heading_up`** — only `north_up` is actually implemented;
  the config option exists but heading-up rotation isn't wired up.
- **`speed_hud`** — config section exists (`enabled: false`) but there's no
  code reading or rendering it yet.
- **`extras` (`north_arrow`, `scale_bar`, `timestamp`)** — listed as config
  options but not implemented.
- **`route.style: single_color`** — only the two-tone style is implemented;
  the config option is read nowhere.
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

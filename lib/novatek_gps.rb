# frozen_string_literal: true

# Shared parser for the proprietary "freeGPS " records embedded by
# Novatek-chipset dashcams (confirmed against a Viofo A119 Mini 2 sample)
# inside the mdat box of each MP4 clip. Used by both gps_extractor.rb and
# the overlay renderer.
#
# Record layout (little-endian), starting at each "freeGPS " signature:
#   offset  size  field
#     0      8    "freeGPS " signature
#     8      4    body length (uint32) -- bytes remaining after this field
#    12      4    hour   (uint32)
#    16      4    minute (uint32)
#    20      4    second (uint32)
#    24      4    year - 2000 (uint32)
#    28      4    month  (uint32)
#    32      4    day    (uint32)
#    36      1    active flag: 'A' = valid fix, 'V' = void
#    37      1    latitude hemisphere: 'N' / 'S'
#    38      1    longitude hemisphere: 'E' / 'W'
#    39      1    padding
#    40      4    latitude,  float32, DDMM.MMMM format
#    44      4    longitude, float32, DDMM.MMMM format
#    48      4    speed, float32, knots (verified via haversine cross-check)
#    52      4    bearing/course, float32, degrees 0-360
#
# The camera re-embeds the last known fix whenever a new record slot comes up
# before the GPS chip has produced a fresh reading -- this happens both
# within a clip and across a clip boundary on file rotation. Such duplicates
# are byte-identical, so callers should drop any record whose decoded
# timestamp matches the previously emitted trackpoint's timestamp.

module NovatekGps
  SIGNATURE = "freeGPS "
  BODY_BYTES = 44 # datetime(24) + flags(4) + lat/lon/speed/course(16)
  CHUNK_SIZE = 4 * 1024 * 1024
  KNOTS_TO_KMH = 1.852

  # Some boots leave the camera's RTC holding a stale/bogus value until GPS
  # produces its first fix and corrects it -- seen as void ('V') records at
  # the very start of a clip whose timestamp is off by hours from every
  # record after it, even though those void records are internally
  # consistent with *each other* (normal encoder-placement gaps between them
  # are at most tens of seconds). A jump this large can only be that RTC
  # correction, never a real gap between consecutive freeGPS records.
  CLOCK_JUMP_SECONDS = 600

  Trackpoint = Struct.new(:time, :lat, :lon, :speed_kmh, :course, keyword_init: true)

  module_function

  # Scans a single MP4 file for freeGPS records via chunked, seek-based reads
  # -- the file is never loaded into memory beyond one chunk at a time -- and
  # yields decoded Trackpoints in on-disk order.
  def each_record(path, include_void: false)
    overlap = SIGNATURE.bytesize
    File.open(path, "rb") do |f|
      file_size = f.size
      pos = 0
      prev_tail = ""

      while pos < file_size
        f.seek(pos)
        data = f.read(CHUNK_SIZE)
        break if data.nil?

        haystack = prev_tail + data
        base = pos - prev_tail.bytesize
        search_from = 0

        while (idx = haystack.index(SIGNATURE, search_from))
          record = decode_at(f, base + idx, include_void: include_void)
          yield record if record
          search_from = idx + 1
        end

        prev_tail = data[-overlap, overlap] || data
        pos += CHUNK_SIZE
      end
    end
  end

  # include_void: also yield records whose active flag is 'V' (no fix yet --
  # seen at the very start of a recording session, before the GPS chip has
  # ever locked). Their lat/lon/speed/course are meaningless and left nil;
  # only their timestamp is usable. Regular callers (collect_trip, building
  # the merged GPX) want these skipped; clip_time_range wants them, to find a
  # clip's true start rather than its first *fixed* position.
  def decode_at(file, offset, include_void: false)
    file.seek(offset + SIGNATURE.bytesize)
    len = file.read(4)&.unpack1("V")
    return nil unless len && len >= BODY_BYTES

    body = file.read(BODY_BYTES)
    return nil unless body && body.bytesize == BODY_BYTES

    hour, min, sec, year, month, day = body[0, 24].unpack("V6")
    active, lat_hemi, lon_hemi = body[24], body[25], body[26]

    if active != "A"
      return nil unless include_void

      time = Time.utc(2000 + year, month, day, hour, min, sec)
      return Trackpoint.new(time: time, lat: nil, lon: nil, speed_kmh: nil, course: nil)
    end

    lat_raw, lon_raw, speed_knots, course = body[28, 16].unpack("e4")

    time = Time.utc(2000 + year, month, day, hour, min, sec)
    lat = ddmm_to_decimal(lat_raw)
    lat = -lat if lat_hemi == "S"
    lon = ddmm_to_decimal(lon_raw)
    lon = -lon if lon_hemi == "W"

    Trackpoint.new(time: time, lat: lat, lon: lon, speed_kmh: speed_knots * KNOTS_TO_KMH, course: course)
  rescue ArgumentError
    nil # garbage/out-of-range datetime fields from a false-positive signature match
  end

  def ddmm_to_decimal(value)
    degrees = (value / 100).to_i
    minutes = value - degrees * 100
    degrees + minutes / 60.0
  end

  # Reads every file matching pattern in dir (sorted by filename, which sorts
  # by trip timestamp given Viofo's YYYYMMDDHHMMSS_NNNNNN naming), merges
  # their records into one continuous, deduplicated trackpoint list.
  def collect_trip(dir, pattern: "*.MP4", utc_offset_hours: 0)
    files = Dir.glob(File.join(dir, pattern), File::FNM_CASEFOLD).sort
    raise "No files matching #{pattern.inspect} found in #{dir}" if files.empty?

    points = []
    last_raw_time = nil

    files.each do |path|
      each_record(path) do |tp|
        next if tp.time == last_raw_time

        last_raw_time = tp.time
        tp.time -= utc_offset_hours * 3600 unless utc_offset_hours.zero?
        points << tp
      end
    end

    raise "No valid GPS records found in #{dir}" if points.empty?

    points
  end

  # Returns [first_time, last_time] for a single clip file, using its own
  # embedded GPS records (not the filename) so clip boundaries line up
  # exactly with a previously-merged trip GPX. Includes void ('V') records so
  # first_time reflects the clip's true start even if GPS hadn't locked yet
  # (only matters in practice for the first clip of a trip) -- otherwise
  # frame 0 of the overlay would be wrongly pinned to the first *fixed*
  # position instead of the video's actual start.
  def clip_time_range(path, utc_offset_hours: 0)
    first_time = nil
    last_time = nil

    each_record(path, include_void: true) do |tp|
      t = tp.time - utc_offset_hours * 3600
      # A jump this large means the RTC just got corrected (see
      # CLOCK_JUMP_SECONDS) -- records before it are on a different, bogus
      # time base, so restart the range from here instead of anchoring to
      # them.
      first_time = t if first_time.nil? || (t - last_time).abs > CLOCK_JUMP_SECONDS
      last_time = t
    end

    raise "No GPS records (valid or void) found in #{path}" unless first_time

    [first_time, last_time]
  end

  # Writes a merged trackpoint list (from collect_trip) out as a GPX file,
  # with speed/course as extensions.
  def write_gpx(points, output_path, creator: "gps_extractor.rb")
    File.open(output_path, "w") do |f|
      f.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="#{creator}" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>Dashcam Trip</name>
            <trkseg>
      XML

      points.each do |p|
        f.write(<<~XML)
              <trkpt lat="#{format('%.7f', p.lat)}" lon="#{format('%.7f', p.lon)}">
                <time>#{p.time.strftime('%Y-%m-%dT%H:%M:%SZ')}</time>
                <extensions>
                  <speed>#{format('%.2f', p.speed_kmh)}</speed>
                  <course>#{format('%.1f', p.course)}</course>
                </extensions>
              </trkpt>
        XML
      end

      f.write(<<~XML)
            </trkseg>
          </trk>
        </gpx>
      XML
    end
  end
end

#!/usr/bin/env ruby
# frozen_string_literal: true

# Merges the Novatek "freeGPS" GPS records from all clips of a dashcam trip
# (see lib/novatek_gps.rb for the record format) into a single continuous
# GPX file.

require "optparse"
require "time"
require_relative "lib/novatek_gps"

if __FILE__ == $PROGRAM_NAME
  options = { output: "trip.gpx", pattern: "*.MP4", utc_offset: 0 }

  OptionParser.new do |opts|
    opts.banner = "Usage: ruby gps_extractor.rb <input_dir> [options]"
    opts.on("-o", "--output PATH", "Output GPX file path (default: trip.gpx)") { |v| options[:output] = v }
    opts.on("--pattern GLOB", "Filename glob within input_dir (default: *.MP4)") { |v| options[:pattern] = v }
    opts.on(
      "--utc-offset HOURS", Float,
      "Camera clock's UTC offset in hours, e.g. 3 for UTC+3 (default: 0 -- " \
      "embedded timestamps are treated as already UTC)"
    ) { |v| options[:utc_offset] = v }
  end.parse!

  input_dir = ARGV.shift || "."

  points = NovatekGps.collect_trip(input_dir, pattern: options[:pattern], utc_offset_hours: options[:utc_offset])
  NovatekGps.write_gpx(points, options[:output])

  puts "#{points.size} trackpoints (#{points.first.time} to #{points.last.time}) -> #{options[:output]}"
end

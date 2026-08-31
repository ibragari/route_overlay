# frozen_string_literal: true

require "rexml/document"
require "time"

GpxPoint = Struct.new(:time, :lat, :lon, :speed_kmh, :course, keyword_init: true)

module GpxReader
  module_function

  # Reads a GPX file (as produced by gps_extractor.rb) into an array of
  # GpxPoint, sorted by time.
  def read(path)
    doc = REXML::Document.new(File.read(path))
    points = doc.get_elements("//trkpt").map do |el|
      speed_el = el.get_elements("extensions/speed").first
      course_el = el.get_elements("extensions/course").first
      GpxPoint.new(
        time: Time.parse(el.get_elements("time").first.text),
        lat: el.attributes["lat"].to_f,
        lon: el.attributes["lon"].to_f,
        speed_kmh: speed_el ? speed_el.text.to_f : nil,
        course: course_el ? course_el.text.to_f : nil
      )
    end
    points.sort_by!(&:time)
    raise "No trackpoints found in #{path}" if points.empty?

    points
  end
end

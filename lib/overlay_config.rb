# frozen_string_literal: true

require "yaml"
require "ostruct"

# Loads overlay_config.yml into a nested OpenStruct so settings can be
# accessed as config.map.window_mode, config.inset.corner, etc.
module OverlayConfig
  module_function

  def load(path)
    raw = YAML.load_file(path)
    to_ostruct(raw)
  end

  def to_ostruct(value)
    case value
    when Hash
      OpenStruct.new(value.transform_values { |v| to_ostruct(v) })
    when Array
      value.map { |v| to_ostruct(v) }
    else
      value
    end
  end
end

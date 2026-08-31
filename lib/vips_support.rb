# frozen_string_literal: true

# Best-effort detection/loading of libvips (via the ruby-vips gem) for the
# much faster VipsMosaicRenderer path -- overlay_generator.rb uses this to
# decide whether to use it or fall back to the pure-Ruby MosaicRenderer.
# Never raises: any failure to load just means "not available".
#
# `gem install ruby-vips` installs cleanly on its own (it's ffi-based, no
# compiler needed), but it still needs the actual libvips native library
# present at runtime. If you have it installed system-wide already, this
# just works. Otherwise, drop a libvips Windows build's `bin` folder
# (download from https://github.com/libvips/build-win64-mxe/releases,
# `vips-dev-x64-web-*.zip` is enough) at `vendor/vips_bin` next to this
# project's scripts, and this will pick it up automatically.
module VipsSupport
  module_function

  def available?
    return @available if defined?(@available)

    @available = try_load
  end

  def try_load
    add_vendored_dll_directory if Gem.win_platform?
    require "vips"
    true
  rescue LoadError, StandardError
    false
  end
  private_class_method :try_load

  # ruby-vips locates libvips via the OS's normal shared-library search,
  # which on Windows does not reliably include PATH for libraries loaded
  # this way (a modern "safe DLL search" restriction) -- SetDllDirectoryA
  # explicitly registers a supplementary search directory that the loader
  # does respect, for this and every DLL it depends on in turn.
  def add_vendored_dll_directory
    vendored_bin = File.expand_path("../vendor/vips_bin", __dir__)
    return unless Dir.exist?(vendored_bin)

    require "fiddle"
    set_dll_directory = Fiddle::Function.new(
      Fiddle::Handle.new("kernel32.dll")["SetDllDirectoryA"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT
    )
    set_dll_directory.call(vendored_bin)
  end
  private_class_method :add_vendored_dll_directory
end

# CFF2 variations acceptance test vs the system FreeType oracle.
#
# SourceSerif4Variable-Roman.otf (adobe-fonts release 4.005R): CFF2 with
# fvar (wght 200..900, opsz 8..60), avar, HVAR, MVAR and six FDs whose
# Private DICT hinting entries (BlueValues, StdHW/StdVW, StemSnap) are
# blended through the VariationStore — the cff_blend_doBlend path. The
# font is not redistributable with the repo, so it is downloaded on
# demand from the upstream release zip into /tmp.
#
# Per coordinate set (default instance, a mid named instance, an
# intermediate point and both axis extremes) and ppem (16/32): unhinted
# and Adobe-hinted outlines plus advances, all glyphs, vs the system
# FreeType. A sensitivity check additionally verifies that the outlines
# genuinely move between the default and the wght=900 instance.
#
# Run: crystal run --release spec/cff2_var_diff.cr

require "./oracle_lib"
require "../src/freetype-cr"

STDOUT.flush_on_newline = true

FONT_PATH = "/tmp/SourceSerif4Variable-Roman.otf"
ZIP_URL   = "https://github.com/adobe-fonts/source-serif/releases/download/4.005R/source-serif-4.005_Desktop.zip"
ZIP_PATH  = "/tmp/source-serif-4.005_Desktop.zip"
ZIP_ENTRY = "source-serif-4.005_Desktop/VAR/SourceSerif4Variable-Roman.otf"

unless File.exists?(FONT_PATH)
  here = File.dirname(__FILE__)
  puts "downloading #{FONT_PATH} ..."
  ok = Process.run("curl", {"-sSfL", "-o", ZIP_PATH, ZIP_URL},
                   output: :inherit, error: :inherit)
  raise "font download failed (curl required)" unless ok.success?
  ok = Process.run("unzip", {"-o", "-j", ZIP_PATH, ZIP_ENTRY, "-d", "/tmp"},
                   output: :inherit, error: :inherit)
  raise "unzip failed" unless ok.success?
end

data = File.read(FONT_PATH).to_slice
font = TT::Font.new(data)
blend = TT::GXBlend.from_font(font)
raise "test font is not variable" if blend.nil?

n_axis = blend.num_axis
sets = [
  blend.axis.map(&.default),
  blend.namedstyle[blend.namedstyle.size // 2].coords,
  blend.axis.map { |a| a.default + (a.maximum - a.default) // 3 },
  blend.axis.map(&.minimum),
  blend.axis.map(&.maximum),
]
SIZES = {16, 32}

lib_ptr = uninitialized Void*
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0
ft_face = FtFace.new(lib_ptr, FONT_PATH)
face = ft_face.face

total_checks = 0
total_fails = 0
first_failures = [] of String

sets.each do |coords|
  err = LibFT.set_var_design(face, n_axis, coords.to_unsafe.as(Int64*))
  raise "FT_Set_Var_Design_Coordinates failed: #{err}" if err != 0

  SIZES.each do |px|
    LibFT.set_pixel_sizes(face, 0, px)
    cf = CFF::Face.new(data)
    cf.set_pixel_size(px)
    cf.set_var_design(coords)

    # unhinted (FT_LOAD_NO_HINTING) and Adobe-hinted (FT_LOAD_DEFAULT)
    {false, true}.each do |hint|
      flags = (hint ? LibFT::FT_LOAD_DEFAULT : LibFT::FT_LOAD_NO_HINTING) |
              LibFT::FT_LOAD_NO_BITMAP
      face.value.num_glyphs.times do |gid|
        snap = load_outline(face, gid, flags)
        total_checks += 1

        g = cf.load_glyph(gid, hint)
        ok = true
        if snap.nil?
          ok = g.xs.empty?
        else
          ok = g.xs == snap.xs && g.ys == snap.ys && g.contours == snap.contours
        end
        adv = face.value.glyph.value.advance.x
        ok = false if adv != g.advance

        unless ok
          total_fails += 1
          if first_failures.size < 10
            snap_n = snap ? snap.not_nil!.xs.size : -1
            first_failures << "#{FONT_PATH} hint=#{hint} px=#{px} " \
                              "coords=#{coords.map { |c| c // 65536 }} " \
                              "gid=#{gid}: ours np=#{g.xs.size} ft np=#{snap_n} " \
                              "adv=#{g.advance} ft_adv=#{adv}"
          end
        end
      end
    end
  end
end

ft_face.done
LibFT.done_free_type(lib_ptr)

# Sensitivity: the instance must actually matter — at least some of the
# sampled outlines differ between the default and the wght=900 master.
sens_default = begin
  cf = CFF::Face.new(data)
  cf.set_pixel_size(16)
  cf.set_var_design(blend.axis.map(&.default))
  (0...face.value.num_glyphs).select { |gid| gid % 97 == 0 }
    .map { |gid| cf.load_glyph(gid, false) }
end
sens_max = begin
  cf = CFF::Face.new(data)
  cf.set_pixel_size(16)
  cf.set_var_design(blend.axis.map(&.maximum))
  (0...face.value.num_glyphs).select { |gid| gid % 97 == 0 }
    .map { |gid| cf.load_glyph(gid, false) }
end
sens_diffs = sens_default.zip(sens_max).count { |a, b| a.xs != b.xs || a.ys != b.ys }
puts "sensitivity: #{sens_diffs}/#{sens_default.size} sampled outlines " \
     "differ between default and max instance"
if sens_diffs.zero?
  total_fails += 1
  first_failures << "sensitivity check failed: no outline reacts to wght"
end

puts
first_failures.each { |f| puts "  #{f}" }
puts "\ncompared #{total_checks} glyph loads; fails: #{total_fails}"
puts "RESULT: #{total_fails.zero? ? "PASS" : "FAIL"}"
exit(total_fails.zero? ? 0 : 1)

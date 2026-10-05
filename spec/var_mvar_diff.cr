# MVAR (metrics variations) acceptance test vs the system FreeType
# oracle.
#
# The test font is Liberation Sans Regular with an `fvar' wght axis
# (400..700, default 400) and an `MVAR' table whose single region peaks
# at wght=700, adjusting ten metric tags (hasc/hdsc/hlgp typo metrics,
# hcla/hcld win metrics, undo/unds underline, xhgt/stro/strs os/2
# values). It is synthesized on demand by spec/gen_var_mvar_font.py
# (pure python3) into /tmp.
#
# The face-level FT_Face metrics (ascender, descender, height,
# underline position/thickness — font units) are compared after a
# sequence of coordinate changes, including an identical re-set (which
# FreeType short-circuits: TT_Set_Var_Design's -1 skips the metrics
# adjust) and a back-and-forth change — the derived line metrics react
# additively in tt_apply_mvar, so this pins that exact semantics.
#
# Run: crystal run --release spec/var_mvar_diff.cr

require "./oracle_lib"
require "../src/freetype-cr"

STDOUT.flush_on_newline = true

FONT_PATH = "/tmp/LibVarMvar.ttf"

unless File.exists?(FONT_PATH)
  here = File.dirname(__FILE__)
  puts "generating #{FONT_PATH} ..."
  ok = Process.run("python3", {File.join(here, "gen_var_mvar_font.py")},
                   output: :inherit, error: :inherit)
  raise "font generation failed (python3 required)" unless ok.success?
end

data = File.read(FONT_PATH).to_slice
font = TT::Font.new(data)
blend = TT::GXBlend.from_font(font)
raise "test font is not variable" if blend.nil?

# default, mid, peak, peak again (no-change), back to mid, default.
SEQUENCE = [400_i64 << 16, 550_i64 << 16, 700_i64 << 16,
            700_i64 << 16, 550_i64 << 16, 400_i64 << 16]

lib_ptr = uninitialized Void*
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0
ft_face = FtFace.new(lib_ptr, FONT_PATH)
face = ft_face.face

total_checks = 0
total_fails = 0
first_failures = [] of String

hf = TT::HintedFace.new(data)

SEQUENCE.each do |wght|
  err = LibFT.set_var_design(face, 1, pointerof(wght))
  raise "FT_Set_Var_Design_Coordinates failed: #{err}" if err != 0
  hf.set_var_design([wght])

  f = face.value
  hf_font = hf.font # MVAR mutates the face's own TT::Font
  ours = {hf_font.ascender, hf_font.descender, hf_font.height,
          hf_font.underline_position, hf_font.underline_thickness}
  oracle = {f.ascender.to_i32, f.descender.to_i32, f.height.to_i32,
            f.underline_position.to_i32, f.underline_thickness.to_i32}
  names = {"ascender", "descender", "height",
           "underline_pos", "underline_thick"}

  total_checks += ours.size
  ours.each_with_index do |v, i|
    next if v == oracle[i]
    total_fails += 1
    if first_failures.size < 10
      first_failures << "#{FONT_PATH} wght=#{wght // 65536}: " \
                        "#{names[i]} ours=#{v} oracle=#{oracle[i]}"
    end
  end
end

ft_face.done
LibFT.done_free_type(lib_ptr)

# The outlines themselves must stay untouched by MVAR (no gvar): spot
# check one glyph against the oracle at the peak instance.
hf2 = TT::HintedFace.new(data)
hf2.set_pixel_size(16)
hf2.set_var_design([700_i64 << 16])
lib_ptr2 = uninitialized Void*
LibFT.init_free_type(pointerof(lib_ptr2))
ft_face = FtFace.new(lib_ptr2, FONT_PATH)
face = ft_face.face
wght = 700_i64 << 16
LibFT.set_var_design(face, 1, pointerof(wght))
LibFT.set_pixel_sizes(face, 0, 16)
gid = LibFT.get_char_index(face, 'A'.ord)
snap = load_outline(face, gid.to_i32,
                    LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
g = hf2.load_glyph(gid.to_i32, hint: true)
total_checks += 1
if snap.nil? || g.xs != snap.xs || g.ys != snap.ys
  total_fails += 1
  first_failures << "#{FONT_PATH} wght=700: outline of 'A' diverged"
end
ft_face.done
LibFT.done_free_type(lib_ptr2)

puts
first_failures.each { |f| puts "  #{f}" }
puts "\ncompared #{total_checks} metric values; fails: #{total_fails}"
puts "RESULT: #{total_fails.zero? ? "PASS" : "FAIL"}"
exit(total_fails.zero? ? 0 : 1)

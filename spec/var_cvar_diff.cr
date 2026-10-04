# cvar (CVT variation) acceptance test vs the system FreeType oracle.
#
# The test font is Liberation Sans Regular with an `fvar' wght axis
# (400..700, default 400) and a `cvar' tuple peaking at wght=700 that
# shifts every CVT entry by +20 font units — the bytecode (fpgm/prep and
# the glyph programs) consumes them, so hinted outlines genuinely move
# with the instance. It is synthesized on demand by
# spec/gen_var_cvar_font.py (pure python3, no fontTools) into /tmp.
#
# Per coordinate set (wght 400/550/700) and ppem (12/16/24): hinted
# outlines and advances, all glyphs, vs FT_LOAD_DEFAULT | NO_BITMAP.
#
# Run: crystal run --release spec/var_cvar_diff.cr

require "./oracle_lib"
require "../src/freetype-cr"

STDOUT.flush_on_newline = true

FONT_PATH = "/tmp/LibVarCvar.ttf"

unless File.exists?(FONT_PATH)
  here = File.dirname(__FILE__)
  puts "generating #{FONT_PATH} ..."
  ok = Process.run("python3", {File.join(here, "gen_var_cvar_font.py")},
                   output: :inherit, error: :inherit)
  raise "font generation failed (python3 required)" unless ok.success?
end

SETS = {400_i64 << 16, 550_i64 << 16, 700_i64 << 16}
SIZES = {12, 16, 24}

data = File.read(FONT_PATH).to_slice
font = TT::Font.new(data)
blend = TT::GXBlend.from_font(font)
raise "test font is not variable" if blend.nil?

lib_ptr = uninitialized Void*
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0
ft_face = FtFace.new(lib_ptr, FONT_PATH)
face = ft_face.face

total_checks = 0
total_fails = 0
first_failures = [] of String

SETS.each do |wght|
  err = LibFT.set_var_design(face, 1, pointerof(wght))
  raise "FT_Set_Var_Design_Coordinates failed: #{err}" if err != 0

  SIZES.each do |px|
    LibFT.set_pixel_sizes(face, 0, px)
    hf = TT::HintedFace.new(data)
    hf.set_pixel_size(px)
    hf.set_var_design([wght])

    face.value.num_glyphs.times do |gid|
      snap = load_outline(face, gid,
                          LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
      total_checks += 1

      ok = true
      g = hf.load_glyph(gid, hint: true)
      if snap.nil?
        ok = g.xs.empty?
        adv = face.value.glyph.value.advance.x
        ok = false if adv != g.advance
      else
        ok = g.xs == snap.xs && g.ys == snap.ys &&
             g.tags.map(&.& 0xE7_u8) == snap.tags.map(&.& 0xE7_u8) &&
             g.contours == snap.contours
        adv = face.value.glyph.value.advance.x
        ok = false if adv != g.advance
      end

      unless ok
        total_fails += 1
        if first_failures.size < 10
          snap_n = snap ? snap.not_nil!.xs.size : -1
          first_failures << "#{FONT_PATH} wght=#{wght // 65536} px=#{px} " \
                            "gid=#{gid}: ours np=#{g.xs.size} ft np=#{snap_n} " \
                            "adv=#{g.advance} ft_adv=#{adv}"
        end
      end
    end
  end
end

ft_face.done
LibFT.done_free_type(lib_ptr)

puts
first_failures.each { |f| puts "  #{f}" }
puts "\ncompared #{total_checks} hinted glyph loads; fails: #{total_fails}"
puts "RESULT: #{total_fails.zero? ? "PASS" : "FAIL"}"
exit(total_fails.zero? ? 0 : 1)

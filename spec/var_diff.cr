# GX variations acceptance test: the full glyph-loading pipeline with
# fvar/avar/gvar/HVAR applied (src/tt/ttgxvar.cr + the loader hooks in
# src/tt/loader.cr) vs the system FreeType oracle.
#
# Per font (every variable Ubuntu face), per coordinate set (all named
# instances plus intermediate corners), per ppem:
#   1. outline:   load_glyph(gid, hint) vs FT_LOAD_[NO_HINTING ]| NO_BITMAP
#                 snapshot (points/tags/contours), both hinted and unhinted
#   2. advance:   LoadedGlyph#advance          vs  slot.advance.x
#
# The Ubuntu faces carry no bytecode (empty `fpgm', a 7-byte `prep', and
# no glyph instructions), so hinted loading runs the bytecode path with
# no glyph programs — the variable counterpart of tt_hinted_diff.cr's
# static corpus; autohint_diff.cr covers the bytecode-less fonts.
#
# Run: crystal run --release spec/var_diff.cr [-- <font.ttf> ...]

require "./oracle_lib"
require "../src/freetype-cr"

STDOUT.flush_on_newline = true

VAR_FONTS = {
  "/usr/share/fonts/truetype/ubuntu/Ubuntu[wdth,wght].ttf",
  "/usr/share/fonts/truetype/ubuntu/Ubuntu-Italic[wdth,wght].ttf",
  "/usr/share/fonts/truetype/ubuntu/UbuntuSans[wdth,wght].ttf",
  "/usr/share/fonts/truetype/ubuntu/UbuntuSans-Italic[wdth,wght].ttf",
  "/usr/share/fonts/truetype/ubuntu/UbuntuMono[wght].ttf",
  "/usr/share/fonts/truetype/ubuntu/UbuntuSansMono[wght].ttf",
  "/usr/share/fonts/truetype/ubuntu/UbuntuSansMono-Italic[wght].ttf",
}

SIZES = {16, 32}

font_paths = ARGV.empty? ? VAR_FONTS.to_a : ARGV

lib_ptr = uninitialized Void*
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0

total_checks = 0
total_fails = 0
first_failures = [] of String

font_paths.uniq.each do |path|
  unless File.exists?(path)
    puts "skip (missing): #{path}"
    next
  end

  data = File.read(path).to_slice
  font = TT::Font.new(data)
  blend = TT::GXBlend.from_font(font)
  if blend.nil?
    puts "skip (not variable): #{path}"
    next
  end
  n_axis = blend.num_axis

  # every named instance plus intermediate corners
  sets = blend.namedstyle.map(&.coords)
  sets << blend.axis.map { |a| a.default + (a.maximum - a.default) // 3 }
  if n_axis == 2
    sets << [blend.axis[0].minimum, blend.axis[1].maximum]
    sets << [blend.axis[0].maximum, blend.axis[1].minimum]
  end

  ft_face = FtFace.new(lib_ptr, path)
  face = ft_face.face

  font_checks = 0
  font_fails = 0

  sets.each do |coords|
    err = LibFT.set_var_design(face, n_axis, coords.to_unsafe)
    raise "FT_Set_Var_Design_Coordinates failed: #{err}" if err != 0

    SIZES.each do |px|
      LibFT.set_pixel_sizes(face, 0, px)
      hf = TT::HintedFace.new(data)
      hf.set_pixel_size(px)
      hf.set_var_design(coords)

      face.value.num_glyphs.times do |gid|
        snap = load_outline(face, gid,
                            LibFT::FT_LOAD_NO_HINTING | LibFT::FT_LOAD_NO_BITMAP)
        font_checks += 1

        ok = true
        g = hf.load_glyph(gid, hint: false)
        if snap.nil?
          # empty glyph on the oracle side (n_points == 0): our outline
          # must be empty too, but the advance still has to match
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
          font_fails += 1
          if first_failures.size < 10
            snap_n = snap ? snap.not_nil!.xs.size : -1
            first_failures << "#{File.basename(path)} px=#{px} gid=#{gid} " \
                              "coords=#{coords.map { |c| c // 65536 }}: " \
                              "ours np=#{g.xs.size} ft np=#{snap_n} " \
                              "adv=#{g.advance} ft_adv=#{adv}"
          end
        end
      end

      # hinted load: FT_LOAD_DEFAULT | NO_BITMAP
      face.value.num_glyphs.times do |gid|
        snap = load_outline(face, gid,
                            LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
        font_checks += 1

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
          font_fails += 1
          if first_failures.size < 10
            snap_n = snap ? snap.not_nil!.xs.size : -1
            first_failures << "#{File.basename(path)} px=#{px} gid=#{gid} " \
                              "coords=#{coords.map { |c| c // 65536 }} (hinted): " \
                              "ours np=#{g.xs.size} ft np=#{snap_n} " \
                              "adv=#{g.advance} ft_adv=#{adv}"
          end
        end
      end
    end
  end

  ft_face.done
  total_checks += font_checks
  total_fails += font_fails
  status = font_fails.zero? ? "OK " : "DIFF"
  puts "#{status} #{File.basename(path)}: #{font_checks} checks, " \
       "fails: #{font_fails}"
end

LibFT.done_free_type(lib_ptr)

puts
first_failures.each { |f| puts "  #{f}" }
puts "\ncompared #{total_checks} glyph loads; fails: #{total_fails}"
puts "RESULT: #{total_fails.zero? ? "PASS" : "FAIL"}"
exit(total_fails.zero? ? 0 : 1)

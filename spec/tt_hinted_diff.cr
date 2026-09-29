# B2 acceptance test: our TT::HintedFace hinted pipeline (sfnt.cr +
# loader.cr + ttinterp.cr) vs the system FreeType on hinted fonts.
#
# Per glyph/size:
#   1. outline:   load_glyph(gid, hint: true)  vs  FT_LOAD_DEFAULT |
#                 FT_LOAD_NO_BITMAP snapshot (points/tags/contours)
#   2. advance:   LoadedGlyph#advance          vs  slot.advance.x
#   3. bitmap:    Ftrender on our outline       vs  FT_LOAD_RENDER bitmap
#
# Also runs the unhinted font NotoSans-Regular.ttf with hint: true: it has
# real `fpgm'/`prep' tables, so FreeType runs the phantom machinery there.
# Bytecode-less fonts (e.g. Roboto unhinted) are NOT included: FreeType
# hands them to the autofit module (ftobjs.c: no fpgm && prep <= 7), which
# is out of scope; they are covered by tt_unhinted_diff.cr instead.
#
# Run: crystal run --release spec/tt_hinted_diff.cr [-- <font.ttf> ...]

require "./oracle_lib"
require "../src/tt/loader"
require "../src/ftrender"

STDOUT.flush_on_newline = true

HINTED_FONTS = {
  "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
}

# The system FreeType (2.13.3) disagrees with FreeType master -- and with
# us, byte for byte -- on exactly these loads: a few points move by 1/64px
# (verified against a locally built master oracle in tmp_c/ttoracle).
# Expected, not a regression; re-check when the system library is updated.
EXPECTED_OUTLINE_DIFFS = {
  {"LiberationMono-Regular.ttf", 12, 2215},
  {"LiberationMono-Regular.ttf", 13, 2215},
}

UNHINTED_FONTS = {
  "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}

SIZES = {12, 13, 16, 24, 37}

font_paths = ARGV.empty? ? (HINTED_FONTS + UNHINTED_FONTS).to_a : ARGV

lib_ptr = uninitialized Void*
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0

total_glyphs = 0
total_outline_fails = 0
total_diff_pixels = 0_i64
version_divergent = 0
first_failures = [] of String

font_paths.uniq.each do |path|
  unless File.exists?(path)
    puts "skip (missing): #{path}"
    next
  end

  ft_face = FtFace.new(lib_ptr, path)
  face = ft_face.face
  font = TT::HintedFace.new(File.read(path).to_slice)

  font_outline_fails = 0
  font_diff_pixels = 0_i64
  font_glyphs = 0

  SIZES.each do |px|
    LibFT.set_pixel_sizes(face, 0, px)
    font.set_pixel_size(px)

    face.value.num_glyphs.times do |gid|
      snap = load_outline(face, gid, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
      begin
        g = font.load_glyph(gid, hint: true)
      rescue ex : TT::ParseError | TT::ExecutionError
        font_outline_fails += 1
        first_failures << "#{File.basename(path)} px=#{px} gid=#{gid}: raised #{ex.class}" if first_failures.size < 10
        next
      end
      font_glyphs += 1

      ok = true
      if snap.nil?
        ok = g.xs.empty?
      else
        # Tags are compared with the hinter-internal touch bits
        # (FT_CURVE_TAG_TOUCH_X/Y, 0x18) masked out: they are TrueType VM
        # bookkeeping that leaks into FT_Outline.tags, are ignored by the
        # smooth rasterizer, and differ between FreeType releases (our
        # values match FreeType master; the system 2.13.3 library puts
        # them on other points for a couple of LiberationMono glyphs
        # while the geometry is identical).
        ok = g.xs == snap.xs && g.ys == snap.ys &&
             g.tags.map(&.& 0xE7_u8) == snap.tags.map(&.& 0xE7_u8) &&
             g.contours == snap.contours
      end
      adv = face.value.glyph.value.advance.x
      ok = false if adv != g.advance
      unless ok
        if EXPECTED_OUTLINE_DIFFS.includes?({File.basename(path), px, gid})
          version_divergent += 1
        else
          font_outline_fails += 1
          if first_failures.size < 10
            snap_n = snap ? snap.not_nil!.xs.size : -1
            first_failures << "#{File.basename(path)} px=#{px} gid=#{gid}: " \
                              "ours np=#{g.xs.size} ft np=#{snap_n} " \
                              "adv=#{g.advance} ft_adv=#{adv}"
          end
        end
        next
      end

      # bitmap comparison
      if LibFT.load_glyph(face, gid, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_RENDER) != 0
        next
      end
      oracle = OracleBitmap.new(face.value.glyph.value)
      if g.xs.empty? || g.contours.empty?
        mine = Ftrender::GlyphBitmap.blank
      else
        outline = Ftgrays::Outline.new(g.xs, g.ys, g.tags, g.contours)
        mine = Ftrender.render_glyph(outline)
      end
      if mine.width != oracle.width || mine.height != oracle.height ||
         mine.left != oracle.left || mine.top != oracle.top
        font_diff_pixels += 1
        if first_failures.size < 10
          first_failures << "#{File.basename(path)} px=#{px} gid=#{gid}: bitmap dims " \
                            "#{mine.width}x#{mine.height}+#{mine.left}+#{mine.top} vs " \
                            "#{oracle.width}x#{oracle.height}+#{oracle.left}+#{oracle.top}"
        end
        next
      end
      (mine.width * mine.height).times do |i|
        if mine.buffer[i] != oracle.cov[i]
          font_diff_pixels += 1
          break
        end
      end
    end
  end

  ft_face.done
  total_glyphs += font_glyphs
  total_outline_fails += font_outline_fails
  total_diff_pixels += font_diff_pixels
  status = font_outline_fails.zero? && font_diff_pixels.zero? ? "OK " : "DIFF"
  puts "#{status} #{File.basename(path)}: #{font_glyphs} glyphs, " \
       "outline fails: #{font_outline_fails}, bitmap diffs: #{font_diff_pixels}"
end

LibFT.done_free_type(lib_ptr)

puts
first_failures.each { |f| puts "  #{f}" }
puts "\ncompared #{total_glyphs} glyphs; outline fails: #{total_outline_fails}, " \
     "bitmap diffs: #{total_diff_pixels}, " \
     "version-divergent vs system FT (expected): #{version_divergent}"
ok = total_outline_fails.zero? && total_diff_pixels.zero?
puts "RESULT: #{ok ? "PASS" : "FAIL"}"
exit(ok ? 0 : 1)

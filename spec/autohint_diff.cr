# Auto-hinter acceptance test: our autofit port (src/autofit/*) on
# bytecode-less fonts (no `fpgm', `prep' <= 7 instructions) vs the system
# FreeType with FT_LOAD_DEFAULT, where ftobjs.c hands the glyph to the
# autofit module.
#
# Per glyph/size:
#   1. outline:   load_glyph(gid, hint: true)  vs  FT_LOAD_DEFAULT |
#                 FT_LOAD_NO_BITMAP snapshot (points/tags/contours)
#   2. advance:   LoadedGlyph#advance          vs  slot.advance.x
#   3. bitmap:    Ftrender on our outline       vs  FT_LOAD_RENDER bitmap
#
# Run: crystal run --release spec/autohint_diff.cr [-- <font.ttf> ...]

require "./oracle_lib"
require "../src/autofit/afloader"
require "../src/tt/loader"
require "../src/ftrender"

STDOUT.flush_on_newline = true

AUTOHINT_FONTS = {
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Bold.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Italic.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-BoldItalic.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Medium.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Black.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoCondensed-Regular.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoCondensed-Bold.ttf",
}

SIZES = {12, 13, 16, 24, 37}

font_paths = ARGV.empty? ? AUTOHINT_FONTS.to_a : ARGV

lib_ptr = uninitialized Void*
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0

total_glyphs = 0
total_outline_fails = 0
total_diff_pixels = 0_i64
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
        # (FT_CURVE_TAG_TOUCH_X/Y, 0x18) masked out, exactly as in
        # tt_hinted_diff.cr.
        ok = g.xs == snap.xs && g.ys == snap.ys &&
             g.tags.map(&.& 0xE7_u8) == snap.tags.map(&.& 0xE7_u8) &&
             g.contours == snap.contours
      end
      adv = face.value.glyph.value.advance.x
      ok = false if adv != g.advance
      unless ok
        font_outline_fails += 1
        if first_failures.size < 10
          snap_n = snap ? snap.not_nil!.xs.size : -1
          first_failures << "#{File.basename(path)} px=#{px} gid=#{gid}: " \
                            "ours np=#{g.xs.size} ft np=#{snap_n} " \
                            "adv=#{g.advance} ft_adv=#{adv}"
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
     "bitmap diffs: #{total_diff_pixels}"
ok = total_outline_fails.zero? && total_diff_pixels.zero?
puts "RESULT: #{ok ? "PASS" : "FAIL"}"
exit(ok ? 0 : 1)

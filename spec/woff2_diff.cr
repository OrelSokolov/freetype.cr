# WOFF2 acceptance test: unwrap real .woff2 webfonts through
# TT.unwrap_woff2 (pure-Crystal brotli decoder + glyf/loca/hmtx
# reconstruction) and diff both the hinted and unhinted pipelines against
# the system FreeType loading the same .woff2 file.
#
# Requirements (this spec is not part of the default CI):
#   * WOFF2 is compiled in by default (add -Dnative_brotli to use
#     libbrotlidec through FFI instead of the brotli shard)
#   * the oracle FreeType must be built with brotli (the system
#     libfreetype on Debian/Ubuntu has it; the CI oracle tarball build
#     in .github/workflows/ci.yml deliberately has it disabled)
#   * a corpus of .woff2 files in tmp_check/w2_*.woff2 (e.g. fetched
#     from Google Fonts; see README)
#
# Run: crystal run --release spec/woff2_diff.cr

require "./oracle_lib"
require "../src/tt/loader"
require "../src/ftrender"

STDOUT.flush_on_newline = true

SIZES = {12, 13, 16, 24, 37}

corpus = Dir["tmp_check/w2_*.woff2"].sort
corpus += ARGV unless ARGV.empty?
if corpus.empty?
  puts "skip: no WOFF2 corpus (put tmp_check/w2_*.woff2 or pass paths)"
  exit 0
end

lib_ptr = uninitialized Void*
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0

total_glyphs = 0
total_outline_fails = 0
total_diff_pixels = 0_i64
first_failures = [] of String

corpus.uniq.each do |path|
  unless File.exists?(path)
    puts "skip (missing): #{path}"
    next
  end

  ft_face = FtFace.new(lib_ptr, path)
  face = ft_face.face
  font = TT::HintedFace.new(File.read(path).to_slice)

  # FreeType hands bytecode-less fonts (no fpgm, tiny prep) to the
  # autohinter, which is out of scope — only diff the hinted pipeline
  # on fonts that carry real bytecode (tt_hinted_diff.cr convention).
  has_bytecode = !font.font.fpgm.empty? && font.font.prep.size > 7

  font_outline_fails = 0
  font_diff_pixels = 0_i64
  font_glyphs = 0

  SIZES.each do |px|
    LibFT.set_pixel_sizes(face, 0, px)
    font.set_pixel_size(px)

    face.value.num_glyphs.times do |gid|
      load_flags = has_bytecode ? LibFT::FT_LOAD_DEFAULT : LibFT::FT_LOAD_NO_HINTING
      snap = load_outline(face, gid, load_flags | LibFT::FT_LOAD_NO_BITMAP)
      begin
        g = font.load_glyph(gid, hint: has_bytecode)
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

      next unless has_bytecode
      if LibFT.load_glyph(face, gid, load_flags | LibFT::FT_LOAD_RENDER) != 0
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
  mode = has_bytecode ? "hinted" : "unhinted"
  puts "#{status} #{File.basename(path)} [#{mode}]: #{font_glyphs} glyphs, " \
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

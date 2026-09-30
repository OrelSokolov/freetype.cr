# Rasterizer acceptance test: pixel diff == 0 between our
# Ftrender pipeline and the system FreeType on unhinted fonts.
#
#   oracle : FT_Load_Glyph( FT_LOAD_DEFAULT | FT_LOAD_RENDER )  -> bitmap
#   ours   : FT_Load_Glyph( FT_LOAD_DEFAULT | FT_LOAD_NO_BITMAP ) -> copy
#            the FT_Outline, render through Ftgrays + Ftrender
#
# Fonts are auto-classified: sampled glyphs must load identically with
# and without hinting (FT_LOAD_NO_HINTING) — for fonts without hint
# bytecode FreeType scales and moves on, which is exactly the pipeline
# ported here. Hinted fonts are skipped with a notice (they need the hinting pipeline).
#
# Run: crystal run --release spec/ftgrays_diff.cr [-- <font.ttf> ...]
require "./oracle_lib"

STDOUT.flush_on_newline = true # keep progress visible through pipes

# --- corpus -------------------------------------------------------------------

DEFAULT_FONTS = [
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Bold.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Italic.ttf",
  "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
  "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
  "/usr/share/fonts/truetype/noto/NotoSerif-Regular.ttf",
  "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
]

SIZES = {12, 13, 16, 24, 37}
MAX_GLYPHS_PER_FONT = 400
# Set DUMP_DIFFS=n to ASCII-dump the first n mismatching glyphs.
DUMP_DIFFS = (ENV["DUMP_DIFFS"]? || "0").to_i
dump_budget = DUMP_DIFFS

font_paths = ARGV.empty? ? DEFAULT_FONTS : ARGV
font_paths += Dir["/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/*.ttf"] if ARGV.empty?

lib_ptr = uninitialized Void*
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0

total_glyphs = 0
total_diff_pixels = 0_i64
failed = false
compared_fonts = 0

font_paths.uniq.each do |path|
  unless File.exists?(path)
    puts "skip (missing): #{path}"
    next
  end
  ft_face = FtFace.new(lib_ptr, path)
  face = ft_face.face

  # Classify: sampled glyphs must be hint-identical (unhinted font).
  # (Set a size first: loading before any FT_Set_Pixel_Sizes scales at
  # ppem 0 and crashes the TT driver.)
  n_glyphs = face.value.num_glyphs
  LibFT.set_pixel_sizes(face, 0, 16)
  sample_step = (n_glyphs // 64).clamp(1, n_glyphs)
  hinted = false
  gid = 0
  while gid < n_glyphs
    a = load_outline(face, gid.to_u32, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
    b = load_outline(face, gid.to_u32,
                     LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP | LibFT::FT_LOAD_NO_HINTING)
    if !(a.nil? && b.nil?) && a != b
      hinted = true
      break
    end
    gid += sample_step
  end
  if hinted
    puts "skip (hinted — needs the hinting pipeline): #{File.basename(path)}"
    ft_face.done
    next
  end

  font_diff_pixels = 0_i64
  font_glyphs = 0
  SIZES.each do |px|
    LibFT.set_pixel_sizes(face, 0, px)
    n_glyphs.clamp(0, MAX_GLYPHS_PER_FONT).times do |gid|
      # Oracle: hinted render (identical to unhinted for this font class).
      if LibFT.load_glyph(face, gid, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_RENDER) != 0
        next
      end
      oracle = OracleBitmap.new(face.value.glyph.value)

      snap = load_outline(face, gid, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
      mine = snap ? Ftrender.render_glyph(snap.to_outline) : Ftrender::GlyphBitmap.blank

      font_glyphs += 1
      if mine.width != oracle.width || mine.height != oracle.height ||
         mine.left != oracle.left || mine.top != oracle.top
        puts "  DIMS DIFF #{File.basename(path)} gid=#{gid} px=#{px}: " \
             "ours #{mine.width}x#{mine.height}+#{mine.left}+#{mine.top} vs " \
             "ft #{oracle.width}x#{oracle.height}+#{oracle.left}+#{oracle.top}"
        font_diff_pixels += 1
        failed = true
        next
      end
      pixel_diffs = [] of {Int32, Int32, UInt8, UInt8}
      (mine.width * mine.height).times do |i|
        next if mine.buffer[i] == oracle.cov[i]
        pixel_diffs << {i % mine.width, i // mine.width, mine.buffer[i], oracle.cov[i]}
      end
      unless pixel_diffs.empty?
        font_diff_pixels += pixel_diffs.size
        if dump_budget > 0
          dump_budget -= 1
          puts "  PIXEL DIFF #{File.basename(path)} gid=#{gid} px=#{px} " \
               "(#{pixel_diffs.size} px, ours/ft):"
          pixel_diffs.first(10).each do |c, r, a, b|
            puts "    (#{c},#{r}): #{a} vs #{b}"
          end
          scale = " .:-=+*#%@"
          mine.height.times do |r|
            puts "    ours |" + String.build { |s|
              mine.width.times { |c| s << scale[{mine.buffer[r * mine.width + c] * 10 // 256, 9}.min] }
            } + "|"
          end
          oracle.height.times do |r|
            puts "    ft   |" + String.build { |s|
              oracle.width.times { |c| s << scale[{oracle.cov[r * oracle.width + c] * 10 // 256, 9}.min] }
            } + "|"
          end
          if snap
            xs, ys = snap.xs, snap.ys
            puts "    outline n=#{xs.size}: xmin=#{xs.min} xmax=#{xs.max} " \
                 "ymin=#{ys.min} ymax=#{ys.max} (26.6)"
          end
        end
      end
    end
  end

  ft_face.done
  compared_fonts += 1
  total_glyphs += font_glyphs
  total_diff_pixels += font_diff_pixels
  status = font_diff_pixels.zero? ? "OK " : "DIFF"
  puts "#{status} #{File.basename(path)}: #{font_glyphs} glyph rasterizations, " \
       "diff pixels: #{font_diff_pixels}"
  failed = true unless font_diff_pixels.zero?
end

LibFT.done_free_type(lib_ptr)

puts "\ncompared #{total_glyphs} glyph rasterizations over #{compared_fonts} " \
     "unhinted fonts; total diff pixels: #{total_diff_pixels}"
if failed || total_diff_pixels != 0
  puts "RESULT: FAIL"
  exit 1
end
puts "RESULT: PASS (pixel-exact vs system FreeType)"

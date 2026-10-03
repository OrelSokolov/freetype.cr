# MONO / LCD / LCD_V acceptance test: render every glyph through
# `Ftrender.render_glyph(outline, mode)' with mode = Mono / Lcd / LcdV
# and diff the bitmap against the system FreeType calling
# FT_Render_Glyph with FT_RENDER_MODE_MONO / _LCD / _LCD_V on the same
# hinted outline (FT_LOAD_DEFAULT). The subpixel modes assume the
# FreeType build with FT_CONFIG_OPTION_SUBPIXEL_RENDERING (what
# Debian/Ubuntu ship — the default five-tap FIR filter applies; see
# ftrender.cr). Mono bitmaps are compared packed, MSB-first, pitch for
# pitch.
#
# Run: crystal run --release spec/mono_lcd_diff.cr [-- fonts...]

require "./oracle_lib"
require "../src/tt/loader"
require "../src/ftrender"

STDOUT.flush_on_newline = true

def hinted_corpus : Array(String)
  dirs = {
    "/usr/share/fonts/truetype/dejavu",
    "/usr/share/fonts/truetype/liberation",
  }
  files = [] of String
  dirs.each do |d|
    Dir.glob("#{d}/*.ttf").sort.each { |f| files << f }
  end
  files.select { |f| File.exists?(f) }
end

CORPUS = ARGV.empty? ? hinted_corpus : ARGV
CORPUS.each do |f|
  raise "corpus font not found: #{f}" unless File.exists?(f)
end

SIZES = {13, 24}

MODES = {
  {"mono", LibFT::FT_RENDER_MODE_MONO, Ftrender::Mode::Mono},
  {"lcd", LibFT::FT_RENDER_MODE_LCD, Ftrender::Mode::Lcd},
  {"lcdv", LibFT::FT_RENDER_MODE_LCD_V, Ftrender::Mode::LcdV},
}

lib_ptr = Pointer(Void).null
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0

total = 0
fails = 0
first_failures = [] of String

CORPUS.each do |path|
  ft_face = FtFace.new(lib_ptr, path)
  face = ft_face.face
  font = TT::HintedFace.new(File.read(path).to_slice)

  font_fails = 0

  MODES.each do |mode_name, ft_mode, our_mode|
    SIZES.each do |px|
      LibFT.set_pixel_sizes(face, 0, px)
      font.set_pixel_size(px)

      face.value.num_glyphs.times do |gid|
        next if LibFT.load_glyph(face, gid,
                                 LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP) != 0
        snap = load_outline(face, gid,
                            LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
        next if snap.nil? # empty outline: nothing to render on either side

        if LibFT.render_glyph(face.value.glyph, ft_mode) != 0
          next # FreeType could not render it either
        end
        slot = face.value.glyph.value
        ob = slot.bitmap

        ours = Ftrender.render_glyph(
          Ftgrays::Outline.new(snap.not_nil!.xs, snap.not_nil!.ys,
                               snap.not_nil!.tags, snap.not_nil!.contours,
                               flags: snap.not_nil!.flags),
          our_mode)

        total += 1
        ok = ours.width == ob.width && ours.height == ob.rows &&
             ours.left == slot.bitmap_left && ours.top == slot.bitmap_top

        if ok
          if our_mode.mono?
            # packed bits, pitch for pitch
            (ob.rows * ob.pitch).times do |i|
              if ours.buffer[i] != (ob.buffer + i)[0] # be careful: same pitch
                ok = false
                break
              end
            end
          else
            # 8-bit, `width' subpixels per row, FT row stride is pitch
            ob.rows.times do |r|
              src = ob.buffer + r * ob.pitch
              ours.width.times do |c|
                if ours.buffer[r * ours.width + c] != src[c]
                  ok = false
                  break
                end
              end
              break unless ok
            end
          end
        end

        unless ok
          fails += 1
          font_fails += 1
          if first_failures.size < 12
            first_failures << "#{File.basename(path)} #{mode_name} px=#{px} gid=#{gid}: " \
                              "ours #{ours.width}x#{ours.height}+#{ours.left}+#{ours.top} " \
                              "ft #{ob.width}x#{ob.rows}+#{slot.bitmap_left}+#{slot.bitmap_top}"
          end
        end
      end
    end
  end

  ft_face.done
  status = font_fails.zero? ? "OK " : "DIFF"
  puts "#{status} #{File.basename(path)}: fails: #{font_fails}"
end

LibFT.done_free_type(lib_ptr)

puts
first_failures.each { |f| puts "  #{f}" }
puts "\nrendered #{total} glyph bitmaps; fails: #{fails}"
puts "RESULT: #{fails == 0 ? "PASS" : "FAIL"}"
exit(fails == 0 ? 0 : 1)

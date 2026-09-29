# Unhinted-outline oracle diff for the B2 loader glue (sfnt.cr + loader.cr
# scaling/composite path with the ttinterp stub in place): our
# `TT::HintedFace#load_glyph(gid, hint: false)` outline (26.6, translated
# by -pp1.x) and horizontal advance must match the system FreeType loaded
# with FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP, point for point.

require "./oracle_lib"
require "../src/tt/loader"

CORPUS = {
  "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
}

SIZES = {13, 16, 24}

lib_ptr = Pointer(Void).null
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType: #{err}" if err != 0

total = 0
fails = 0
first_failures = [] of String

CORPUS.each do |path|
  next unless File.exists?(path)
  face = FtFace.new(lib_ptr, path)
  font = TT::HintedFace.new(File.read(path).to_slice)

  SIZES.each do |px|
    LibFT.set_pixel_sizes(face.face, px, px)
    font.set_pixel_size(px)

    font.num_glyphs.times do |gid|
      snap = load_outline(face.face, gid, LibFT::FT_LOAD_NO_HINTING | LibFT::FT_LOAD_NO_BITMAP)
      g = font.load_glyph(gid, hint: false)

      total += 1
      ok = true
      if snap.nil?
        ok = g.xs.empty? && g.ys.empty?
      else
        ok = g.xs == snap.xs && g.ys == snap.ys &&
             g.tags == snap.tags && g.contours == snap.contours
      end
      # advance comparison (slot->advance.x, 26.6)
      adv = face.face.value.glyph.value.advance.x
      if adv != g.advance
        ok = false
      end
      unless ok
        fails += 1
        if first_failures.size < 10
          snap_n = snap ? snap.not_nil!.xs.size : -1
          first_failures << "#{File.basename(path)} px=#{px} gid=#{gid}: " \
                            "ours np=#{g.xs.size} ft np=#{snap_n} " \
                            "adv=#{g.advance} ft_adv=#{adv}"
        end
      end
    end
  end
  face.done
end

LibFT.done_free_type(lib_ptr)

puts "glyphs=#{total} fails=#{fails}"
first_failures.each { |f| puts "  #{f}" }
puts "RESULT: #{fails == 0 ? "PASS" : "FAIL"}"
exit(fails == 0 ? 0 : 1)

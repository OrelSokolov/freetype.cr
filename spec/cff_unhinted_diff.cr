# Unhinted-outline oracle diff for the CFF pipeline (cffload.cr +
# cffinterp.cr + face.cr): our `CFF::Face#load_glyph(gid)` outline
# (26.6, font-unit origin) and horizontal advance must match the system
# FreeType loaded with FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP and the
# CFF driver's stem darkening disabled (FT_Property_Set
# "no-stem-darkening" = TRUE) — the exact configuration the unhinted
# Adobe-engine port reproduces. Point for point, advances included.

require "./oracle_lib"
require "../src/cff/face"

def otf_corpus : Array(String)
  dirs = {
    "/usr/share/fonts/opentype/urw-base35",
    "/usr/share/fonts/opentype/urw-base35/Extra",
    "/usr/share/texmf/fonts/opentype/public/tex-gyre",
    "/usr/share/texmf/fonts/opentype/public/lm",
    "/usr/share/fonts/opentype/texgyre",
    "/usr/share/fonts/opentype/lm",
  }
  files = [] of String
  dirs.each do |d|
    Dir.glob("#{d}/*.otf").sort.each { |f| files << f }
  end
  files.select { |f| File.exists?(f) }
end

CORPUS = ARGV.empty? ? otf_corpus : ARGV
raise "corpus is empty: no OTF fonts found (or pass font paths as ARGV)" \
  if CORPUS.empty?
CORPUS.each do |f|
  raise "corpus font not found: #{f}" unless File.exists?(f)
end
SIZES = {12, 13, 16, 24, 37}

lib_ptr = Pointer(Void).null
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType: #{err}" if err != 0

# Disable stem darkening: the ported unhinted path does not apply it.
no_darkening = 1_u8
module_name = "cff\0".to_unsafe
prop_name = "no-stem-darkening\0".to_unsafe
err = LibFT.property_set(lib_ptr, module_name, prop_name,
                         pointerof(no_darkening).as(Void*))
raise "FT_Property_Set(no-stem-darkening): #{err}" if err != 0

total = 0
fails = 0
first_failures = [] of String

CORPUS.each do |path|
  face = FtFace.new(lib_ptr, path)
  font = CFF::Face.new(File.read(path).to_slice)

  SIZES.each do |px|
    LibFT.set_pixel_sizes(face.face, px, px)
    font.set_pixel_size(px)

    font.num_glyphs.times do |gid|
      snap = load_outline(face.face, gid, LibFT::FT_LOAD_NO_HINTING | LibFT::FT_LOAD_NO_BITMAP)
      g = font.load_glyph(gid)

      total += 1
      ok = true
      if snap.nil?
        ok = g.xs.empty? && g.ys.empty?
      else
        ok = g.xs == snap.xs && g.ys == snap.ys &&
             g.tags == snap.tags && g.contours == snap.contours
      end
      adv = face.face.value.glyph.value.advance.x
      ok = false if adv != g.advance
      unless ok
        fails += 1
        if first_failures.size < 12
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

puts "fonts=#{CORPUS.size} glyphs=#{total} fails=#{fails}"
first_failures.each { |f| puts "  #{f}" }
puts "RESULT: #{fails == 0 ? "PASS" : "FAIL"}"
exit(fails == 0 ? 0 : 1)

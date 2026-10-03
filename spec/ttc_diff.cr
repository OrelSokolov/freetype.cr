# TTC/OTC acceptance test: load every face of a TrueType/OpenType
# collection through `CFF::Face.new(data, face_index)' (the Noto CJK
# collections are CFF-flavoured OTFs, i.e. the Adobe hinting engine) and
# diff outlines + advances against the system FreeType opening the same
# `.ttc' with the same face index. The unhinted pass (FT_LOAD_NO_HINTING,
# hint: false) runs first; the hinted pass (FT_LOAD_DEFAULT) after.
#
# Corpus: the system Noto CJK collections; extra `.ttc' paths can be
# passed as ARGV. Skips missing files.
#
# Run: crystal run --release spec/ttc_diff.cr [-- fonts.ttc ...]

require "./oracle_lib"
require "../src/cff/face"

STDOUT.flush_on_newline = true

CORPUS = ARGV.empty? ? {
  "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
  "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
  "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
  "/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc",
} : ARGV

SIZES = {13, 24}

lib_ptr = Pointer(Void).null
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType failed: #{err}" if err != 0

total = 0
fails = 0
first_failures = [] of String

CORPUS.each do |path|
  unless File.exists?(path)
    puts "skip (missing): #{path}"
    next
  end

  # Face count straight from the ttcf header (u32 tag, u32 version,
  # u32 numFonts, then u32 offsets).
  d = File.read(path).to_slice
  num_faces = ((d[8].to_u32 << 24) | (d[9].to_u32 << 16) |
               (d[10].to_u32 << 8) | d[11]).to_i32
  puts "#{File.basename(path)}: #{num_faces} faces"

  num_faces.times do |face_index|
    ft_face = FtFace.new(lib_ptr, path, face_index)
    font = CFF::Face.new(d, face_index)

    {false, true}.each do |hinted|
      load_flags = hinted ? LibFT::FT_LOAD_DEFAULT : LibFT::FT_LOAD_NO_HINTING
      SIZES.each do |px|
        LibFT.set_pixel_sizes(ft_face.face, px, px)
        font.set_pixel_size(px)

        font.num_glyphs.times do |gid|
          snap = load_outline(ft_face.face, gid, load_flags | LibFT::FT_LOAD_NO_BITMAP)
          g = font.load_glyph(gid, hint: hinted)

          total += 1
          ok = true
          if snap.nil?
            ok = g.xs.empty? && g.ys.empty?
          else
            ok = g.xs == snap.xs && g.ys == snap.ys &&
                 g.tags == snap.tags && g.contours == snap.contours
          end
          adv = ft_face.face.value.glyph.value.advance.x
          ok = false if adv != g.advance
          unless ok
            fails += 1
            if first_failures.size < 12
              snap_n = snap ? snap.not_nil!.xs.size : -1
              first_failures << "#{File.basename(path)}##{face_index} #{hinted ? "hinted" : "unhinted"} " \
                                "px=#{px} gid=#{gid}: ours np=#{g.xs.size} ft np=#{snap_n} " \
                                "adv=#{g.advance} ft_adv=#{adv}"
            end
          end
        end
      end
    end
    ft_face.done
    puts "  face #{face_index}: #{font.num_glyphs} glyphs done"
  end
end

LibFT.done_free_type(lib_ptr)

puts
first_failures.each { |f| puts "  #{f}" }
puts "faces compared: glyphs=#{total} fails=#{fails}"
puts "RESULT: #{fails == 0 ? "PASS" : "FAIL"}"
exit(fails == 0 ? 0 : 1)

# Probe: our TT::Font cmap/ascender/kerning against the system FreeType
# (the egui integration needs all three from the Crystal side).
#
#  - glyph_index vs FT_Get_Char_Index over dense codepoint ranges
#  - ascender/descender vs FT_Face fields (sfobjs selection)
#  - kerning px vs FT_Get_Kerning(FT_KERNING_DEFAULT) at several ppem,
#    replicating the egui backend's formula (MulFix -> small-ppem MulDiv
#    -> FT_PIX_ROUND)
#
# Run: crystal run --release spec/cmap_kern_probe.cr [-- <font.ttf> ...]

require "./oracle_lib"
require "../src/tt/loader"

STDOUT.flush_on_newline = true

FONTS = {
  "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
  "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}

lib FT
  fun get_kerning = FT_Get_Kerning(face : LibFT::FaceRec*, left : UInt32, right : UInt32,
                                   kern_mode : UInt32, akerning : LibFT::Vector*) : Int32
end

paths = ARGV.empty? ? FONTS.to_a : ARGV

lib_ptr = uninitialized Void*
raise "FT_Init_FreeType failed" if LibFT.init_free_type(pointerof(lib_ptr)) != 0

total_cp_fails = 0
total_kern_fails = 0
total_metric_fails = 0

paths.each do |path|
  next puts "skip (missing): #{path}" unless File.exists?(path)

  ft_face = FtFace.new(lib_ptr, path)
  face = ft_face.face
  font = TT::Font.new(File.read(path).to_slice)

  cp_fails = 0
  cp_checked = 0
  # Dense BMP sweep + a non-BMP slice (exercises format 12 when present).
  ranges = [{0x20, 0x3000}, {0x4000, 0x5000}, {0x1_0000, 0x1_0100}]
  ranges.each do |lo, hi|
    (lo..hi).each do |cp|
      cp_checked += 1
      ft_gid = LibFT.get_char_index(face, cp.to_u32).to_i32
      my_gid = font.glyph_index(cp)
      if ft_gid != my_gid
        cp_fails += 1
        puts "  CP DIFF #{File.basename(path)} U+#{cp.to_s(16)}: ft=#{ft_gid} mine=#{my_gid}" if cp_fails <= 5
      end
    end
  end

  # Kerning: FT_KERNING_DEFAULT semantics replicated on our side.
  kern_fails = 0
  kern_checked = 0
  metric_fails = 0
  {12, 16, 24, 37}.each do |px|
    LibFT.set_pixel_sizes(face, 0, px)
    scale = TT::Fixed.divfix(px.to_i64 << 6, font.upem.to_i64)
    metric_fails += 1 if face.value.ascender != font.ascender ||
                         face.value.descender != font.descender
    n = {face.value.num_glyphs, 300}.min
    # Pairs of consecutive gids of real glyphs + the classic AV pair.
    checks = [] of {Int32, Int32}
    (0...n).each do |g|
      checks << {g, g + 1} if g + 1 < n
      checks << {g, (g + 7) % n}
    end
    checks.each do |l, r|
      kern_checked += 1
      vec = uninitialized LibFT::Vector
      FT.get_kerning(face, l.to_u32, r.to_u32, 0_u32, pointerof(vec))
      ft_px = vec.x / 64.0
      k26 = TT::Fixed.mulfix(font.kerning(l, r).to_i64, scale)
      k26 = TT::Fixed.muldiv(k26, px, 25) if px < 25
      my_px = TT::Fixed.pix_round(k26).to_f64 / 64.0
      if ft_px != my_px
        kern_fails += 1
        puts "  KERN DIFF #{File.basename(path)} px=#{px} #{l},#{r}: ft=#{ft_px} mine=#{my_px}" if kern_fails <= 5
      end
    end
  end

  status = cp_fails.zero? && kern_fails.zero? && metric_fails.zero? ? "OK " : "DIFF"
  puts "#{status} #{File.basename(path)}: cmap #{cp_fails}/#{cp_checked} diffs, " \
       "kern #{kern_fails}/#{kern_checked} diffs, asc/desc #{metric_fails} diffs"
  total_cp_fails += cp_fails
  total_kern_fails += kern_fails
  total_metric_fails += metric_fails
  ft_face.done
end

LibFT.done_free_type(lib_ptr)
ok = total_cp_fails.zero? && total_kern_fails.zero? && total_metric_fails.zero?
puts "\nRESULT: #{ok ? "PASS" : "FAIL"}"
exit(ok ? 0 : 1)

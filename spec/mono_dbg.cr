# Debug one glyph: dump our mono bitmap vs FreeType's, bit by bit.
require "./oracle_lib"
require "../src/tt/loader"
require "../src/ftrender"

path = ARGV[0]
gid = ARGV[1].to_i
px = ARGV[2].to_i

lib_ptr = Pointer(Void).null
LibFT.init_free_type(pointerof(lib_ptr))
face = FtFace.new(lib_ptr, path)
font = TT::HintedFace.new(File.read(path).to_slice)
LibFT.set_pixel_sizes(face.face, 0, px)
font.set_pixel_size(px)

LibFT.load_glyph(face.face, gid, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
snap = load_outline(face.face, gid, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP).not_nil!
LibFT.render_glyph(face.face.value.glyph, LibFT::FT_RENDER_MODE_MONO)
slot = face.face.value.glyph.value
ob = slot.bitmap

ours = Ftrender.render_glyph(
  Ftgrays::Outline.new(snap.xs, snap.ys, snap.tags, snap.contours, flags: snap.flags),
  Ftrender::Mode::Mono)

puts "ours #{ours.width}x#{ours.height}+#{ours.left}+#{ours.top} pitch=#{ours.pitch}"
puts "ft   #{ob.width}x#{ob.rows}+#{slot.bitmap_left}+#{slot.bitmap_top} pitch=#{ob.pitch} pixel_mode=#{ob.pixel_mode}"

if ENV.has_key?("M1DUMP")
  tx = -64_i64 * ours.left
  ty = 64_i64 * ours.height - 64_i64 * ours.top
  puts "#{snap.xs.size} #{snap.contours.size} #{snap.flags}"
  snap.xs.size.times do |i|
    puts "#{snap.xs[i]} #{snap.ys[i]} #{snap.tags[i]}"
  end
  snap.contours.each { |c| puts c }
  puts "#{ours.width} #{ours.height} #{tx} #{ty}"
end

def dump_row(buf, pitch, r, width)
  row = buf + r * pitch
  String.build do |s|
    width.times do |c|
      bit = (row[c >> 3] & (0x80_u8 >> (c & 7))) != 0
      s << (bit ? "#" : ".")
    end
  end
end

n = {ours.height, ob.rows}.min
n.times do |r|
  a = dump_row(ours.buffer, ours.pitch, r, ours.width)
  b = dump_row(ob.buffer, ob.pitch, r, ob.width)
  mark = a == b ? " " : "!"
  puts "#{mark} #{a} | #{b}"
end

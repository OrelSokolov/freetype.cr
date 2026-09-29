# Minimal FFI mirror debug for the oracle spec. Run:
#   crystal run --release spec/ffi_dbg.cr
require "./oracle_lib"

path = "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf"

lib_ptr = uninitialized Void*
raise "init" if LibFT.init_free_type(pointerof(lib_ptr)) != 0

data = File.read(path)
face = uninitialized LibFT::FaceRec*
err = LibFT.new_memory_face(lib_ptr, data.to_unsafe, data.bytesize, 0, pointerof(face))
puts "new_memory_face err=#{err} face=#{face.address}"
raise "face" if err != 0

f = face.value
puts "num_faces=#{f.num_faces} face_index=#{f.face_index} num_glyphs=#{f.num_glyphs} " \
     "upem=#{f.units_per_em} asc=#{f.ascender} desc=#{f.descender} " \
     "glyph=#{f.glyph.address} size=#{f.size.address}"

err = LibFT.set_pixel_sizes(face, 0, 16)
puts "set_pixel_sizes err=#{err}"

err = LibFT.load_glyph(face, 0, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
puts "load (no bitmap) err=#{err}"
ol = face.value.glyph.value.outline
puts "outline n_points=#{ol.n_points} n_contours=#{ol.n_contours} flags=#{ol.flags} " \
     "points=#{ol.points.address} tags=#{ol.tags.address} contours=#{ol.contours.address}"

err = LibFT.load_glyph(face, 36, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_RENDER)
puts "load+render err=#{err}"
slot = face.value.glyph.value
bmp = slot.bitmap
puts "bitmap w=#{bmp.width} rows=#{bmp.rows} pitch=#{bmp.pitch} " \
     "mode=#{bmp.pixel_mode} left=#{slot.bitmap_left} top=#{slot.bitmap_top} " \
     "buffer=#{bmp.buffer.address}"

LibFT.done_face(face)
LibFT.done_free_type(lib_ptr)
puts "OK"

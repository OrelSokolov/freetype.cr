# WOFF1 acceptance diff: the SFNT parser must unwrap a WOFF wrapper
# bit-compatibly — our pipeline loading a `.woff` buffer must match the
# system FreeType loading the same bytes. The WOFF wrappers are built
# here in Crystal (zlib via the stdlib) from the raw SFNT corpus, each
# table zlib-compressed when that is smaller and stored raw otherwise,
# so both branches of the unwrap code are exercised. Unhinted outline +
# advance comparison, the same as spec/tt_unhinted_diff.cr / the CFF
# counterpart; fonts given as ARGV are appended to the default corpus.

require "./oracle_lib"
require "../src/tt/loader"
require "../src/cff/face"
require "compress/zlib"
require "io/memory"

DEFAULT_CORPUS = {
  "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSerif-Italic.ttf",
  "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-MediumItalic.ttf",
  "/usr/share/fonts/opentype/urw-base35/NimbusSans-Regular.otf",
  "/usr/share/fonts/opentype/urw-base35/C059-BdIta.otf",
  "/usr/share/texmf/fonts/opentype/public/tex-gyre/texgyrebonum-bold.otf",
}

def build_woff(sfnt : Bytes) : Bytes
  raise "not an SFNT font" if sfnt.size < 12
  num_tables = ((sfnt[4] << 8) | sfnt[5]).to_i32
  entries = [] of {Bytes, Bytes, Bytes, UInt32} # tag, raw, stored, checksum
  num_tables.times do |i|
    off = 12 + 16*i
    tag = sfnt[off, 4]
    checksum = (sfnt[off+4].to_u32 << 24) | (sfnt[off+5].to_u32 << 16) |
                (sfnt[off+6].to_u32 << 8) | sfnt[off+7]
    t_off = ((sfnt[off+8].to_u32 << 24) | (sfnt[off+9].to_u32 << 16) |
             (sfnt[off+10].to_u32 << 8) | sfnt[off+11]).to_i32
    t_len = ((sfnt[off+12].to_u32 << 24) | (sfnt[off+13].to_u32 << 16) |
             (sfnt[off+14].to_u32 << 8) | sfnt[off+15]).to_i32
    raw = sfnt[t_off, t_len]
    io = IO::Memory.new
    writer = Compress::Zlib::Writer.new(io, 9)
    writer.write(raw)
    writer.close
    z = io.to_slice
    entries << {tag, raw, z.size < raw.size ? z : raw, checksum}
  end
  entries.sort_by!(&.[0])

  sfnt_size = 12 + 16*entries.size
  entries.each { |_, raw, _, _| sfnt_size += (raw.size + 3) &~ 3 }
  woff_size = 44 + 20*entries.size
  entries.each { |_, _, stored, _| woff_size += (stored.size + 3) &~ 3 }

  out = Bytes.new(woff_size, 0)
  # header: sig, flavor, length, numTables, reserved, totalSfntSize,
  # major, minor, metaOffset/Length/OrigLength, privOffset/privLength.
  out[0, 4].copy_from("wOFF".to_slice)
  out[4, 4].copy_from(sfnt[0, 4])
  out[8] = (woff_size >> 24).to_u8!
  out[9] = (woff_size >> 16).to_u8!
  out[10] = (woff_size >> 8).to_u8!
  out[11] = woff_size.to_u8!
  out[12] = (entries.size >> 8).to_u8!
  out[13] = entries.size.to_u8!
  out[16] = (sfnt_size >> 24).to_u8!
  out[17] = (sfnt_size >> 16).to_u8!
  out[18] = (sfnt_size >> 8).to_u8!
  out[19] = sfnt_size.to_u8!

  dir_off = 44
  data_off = 44 + 20*entries.size
  entries.each do |tag, raw, stored, checksum|
    out[dir_off, 4].copy_from(tag)
    4.times do |k|
      out[dir_off + 4 + k] = (data_off >> (24 - 8*k)).to_u8!
      out[dir_off + 8 + k] = (stored.size >> (24 - 8*k)).to_u8!
      out[dir_off + 12 + k] = (raw.size >> (24 - 8*k)).to_u8!
      out[dir_off + 16 + k] = (checksum >> (24 - 8*k)).to_u8!
    end
    out[data_off, stored.size].copy_from(stored)
    data_off += (stored.size + 3) &~ 3
    dir_off += 20
  end
  out
end

corpus = DEFAULT_CORPUS.select { |f| File.exists?(f) } + ARGV
corpus.each do |f|
  raise "corpus font not found: #{f}" unless File.exists?(f)
end
raise "no corpus fonts found" if corpus.empty?

SIZES = {13, 16, 24}

lib_ptr = Pointer(Void).null
err = LibFT.init_free_type(pointerof(lib_ptr))
raise "FT_Init_FreeType: #{err}" if err != 0
no_darkening = 1_u8
LibFT.property_set(lib_ptr, "cff\0".to_unsafe, "no-stem-darkening\0".to_unsafe,
                   pointerof(no_darkening).as(Void*))

total = 0
fails = 0
first_failures = [] of String

corpus.each do |path|
  woff = build_woff(File.read(path).to_slice)
  woff_path = File.tempname("freetype_cr_woff", ".woff")
  File.write(woff_path, woff)
  face = FtFace.new(lib_ptr, woff_path)
  otf = String.new(woff[4, 4]) == "OTTO"
  loader = otf ? CFF::Face.new(woff) : TT::HintedFace.new(woff)

  SIZES.each do |px|
    LibFT.set_pixel_sizes(face.face, px, px)
    loader.set_pixel_size(px)
    loader.num_glyphs.times do |gid|
      snap = load_outline(face.face, gid, LibFT::FT_LOAD_NO_HINTING | LibFT::FT_LOAD_NO_BITMAP)
      g = loader.load_glyph(gid, hint: false)
      total += 1
      ok = snap.nil? ? (g.xs.empty? && g.ys.empty?) :
            (g.xs == snap.xs && g.ys == snap.ys &&
             g.tags == snap.tags && g.contours == snap.contours)
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
  File.delete(woff_path)
end

LibFT.done_free_type(lib_ptr)

puts "fonts=#{corpus.size} glyphs=#{total} fails=#{fails}"
first_failures.each { |f| puts "  #{f}" }
puts "RESULT: #{fails == 0 ? "PASS" : "FAIL"}"
exit(fails == 0 ? 0 : 1)

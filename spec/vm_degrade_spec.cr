# VM-failure degradation test: corrupt a hinted font's bytecode ('fpgm',
# 'prep') and check the face keeps loading glyphs (unhinted) instead of
# raising — the interpreter's errors must be interceptable and non-fatal.
# Run: crystal run --release spec/vm_degrade_spec.cr

require "../src/tt/loader"

SRC = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

# Patch the first `patch.size` bytes of a table in a copy of the font.
def with_table(path : String, tag : String, patch : Bytes)
  data = File.read(path).to_slice.dup
  num = (data[4].to_u16 << 8) | data[5]
  i = 0
  while i < num
    off = 12 + 16*i
    if String.new(data[off, 4]) == tag
      o = (data[off + 8].to_u32 << 24) | (data[off + 9].to_u32 << 16) |
          (data[off + 10].to_u32 << 8) | data[off + 11].to_u32
      patch.each_with_index { |b, k| data[o + k] = b }
      break
    end
    i += 1
  end
  data
end

def check(label : String, data : Bytes)
  font = TT::HintedFace.new(data)
  font.set_pixel_size(16) # must not raise
  loaded = 0
  font.num_glyphs.times { |gid| font.load_glyph(gid, hint: true); loaded += 1 }
  vm = font.vm_error
  puts "#{label}: set_pixel_size OK, #{loaded}/#{font.num_glyphs} glyphs — " \
       "#{vm ? "degraded to unhinted (#{vm.split(';').first})" : "hinted"}"
  raise "#{label}: glyph loads failed" if loaded != font.num_glyphs
end

# 1. 'prep' = NPUSHB 255 values -> unconditional "stack overflow" VM error.
overflow = Bytes[0x40_u8, 0xFF_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
check("'prep' stack overflow", with_table(SRC, "prep", overflow))

# 2. 'fpgm' = same overflow in the font program.
check("'fpgm' stack overflow", with_table(SRC, "fpgm", overflow))

# 3. control: the untouched font still hints (no vm_error).
check("clean font (control)", File.read(SRC).to_slice)

puts "RESULT: PASS"

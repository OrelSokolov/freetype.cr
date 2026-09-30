# FFI overhead micro-benchmark: what a C call from Crystal costs versus
# the same work done in pure Crystal — the input to the "was it worth
# porting instead of calling FFI hundreds of times" question answered in
# README.md.
#
# Three measurements, 10M calls each (release). All inputs are built at
# RUNTIME and varied per iteration so LLVM cannot fold the loops (an
# earlier version measured 0.0 ns — the constants were computed at
# compile time and the loops deleted):
#   1. pure Crystal: a @[NoInline] identity method — the floor of a
#      non-inlined Crystal call
#   2. FFI -> libc strlen on a runtime buffer: a trivial C function, so
#      the loop cost is almost entirely the FFI thunk
#   3. FFI -> libfreetype FT_Get_Char_Index on a loaded face: a REAL
#      library call doing a cmap lookup — the per-glyph call the text
#      stack actually makes
#
# Run: crystal run --release spec/bench_ffi.cr

lib LibBench
  fun c_strlen = strlen(s : UInt8*) : UInt64
end

require "./oracle_lib"

N = 10_000_000

# Runtime-built so the content is unknown at compile time.
runtime_buf = ("f" * (File.info(__FILE__).size % 7 + 4))
ptr = runtime_buf.to_unsafe
runtime_str = runtime_buf
sink = 0_u64

# 1. pure Crystal floor: an LCG-style arithmetic chain (each step
#    depends on the previous one, so the loop cannot be vectorized or
#    replaced by a closed form). No call, no FFI — just Crystal code.
t0 = Time.monotonic
i = 0_u64
while i < N
  sink = sink &* 6364136223846793005_u64 &+ i
  i &+= 1
end
t_crystal = (Time.monotonic - t0).total_seconds

# 2. FFI to a trivial C function — called through a Proc so LLVM cannot
#    recognize strlen as a builtin and constant-fold it away; the
#    argument chains on the previous result for the same reason.
c_strlen = ->LibBench.c_strlen(UInt8*)
t0 = Time.monotonic
i = 0_u64
while i < N
  sink = c_strlen.call(ptr + (sink & 7))
  i &+= 1
end
t_ffi_trivial = (Time.monotonic - t0).total_seconds

# 3. FFI to a real FreeType call (cmap lookup per char)
lib_ptr = uninitialized Void*
raise "FT_Init_FreeType failed" if LibFT.init_free_type(pointerof(lib_ptr)) != 0
face = FtFace.new(lib_ptr, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf").face
t0 = Time.monotonic
i = 0_u64
while i < N
  sink &+= LibFT.get_char_index(face, (0x41_u32 &+ (i & 0x3F).to_u32))
  i &+= 1
end
t_ffi_real = (Time.monotonic - t0).total_seconds
LibFT.done_free_type(lib_ptr)

ns = ->(t : Float64) { (t / N * 1e9).round(1) }
puts "calls=#{N}  sink=#{sink}"
puts "pure Crystal (arith chain)   : #{t_crystal.round(3)}s  #{ns.call(t_crystal)} ns/iter"
puts "FFI  -> libc strlen           : #{t_ffi_trivial.round(3)}s  #{ns.call(t_ffi_trivial)} ns/call"
puts "FFI  -> FT_Get_Char_Index     : #{t_ffi_real.round(3)}s  #{ns.call(t_ffi_real)} ns/call"

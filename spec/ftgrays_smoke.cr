# Synthetic smoke test for the ftgrays port: simple outlines with
# hand-computable coverage. Run: crystal run spec/ftgrays_smoke.cr
require "../src/ftrender"

failures = 0

def trace(msg) : Nil
  STDERR.puts msg
  STDERR.flush
end

trace "test 1: square"
# 1. Axis-aligned unit square, 4x4 px, aligned to whole pixels: interior
# must be fully covered (255).
square = Ftgrays::Outline.new(
  xs: [0_i64, 256_i64, 256_i64, 0_i64], # 26.6: 4px = 256
  ys: [0_i64, 0_i64, 256_i64, 256_i64],
  tags: [1_u8, 1_u8, 1_u8, 1_u8],
  contours: [3]
)
bmp = Ftrender.render_glyph(square)
if bmp.width != 4 || bmp.height != 4 || bmp.left != 0 || bmp.top != 4
  puts "FAIL square dims: #{bmp.width}x#{bmp.height} left=#{bmp.left} top=#{bmp.top}"
  failures += 1
elsif bmp.buffer.any? { |v| v != 255 }
  puts "FAIL square coverage: not all 255"
  failures += 1
else
  puts "OK square 4x4 fully covered"
end

trace "test 2: triangle"
# 2. Right triangle, 16px legs on pixel edges: (0,0)-(16,0)-(0,16), y up.
# Bottom-left pixel is fully inside (255), top-right is fully outside
# (0), bottom-right is cut exactly by the hypotenuse (~half).
tri = Ftgrays::Outline.new(
  xs: [0_i64, 1024_i64, 0_i64],
  ys: [0_i64, 0_i64, 1024_i64],
  tags: [1_u8, 1_u8, 1_u8],
  contours: [2]
)
bmp = Ftrender.render_glyph(tri)
bl = bmp.buffer[15 * 16]        # bottom-left
tr = bmp.buffer[15]             # top-right
br = bmp.buffer[15 * 16 + 15]   # bottom-right, on the hypotenuse
if bmp.width != 16 || bmp.height != 16
  puts "FAIL triangle dims: #{bmp.width}x#{bmp.height}"
  failures += 1
elsif bl != 255 || tr != 0 || br <= 0 || br >= 255
  puts "FAIL triangle coverage: bl=#{bl} tr=#{tr} br=#{br}"
  failures += 1
else
  puts "OK triangle 16x16 (bl=#{bl} tr=#{tr} br=#{br})"
end

trace "test 3: circle"
# 3. A circle built from 4 conics (TTF-style): symmetric coverage, solid
# center. r = 6px, center at 8px; bbox = 12x12 (control points stay
# inside the on-point extremes).
cx = 512_i64
cy = 512_i64
r = 384_i64
k = (r * 55225 // 100000).to_i64 # conic kappa, 26.6
circle = Ftgrays::Outline.new(
  xs: [cx + r, cx + k, cx, cx - k, cx - r, cx - k, cx, cx + k],
  ys: [cy, cy + k, cy + r, cy + k, cy, cy - k, cy - r, cy - k],
  tags: [1, 0, 1, 0, 1, 0, 1, 0].map(&.to_u8!),
  contours: [7]
)
bmp = Ftrender.render_glyph(circle)
if bmp.width != 12 || bmp.height != 12
  puts "FAIL circle dims: #{bmp.width}x#{bmp.height}"
  failures += 1
elsif bmp.buffer[6 * 12 + 5] != 255 || bmp.buffer[6 * 12 + 6] != 255
  puts "FAIL circle: center not solid (#{bmp.buffer[6 * 12 + 5]}, #{bmp.buffer[6 * 12 + 6]})"
  failures += 1
else
  # Quasi-symmetry only: the integer conic DDA rounds per direction, so
  # the exact coverage is not mirror-symmetric — neither in FreeType
  # itself (verified byte-identical against the standalone C ftgrays).
  col = Array.new(12) { |c| bmp.height.times.sum { |r| bmp.buffer[r * 12 + c].to_i32 } }
  row = Array.new(12) { |r| bmp.width.times.sum { |c| bmp.buffer[r * 12 + c].to_i32 } }
  asym = (0...12).sum { |i| (col[i] - col[11 - i]).abs + (row[i] - row[11 - i]).abs }
  if asym <= 40
    puts "OK circle 12x12 quasi-symmetric (asym=#{asym})"
  else
    puts "FAIL circle: asymmetric coverage (asym=#{asym})"
    failures += 1
  end
end

trace "test 4: cubic"
# 4. Cubic Bézier outline (CFF-style) renders with the right bbox.
cubic = Ftgrays::Outline.new(
  xs: [0_i64, 0_i64, 1024_i64, 1024_i64, 1024_i64, 0_i64, 0_i64],
  ys: [0_i64, 768_i64, 768_i64, 768_i64, 0_i64, 0_i64, 0_i64],
  tags: [1, 2, 2, 1, 2, 2, 1].map(&.to_u8!),
  contours: [6]
)
bmp = Ftrender.render_glyph(cubic)
if bmp.width != 16 || bmp.height != 12
  puts "FAIL cubic dims: #{bmp.width}x#{bmp.height}"
  failures += 1
elsif bmp.buffer[6 * 16 + 8] == 0
  puts "FAIL cubic: interior empty"
  failures += 1
else
  puts "OK cubic 16x12"
end

trace "test 5: even-odd"
# 5. Even-odd fill of two nested squares: the ring is covered, the hole
# is not.
eo = Ftgrays::Outline.new(
  xs: [0_i64, 1024_i64, 1024_i64, 0_i64, 256_i64, 768_i64, 768_i64, 256_i64],
  ys: [0_i64, 0_i64, 1024_i64, 1024_i64, 256_i64, 256_i64, 768_i64, 768_i64],
  tags: [1_u8] * 8,
  contours: [3, 7],
  flags: Ftgrays::FT_OUTLINE_EVEN_ODD_FILL
)
bmp = Ftrender.render_glyph(eo)
hole = 4.upto(11).all? do |r|
  4.upto(11).all? { |c| bmp.buffer[r * 16 + c] == 0 }
end
ring = { {2, 2}, {8, 1}, {13, 13} }.all? do |(r, c)|
  bmp.buffer[r * 16 + c] > 0
end
if hole && ring
  puts "OK even-odd ring/hole"
else
  puts "FAIL even-odd: hole=#{hole} ring=#{ring}"
  failures += 1
end

if failures.zero?
  puts "\nSMOKE PASS"
else
  puts "\nSMOKE FAIL (#{failures})"
  exit 1
end

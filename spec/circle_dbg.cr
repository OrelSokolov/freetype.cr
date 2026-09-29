# Compare the synthetic smoke-test circle between the Crystal port and
# the standalone C ftgrays oracle (tmp_c/c_oracle). Run:
#   crystal run spec/circle_dbg.cr
require "../src/ftrender"

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
File.write("tmp_c/circle_ours.bin", bmp.buffer)

x_min = circle.xs.min
x_max = circle.xs.max
y_min = circle.ys.min
y_max = circle.ys.max
px_min = x_min >> 6
px_max = (x_max >> 6) + (((x_max & 63) + 63) >> 6)
py_min = y_min >> 6
py_max = (y_max >> 6) + (((y_max & 63) + 63) >> 6)
w = (px_max - px_min).to_i
h = (py_max - py_min).to_i
tx = -64_i64 &* px_min
ty = 64_i64 &* h &- 64_i64 &* py_max
File.write("tmp_c/circle_outline.txt", String.build { |s|
  s << "#{w} #{h} #{tx} #{ty} #{circle.xs.size} 1\n"
  circle.xs.size.times { |i| s << "#{circle.xs[i]} #{circle.ys[i]} #{circle.tags[i] & 3}\n" }
  s << "7\n"
})
puts "#{w}x#{h} left=#{px_min} top=#{py_max}"

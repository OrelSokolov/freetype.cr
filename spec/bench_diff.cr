# Debug helper for bench_render: per-item C-vs-Crystal comparison over the
# same workload, printing the first mismatches with details.
# Run: crystal run --release spec/bench_diff.cr -- [n]

require "./oracle_lib"
require "../src/tt/loader"
require "../src/ftrender"

STDOUT.flush_on_newline = true

N = (ARGV[0]? || "20000").to_i
FONTS = {
  "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
  "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}
SIZES = {12, 16, 24, 37}

fonts = FONTS.to_a.select { |p| File.exists?(p) }
datas = fonts.map { |p| File.read(p) } # outlives the faces (GC)
faces = datas.map { |d| TT::HintedFace.new(d.to_slice) }
n_glyphs = faces.map(&.num_glyphs)

lib_ptr = uninitialized Void*
raise "init" if LibFT.init_free_type(pointerof(lib_ptr)) != 0
ft_wrappers = fonts.map { |p| FtFace.new(lib_ptr, p) }
ft_faces = ft_wrappers.map(&.face)

shown = 0
cur_c = {-1, -1}
cur_x = {-1, -1}
N.times do |i|
  f = i % fonts.size
  px = SIZES[(i // 7) % SIZES.size]
  gid = i % n_glyphs[f]
  if cur_c != {f, px}
    LibFT.set_pixel_sizes(ft_faces[f], 0, px)
    cur_c = {f, px}
  end
  if cur_x != {f, px}
    faces[f].set_pixel_size(px)
    cur_x = {f, px}
  end

  ec = LibFT.load_glyph(ft_faces[f], gid.to_u32, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_RENDER)
  slot = ft_faces[f].value.glyph.value
  if ec != 0
    puts "FT ERR i=#{i} ec=#{ec}" if shown < 10 && false # keep count of these only if bitmap-level diff shows
  end
  ob = OracleBitmap.new(slot)

  g = faces[f].load_glyph(gid, hint: true)
  if g.xs.empty? || g.contours.empty?
    mw = mh = ml = mt = 0
    buf = Bytes.new(0)
  else
    bmp = Ftrender.render_glyph(Ftgrays::Outline.new(g.xs, g.ys, g.tags, g.contours))
    mw, mh, ml, mt = bmp.width, bmp.height, bmp.left, bmp.top
    buf = bmp.buffer
  end

  next if mw == ob.width && mh == ob.height && ml == ob.left && mt == ob.top &&
          g.advance == slot.advance.x && buf == ob.cov[0, mw * mh]
  next if shown >= 10
  shown += 1
  np = buf.size == ob.cov.size ? (0...buf.size).count { |k| buf[k] != ob.cov[k] } : -1
  puts "#{File.basename(fonts[f])} px=#{px} gid=#{gid} (i=#{i}) ec=#{ec}: " \
       "mine=#{mw}x#{mh}+#{ml}+#{mt} adv=#{g.advance} ft=#{ob.width}x#{ob.height}+#{ob.left}+#{ob.top} adv=#{slot.advance.x} pixdiff=#{np}"
end
puts shown.zero? ? "no diffs in #{N}" : "#{shown}+ diffs"
LibFT.done_free_type(lib_ptr)

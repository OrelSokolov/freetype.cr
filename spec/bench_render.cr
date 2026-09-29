# Render benchmark: C FreeType (FT_Load_Glyph|FT_LOAD_RENDER through FFI)
# vs the Crystal port (TT::HintedFace#load_glyph + Ftrender), 100 000
# glyphs total in batches (default 1000/batch). The workload is a fixed
# deterministic sequence over the hinted corpus and a few ppem values;
# both sides checksum every glyph (dims + advance + coverage bytes) so
# the run doubles as an equality check over the whole benchmark.
#
# Run:  crystal run --release spec/bench_render.cr -- [total] [batch]
#   e.g. crystal run --release spec/bench_render.cr -- 100000 1000

require "./oracle_lib"
require "../src/tt/loader"
require "../src/ftrender"

STDOUT.flush_on_newline = true

TOTAL = (ARGV[0]? || "100000").to_i
BATCH = (ARGV[1]? || "1000").to_i

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

fonts = FONTS.to_a.map { |p| File.exists?(p) ? p : nil }.compact
datas = fonts.map { |p| File.read(p) } # outlives the faces (GC)
faces = datas.map { |d| TT::HintedFace.new(d.to_slice) }
n_glyphs = faces.map(&.num_glyphs)

# Deterministic workload, batch-major: one batch = one font at one size
# (a realistic bake — the UI renders runs of glyphs per font/size), gids
# sequential from a per-batch offset. Batches cycle fonts round-robin
# and step through the sizes every full round.
items = Array({Int32, Int32, Int32}).new(TOTAL)
n_batches = (TOTAL + BATCH - 1) // BATCH
gid_base = 0
n_batches.times do |b|
  f = b % fonts.size
  px = SIZES[(b // fonts.size) % SIZES.size]
  count = {BATCH, TOTAL - items.size}.min
  count.times do
    items << {f, px, gid_base}
    gid_base += 1
  end
end

lib_ptr = uninitialized Void*
raise "FT_Init_FreeType failed" if LibFT.init_free_type(pointerof(lib_ptr)) != 0
ft_wrappers = fonts.map { |p| FtFace.new(lib_ptr, p) }
ft_faces = ft_wrappers.map(&.face)

# FNV-1a over the glyph result: dims, placement, advance, coverage.
struct Sum
  property h : UInt64 = 0x811c_9dc5_u64

  def mix(v : Int) : Nil
    @h = (@h ^ (v & 0xFF)) &* 0x0100_0000_01b3
  end

  def bytes(b : Bytes) : Nil
    b.each { |v| @h = (@h ^ v) &* 0x0100_0000_01b3 }
  end
end

# --- C reference ----------------------------------------------------------

def run_c(items, batch, faces, ft_faces, n_glyphs) : UInt64
  sum = Sum.new
  cur_size = {-1, -1}
  items.each_slice(batch) do |slice|
    slice.each do |f, px, i|
      if cur_size != {f, px}
        LibFT.set_pixel_sizes(ft_faces[f], 0, px)
        cur_size = {f, px}
      end
      gid = i % n_glyphs[f]
      if LibFT.load_glyph(ft_faces[f], gid.to_u32,
                          LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_RENDER) != 0
        sum.mix(-1)
        next
      end
      slot = ft_faces[f].value.glyph.value
      bmp = slot.bitmap
      sum.mix(bmp.width); sum.mix(bmp.rows)
      sum.mix(slot.bitmap_left); sum.mix(slot.bitmap_top)
      sum.mix(slot.advance.x)
      w = bmp.width
      bmp.rows.times do |r|
        row = bmp.buffer + r * bmp.pitch
        w.times { |c| sum.mix(row[c]) }
      end
    end
  end
  sum.h
end

# --- Crystal port ---------------------------------------------------------

def run_crystal(items, batch, faces, n_glyphs) : UInt64
  sum = Sum.new
  cur_size = {-1, -1}
  items.each_slice(batch) do |slice|
    slice.each do |f, px, i|
      if cur_size != {f, px}
        faces[f].set_pixel_size(px)
        cur_size = {f, px}
      end
      gid = i % n_glyphs[f]
      begin
        g = faces[f].load_glyph(gid, hint: true)
      rescue TT::ParseError | TT::ExecutionError
        sum.mix(-1)
        next
      end
      if g.xs.empty? || g.contours.empty?
        sum.mix(0); sum.mix(0)
        sum.mix(0); sum.mix(0)
        sum.mix(g.advance)
        next
      end
      outline = Ftgrays::Outline.new(g.xs, g.ys, g.tags, g.contours)
      bmp = Ftrender.render_glyph(outline)
      sum.mix(bmp.width); sum.mix(bmp.height)
      sum.mix(bmp.left); sum.mix(bmp.top)
      sum.mix(g.advance)
      sum.bytes(bmp.buffer)
    end
  end
  sum.h
end

# --- warmup + timed runs ---------------------------------------------------

warm = items[0, {BATCH * 2, TOTAL}.min]
run_c(warm, BATCH, faces, ft_faces, n_glyphs)
run_crystal(warm, BATCH, faces, n_glyphs)

only = ENV["ONLY"]? # "c" / "x": profile one side (perf)

t0 = Time.monotonic
sum_c = only == "x" ? 0_u64 : run_c(items, BATCH, faces, ft_faces, n_glyphs)
t_c = Time.monotonic - t0

t0 = Time.monotonic
sum_x = only == "c" ? 0_u64 : run_crystal(items, BATCH, faces, n_glyphs)
t_x = Time.monotonic - t0

puts "glyphs=#{TOTAL} batch=#{BATCH} fonts=#{fonts.size}"
if only == "x"
  puts "Crystal    : #{t_x.total_seconds.round(3)}s  #{"%.0f" % (TOTAL / t_x.total_seconds)} glyphs/s  (checksum #{sum_x.to_s(16)})"
  exit(sum_x.zero? ? 1 : 0)
end
if only == "c"
  puts "C FreeType : #{t_c.total_seconds.round(3)}s  #{"%.0f" % (TOTAL / t_c.total_seconds)} glyphs/s  (checksum #{sum_c.to_s(16)})"
  exit(sum_c.zero? ? 1 : 0)
end
puts "C FreeType : #{t_c.total_seconds.round(3)}s  #{"%.0f" % (TOTAL / t_c.total_seconds)} glyphs/s  (checksum #{sum_c.to_s(16)})"
puts "Crystal    : #{t_x.total_seconds.round(3)}s  #{"%.0f" % (TOTAL / t_x.total_seconds)} glyphs/s  (checksum #{sum_x.to_s(16)})"
puts "ratio      : #{"%.2f" % (t_x.total_seconds / t_c.total_seconds)}x slower"

if sum_c == sum_x
  puts "RESULT: PASS (identical output over #{TOTAL} renders)"
else
  puts "RESULT: FAIL (checksums differ!)"
  exit 1
end

ft_faces.each { |f| LibFT.done_face(f) }
LibFT.done_free_type(lib_ptr)

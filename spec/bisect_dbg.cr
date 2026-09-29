# Bisect a mismatching glyph through three rasterizers:
#   1. ours  — Ftgrays/Ftrender (Crystal)
#   2. c     — the standalone ftgrays.c oracle (tmp_c/c_oracle), fed the
#              identical outline + bitmap geometry
#   3. ft    — the system FreeType (FT_LOAD_RENDER)
# Run: crystal run --release spec/bisect_dbg.cr [font px gid]
require "./oracle_lib"

path = ARGV[0]? || "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf"
px = (ARGV[1]? || "12").to_i
gid = (ARGV[2]? || "13").to_u32

lib_ptr = uninitialized Void*
raise "init" if LibFT.init_free_type(pointerof(lib_ptr)) != 0
data = File.read(path)
face = uninitialized LibFT::FaceRec*
raise "face" if LibFT.new_memory_face(lib_ptr, data.to_unsafe, data.bytesize, 0,
                                      pointerof(face)) != 0
LibFT.set_pixel_sizes(face, 0, px)

# 3. system FreeType oracle
raise "render" if LibFT.load_glyph(face, gid, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_RENDER) != 0
oracle = OracleBitmap.new(face.value.glyph.value)

# outline snapshot
snap = load_outline(face, gid, LibFT::FT_LOAD_DEFAULT | LibFT::FT_LOAD_NO_BITMAP)
raise "no outline" unless snap

# 1. ours
Ftgrays::Raster.lines_log = [] of String
Ftgrays::Raster.conic_log = [] of String
mine = Ftrender.render_glyph(snap.to_outline)
File.write("tmp_c/lines_crystal.txt", Ftgrays::Raster.lines_log.not_nil!.join("\n") + "\n")
File.write("tmp_c/conics_crystal.txt", Ftgrays::Raster.conic_log.not_nil!.join("\n") + "\n")
Ftgrays::Raster.lines_log = nil
Ftgrays::Raster.conic_log = nil

# bitmap geometry (same math as Ftrender, for feeding the C oracle)
x_min = snap.xs.min
x_max = snap.xs.max
y_min = snap.ys.min
y_max = snap.ys.max
px_min = x_min >> 6
px_max = (x_max >> 6) + (((x_max & 63) + 63) >> 6)
py_min = y_min >> 6
py_max = (y_max >> 6) + (((y_max & 63) + 63) >> 6)
width = (px_max - px_min).to_i
height = (py_max - py_min).to_i
left = px_min.to_i
top = py_max.to_i
x_shift = -64_i64 &* left
y_shift = 64_i64 &* height &- 64_i64 &* top

puts "glyph gid=#{gid} px=#{px}: ft #{oracle.width}x#{oracle.height}+#{oracle.left}+#{oracle.top}, " \
     "ours #{mine.width}x#{mine.height}+#{mine.left}+#{mine.top}, " \
     "preset #{width}x#{height}+#{left}+#{top}"

# 2. C standalone oracle (same outline, same geometry + shifts)
input = String.build do |s|
  s << "#{width} #{height} #{x_shift} #{y_shift} " \
       "#{snap.xs.size} #{snap.contours.size}\n"
  snap.xs.size.times do |i|
    s << "#{snap.xs[i]} #{snap.ys[i]} #{snap.tags[i] & 3}\n"
  end
  snap.contours.each { |c| s << c << '\n' }
end
File.write("tmp_c/outline.txt", input)
cout = IO::Memory.new
cerr = IO::Memory.new
env = {"FT_LINES" => "1"}
status = Process.run("./tmp_c/c_oracle", input: IO::Memory.new(input), output: cout,
                     error: cerr, env: env)
File.write("tmp_c/lines_c.txt", cerr.to_s)
raise "c_oracle failed: #{status}" unless status.success?
cbuf = cout.to_slice

def diff_rows(a : Bytes, b : Bytes, w : Int32, h : Int32, la : String, lb : String)
  n = 0
  h.times do |r|
    w.times do |c|
      next if a[r * w + c] == b[r * w + c]
      n += 1
      puts "  (#{c},#{r}): #{la}=#{a[r * w + c]} #{lb}=#{b[r * w + c]}" if n <= 12
    end
  end
  puts "  #{la} vs #{lb}: #{n} diff pixels"
  n
end

w = oracle.width
h = oracle.height
puts "diffs:"
diff_rows(cbuf, oracle.cov, w, h, "c", "ft")
diff_rows(mine.buffer, oracle.cov, w, h, "ours", "ft")
diff_rows(mine.buffer, cbuf, w, h, "ours", "c")

LibFT.done_face(face)
LibFT.done_free_type(lib_ptr)

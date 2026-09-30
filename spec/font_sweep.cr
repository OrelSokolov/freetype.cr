# Sweep every system font through the hinted pipeline (fpgm/prep + every
# glyph at several sizes) and report crashes vs clean skips.
# Run: crystal run --release spec/font_sweep.cr

require "../src/tt/loader"

roots = {"/usr/share/fonts", "/usr/local/share/fonts", "#{ENV["HOME"]}/.local/share/fonts"}
paths = roots.flat_map { |r| Dir.glob("#{r}/**/*.{ttf,otf,ttc}") }.uniq.sort

SIZES = {12, 16, 24}
ok = 0
crashed = 0
skipped = 0
failures = [] of String
# SWEEP_TSV=<file>: also write "path<TAB>status" per font (see the
# Tested-on-fonts summary generated from a run).
tsv = ENV["SWEEP_TSV"]?.try { |p| File.new(p, "w") }

paths.each do |path|
  if path.ends_with?(".ttc")
    skipped += 1
    tsv.try &.puts("#{path}\tskip-ttc")
    next
  end

  begin
    font = TT::HintedFace.new(File.read(path).to_slice)
    glyphs = 0
    SIZES.each do |px|
      font.set_pixel_size(px)
      font.num_glyphs.times do |gid|
        font.load_glyph(gid, hint: true)
        glyphs += 1
      end
    end
    ok += 1
    tsv.try &.puts("#{path}\tclean\t#{glyphs / SIZES.size}")
  rescue ex : TT::ParseError
    skipped += 1
    failures << "SKIP #{File.basename(path)}: #{ex.class}: #{ex.message}"
    tsv.try &.puts("#{path}\tskip\t#{ex.message}")
  rescue ex
    crashed += 1
    failures << "CRASH #{File.basename(path)}: #{ex.class}: #{ex.message}"
    tsv.try &.puts("#{path}\tcrash\t#{ex.class}: #{ex.message}")
  end
end
tsv.try &.close

puts "fonts total: #{paths.size}, clean: #{ok}, skipped (unsupported): #{skipped}, crashed: #{crashed}"
failures.each { |f| puts "  #{f}" }
exit(crashed.zero? ? 0 : 1)

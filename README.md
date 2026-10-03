# freetype.cr — TrueType & CFF glyph pipeline in pure Crystal

<p align="center">
  <img src="docs/logo.png" alt="freetype.cr logo" width="418">
</p>

*The logo above was rendered by this library itself — hinted glyph
rasterization + PNG packing, no FreeType, no FFI (`spec/gen_logo.cr`).*

A self-contained Crystal port of FreeType's font pipeline: the
`ftgrays.c` anti-aliasing rasterizer, the `ttinterp.c` bytecode-hinting
VM, the SFNT loading glue and the CFF (Type 2 charstring) glyph loader
(ported from the FreeType 2.14.3 master snapshot). No dependency on
libfreetype — or on any other part of FreeType. Given a TTF/OTF and a
pixel size, it produces hinted or unhinted glyph bitmaps
**pixel-for-pixel identical** to what the system libfreetype would
render.

## Why

- **Drop the native dependency.** No `libfreetype.so` / `freetype.dll` to
  ship (the Windows DLL distribution problem disappears entirely).
- **Full control over the pipeline.** Loading, hinting and rasterization
  are ordinary Crystal code you can step through, instrument and embed.
- **Correct hinting without the library.** TrueType hinting is bytecode
  (`fpgm`, `prep`, per-glyph instructions) that moves outline points;
  there is no heuristic that approximates it. This port executes it.

## Components

- `src/ftgrays.cr` — the rasterizer core: `Ftgrays::Raster` +
  `Ftgrays::Outline` (26.6 coordinates, y up). A port of
  `gray_render_line` (64-bit variant), conics via DDA
  (`gray_render_conic`), cubics via bisection (`gray_render_cubic`),
  coverage cells and the sweep with fill rules. Bit-level fidelity is
  carried over explicitly: wrapping arithmetic (`&+ &- &*`), arithmetic
  shifts, C-style truncated division `tdiv`, an exact replica of
  `FT_UDIV`. The cell pool / band bisection is replaced with dynamic
  arrays (area integration is independent of the band split).
- `src/ftrender.cr` — the `ftsmooth.c`/`ftobjs.c` glue for
  FT_RENDER_MODE_NORMAL: control box → pixel bbox (floor/ceil as in
  `ft_glyphslot_preset_bitmap`) → translation → rasterization. The
  result is an `Ftrender::GlyphBitmap` (top-down 8-bit coverage).
- `src/fttrigon.cr` — a port of `fttrigon.c` (fixed-point trigonometry:
  `FT_Vector_Rotate`, `FT_Vector_Norm_Len`, etc. — needed for
  projections onto arbitrary axes in the bytecode).
- `src/tt/sfnt.cr` — a minimal SFNT parser: head, maxp, hhea, hmtx,
  cmap (formats 4 and 12), loca, glyf, cvt, fpgm, prep, gasp, kern.
  Only what loading outlines and hinting need. WOFF1 wrappers are
  unwrapped into a plain SFNT before parsing (the `woff_open_font'
  approach, zlib via the Crystal stdlib) — `TT::Font`/`CFF::Face`
  accept `.woff` buffers directly; WOFF2 (brotli) is out of scope.
- `src/tt/loader.cr` — a port of the hint glue from `ttgload.c`/
  `ttobjs.c`: scaling, `exec.run_fpgm`/`run_prep` (CVT in 26.6, as in
  C), `backward_compatibility`, simple and composite glyph loading,
  grid-fit advance (`ft_glyphslot_grid_fit_metrics`), point write-back,
  the scan-conversion flag in tags[0].
- `src/tt/ttinterp.cr` (~4 600 lines) — a port of the `ttinterp.c` VM:
  stack, zones/points, CVT, storage, functions, ~190 opcodes;
  wrapping arithmetic (`&+ &- &*`), C semantics for division and shifts.
  A tracer is built in (`TT_TRACE=1` — per-instruction VM dump, zero
  cost when the flag is off).
- `src/cff/cffload.cr` — the CFF table parser: a port of `cffload.c`
  (header, INDEX structures, charset — needed for seac, FDSelect +
  FDArray, the font-matrix reconciliation from `cffobjs.c`) and the
  DICT operand decoding of `cffparse.c` (integers, 16.16 fixed,
  binary-coded decimal reals verbatim).
- `src/cff/cffinterp.cr` — the Type 2 charstring interpreter: a port of
  `psintrp.c` cf2_interpT2CharString (typed int/fixed operand stack,
  width parsing, path/arithmetic operators, flex, seac via endchar, the
  xorshift `random`) specialized to the unhinted no-stem-darkening
  mode, plus the unhinted cf2_glyphpath from `pshints.c` and the
  ps_builder outline callbacks from `psobjs.c`. 32-bit wrapping
  arithmetic is carried over explicitly. A tracer is built in
  (`CFF_TRACE=1`, the TT_TRACE counterpart).
- `src/cff/face.cr` — the CFF-flavoured OTF face: a port of
  `cff_slot_load` (cffgload.c) — advance from `hmtx`, FontMatrix →
  translate → FT_MulFix scale in the cffgload.c order — reusing the
  SFNT glue (cmap/hmtx) from `src/tt/sfnt.cr`. Returns the same
  `TT::LoadedGlyph` as the TrueType loader.

Note: FreeType hands fonts without bytecode (empty `fpgm`, `prep` ≤ 7
bytes) to the auto-hinter (ftobjs.c:1016-1020) — so unhinted corpora
(e.g. Roboto) are covered by a separate unhinted acceptance run rather
than the hinted one.

## Usage

```crystal
require "freetype-cr"

face = TT::HintedFace.new(File.read("DejaVuSans.ttf").to_slice)
face.set_pixel_size(16)

gid = face.font.glyph_index('A'.ord)
g = face.load_glyph(gid)                    # hinted 26.6 outline + advance
bmp = Ftrender.render_glyph(
  Ftgrays::Outline.new(g.xs, g.ys, g.tags, g.contours))
# bmp.width/height/left/top + bmp.buffer (8-bit coverage, top-down)
```

`load_glyph(gid, hint: false)` gives the FT_LOAD_NO_HINTING path;
advances come back in 26.6 fixed point alongside the outline.

CFF (OTF) fonts go through the same API:

```crystal
require "freetype-cr"

face = CFF::Face.new(File.read("NimbusSans-Regular.otf").to_slice)
face.set_pixel_size(16)

gid = face.font.glyph_index('A'.ord)
g = face.load_glyph(gid)                 # unhinted 26.6 outline + advance
bmp = Ftrender.render_glyph(
  Ftgrays::Outline.new(g.xs, g.ys, g.tags, g.contours))
```

`CFF::Face#load_glyph` returns the same `TT::LoadedGlyph` structure and
renders through the same `Ftrender` as the TrueType path.

## Accuracy

Verified with an oracle-diff against the system libfreetype (FFI in the
specs; the library itself never calls it):

- **Unhinted:** 32 000 glyph rasterizations across 16 unhinted fonts
  (every Roboto weight/style, Noto Sans/Serif/Mono; sizes 12/13/16/24/37)
  — **0-pixel diff**, including bitmap dimensions and offsets. Synthetic
  smoke tests: 5/5.
- **Hinted (full pipeline — TTF → outline → hinting → rasterization,
  entirely in Crystal):** **198 790 hinted glyphs** (Liberation, DejaVu,
  Verdana, Times and others; 12/13/16/24/37 px) — **0 diff** on
  outlines + bitmaps + advances, plus 80 997 unhinted glyphs — 0 diff.
  Two "version-sensitive" glyphs are registered (LiberationMono, 12/13
  px) where the system libfreetype 2.13.3 disagrees with the FT master
  snapshot; this port matches the master (checked against a local
  build).
- **CFF (OTF), unhinted:** **632 875 glyphs** across **140 OTF fonts**
  (URW base35 + Extra, TeX Gyre, Latin Modern; 12/13/16/24/37 px) —
  **0 diff** on outlines + advances against the system libfreetype with
  FT_LOAD_NO_HINTING and `no-stem-darkening=TRUE` (the property is set
  through FFI in the spec; the library itself assumes darkening is
  off). A render smoke test (3 fonts × 16/24 px, full load → rasterize
  → bitmap compare) is also 0-diff. The CID path (FDArray/FDSelect) is
  verified on Noto Sans CJK JP (18 subfonts, every one in use):
  327 675 glyphs, 0 diff.
- **WOFF1:** 222 942 glyphs across 6 fonts (Liberation TTF, Roboto TTF,
  three OTFs and the CID Noto above, all re-wrapped as WOFF1 with
  zlib-compressed tables) — **0 diff** against the system libfreetype
  loading the same `.woff` files.

### CFF limitations (honest)

- **Hinting and stem darkening are not ported.** The Adobe engine
  (`pshints.c`/`psblues.c`, ~4.5k lines of psaux) is not implemented:
  glyphs always load unhinted, without darkening. Note that stock
  libfreetype applies stem darkening even under FT_LOAD_NO_HINTING —
  matching its default output would require that engine (a possible
  stage B).
- Bare CFF (`.cff` files with their own encoding/charset charmaps),
  CFF2 and WOFF2 wrappers are not parsed — only CFF1 in an SFNT/OTF
  and WOFF1 (which is unwrapped to SFNT transparently).
- CID (FDArray/FDSelect) is implemented and oracle-verified on
  Noto Sans CJK JP; other CID fonts passed through the same code path,
  but that is the only CID font in the acceptance corpus.
- The `random` operator seed is deterministic (FT's
  InitialRandomSeed); FreeType derives the default seed from a memory
  address, so glyphs using `random` may differ in the low bits of
  perturbed coordinates.

## Performance: pure Crystal vs C through FFI

**Bottom line: the port is ~1.8x slower than the "Crystal calls
libfreetype via FFI" path** (~115k vs ~205k glyphs/s, machine variance
±5%). Both numbers are measured from Crystal, so the comparison is
fair: the C side of the benchmark is the real FFI path of a text stack.

```
crystal run --release spec/bench_render.cr -- 100000 1000
```

renders 100 000 glyphs in batches of 1000 (batch = one font at one
size; the DejaVu/Liberation/Noto corpus, ppem 12/16/24/37), both sides
with a per-pixel checksum of the output. `ONLY=c`/`ONLY=x` runs one
side; `spec/bench_diff.cr` is a per-glyph debug diff of the same
workload.

### Was porting worth it "to avoid hundreds of FFI calls"?

The FFI transition itself was measured (`spec/bench_ffi.cr`, 10M calls,
release). NB: the rows below measure DIFFERENT things and are not a
"Crystal vs C" comparison — the first is the cost of executing code
with no call at all (the floor), the second and third are the cost of
CALLING C from Crystal:

| what is measured | ns |
|---|---|
| executed Crystal code: two arithmetic ops, no call at all | ~0.9 |
| trivial C function call (strlen, ~0.5 ns of work) via FFI | ~3.6 |
| real FT_Get_Char_Index call (cmap lookup) via FFI | ~9 |

How to read it: the FFI toll itself is **~3 ns on top of a native
call** (3.6 − strlen's work). Baking one glyph costs 4 700–8 500 ns and
makes 1–3 FFI calls (load, optionally kerning/metrics) — so FFI
overhead is **<0.5 %** of a glyph bake. Saving on FFI calls is NOT by
itself a reason for the port — it is negligible when baking into an
atlas. The real wins are removing the external
`libfreetype.so`/`.dll` dependency and full control of the pipeline;
the price is 1.8x in speed, which is immaterial for UI (a full bake of
every glyph of a font size is single-digit milliseconds).

### But what if there really are hundreds of FFI calls per frame?

Checked on live egui.cr load (icons_browser: ~4000 icons, a grid with a
texture-cache pool, text through the same stack):

- **Text.** After the first bake — zero FFI per frame: `glyph_index`,
  kerning and glyphs are memoized (`AtlasFonts`), drawing goes from the
  atlas. FFI lives only in cache misses.
- **Icons.** Baking = rasterizing an SVG into a texture, once per
  (source, tint, size); the release bake in egui.cr goes through pure
  Crystal (a NanoSVG port), the C shim is only in dev builds. A/B on
  real icons (`bin/svg_rasterizer --headless`, 128×128): C via FFI
  0.23–0.47 ms vs Crystal 0.17–0.53 ms per icon, byte-identical output
  — on that workload the ports are already on par.
- **Worst-case arithmetic.** Even if a frame makes 1000 direct FFI
  calls — 1000 × ~3.5 ns ≈ **3.5 µs per frame** against a 16 600 µs
  budget (60 fps) — 0.02 %. The real hundreds of calls per frame in
  egui.cr are the sokol draw layer; it exists regardless of the
  rasterizer/font choice and costs a few microseconds total.

In every scenario the cost of the FFI transitions is negligible against
the work the call performs; the choice between "C via FFI" and "a
Crystal port" should be made on the cost of the work itself (for
glyphs — 1.8x in favor of C; for SVG icons — parity) and on the price
of the dependency, not on the number of calls.

### Optimizations made (the port's output stayed bit-identical)

- `loader`: reusable scratch buffers instead of ~10 allocations per
  glyph (parse buffers, cur/org/orus copies, phantom points, the
  composite-glyph chain Set); `simple_glyph_into` parses a simple
  glyph directly into caller buffers; bulk outline copy into the
  accumulator.
- `ftgrays`: rasterizer cells are structs in per-row arrays reused
  between renders (previously: an `height+1` array + a class object per
  touched cell); `Ftrender` keeps one `Raster` per process so the pool
  stays warm.
- `ttinterp`: unsafe reads in the VM main loop (POP_PUSH_COUNT/code);
  the opcode counter behind `TT_OPCOUNT=1` (profiling).
- `sfnt`: unsafe reads when decoding simple-glyph coordinates (bounds
  already validated).

Measured profile after the optimizations: load + hint ~6.0 µs per
glyph, rasterization ~2.6 µs. The remaining win would be systemic
unsafe access to VM zones (~190 handlers), which would sharply
increase the review cost of acceptance.

## Tests

- `crystal run spec/ftgrays_smoke.cr` — synthetic shapes: a square, a
  triangle, a circle of conics, a cubic, even-odd.
- `crystal run --release spec/ftgrays_diff.cr [-- fonts...]` — the
  rasterizer acceptance diff against the system libfreetype (FFI
  oracle). Fonts are auto-classified (unhinted = outlines match with
  and without hinting); hinted ones are skipped with a note. Runs on
  the unhinted corpus with a 0-pixel diff. `DUMP_DIFFS=n` — ASCII dump
  of the first n mismatches.
- `crystal run --release spec/tt_unhinted_diff.cr [-- fonts...]` — the
  full pipeline without hinting, a diff of outlines/bitmaps/advances
  against FT_LOAD_NO_HINTING (80 997 glyphs, 0 diff).
- `crystal run --release spec/tt_hinted_diff.cr [-- fonts...]` — the
  hinted acceptance diff: outline comparison (points + tags with the
  0xE7 mask — TOUCH bits are VM internals and vary between FT
  versions), bitmaps and advances against FT_LOAD_DEFAULT
  (198 790 glyphs, 0 diff).
- `crystal run --release spec/cff_unhinted_diff.cr [-- fonts...]` — the
  CFF acceptance diff: outlines (points + tags + contours) and advances
  against FT_LOAD_NO_HINTING with `no-stem-darkening` set via FFI
  (632 875 glyphs across 140 OTF fonts, 0 diff).
- `crystal run --release spec/bench_render.cr -- [total] [batch]` —
  the performance benchmark (see above); `spec/bench_ffi.cr` — the
  FFI-call-cost microbenchmark; `spec/bench_diff.cr -- [n]` — a
  per-glyph diff of the same workload.
- `spec/interp_probe.cr` — manual VM probes on synthetic input.
- `tmp_c/` — a standalone build of `ftgrays.c` from the snapshot (a
  second oracle for bisection: input is a text outline dump, output is
  coverage). NB: must be built with `ftint64_shim.h` (the `FT_INT64`
  macro), otherwise it compiles the pre-2.13 rasterization path.
- `spec/bisect_dbg.cr` — a three-way glyph bisection (ours /
  C-ftgrays / system FT); `spec/ffi_dbg.cr` — a check of the FFI
  mirror of the FT structures; `spec/circle_dbg.cr` — synthetic
  cross-check against the C oracle.

## Implementation notes

- FreeType applies `FT_Outline_Translate` **before** outline
  decomposition, so conic midpoints (`v_start`/`v_middle`, C division
  `/2` truncating toward zero) round on shifted coordinates — the port
  applies the shift when reading points in `decompose`, not when
  upscaling. Found by debugging; kept as an invariant.
- Rendering follows FT_RENDER_MODE_NORMAL only: overlap handling
  (FT_OUTLINE_OVERLAP) and the LCD paths are not ported — glyph baking
  uses the plain NORMAL path.
- Square pixel sizes, grayscale (non-mono) rendering, non-tricky fonts
  — the scope the hint glue is specialized to (FT_LOAD_DEFAULT with
  v40 subpixel-hinting-minimal).

## License

MIT — see `shard.yml`. The port is derived from the FreeType source
(FTL/MIT-licensed); the original notices live in the file headers.

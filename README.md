# freetype.cr — TrueType & CFF glyph pipeline in pure Crystal

<p align="center">
  <img src="docs/logo.png" alt="freetype.cr logo" width="418">
</p>

*The logo above was rendered by this library itself — hinted glyph
rasterization + PNG packing, no FreeType, no FFI (`spec/gen_logo.cr`).*

A self-contained Crystal port of FreeType's font pipeline: the
`ftgrays.c` anti-aliasing rasterizer (plus the `ftraster.c`
black-and-white one for FT_RENDER_MODE_MONO and the `ftlcdfil.c` FIR
filter for LCD), the `ttinterp.c` bytecode-hinting
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
- `src/ftrender.cr` — the `ftsmooth.c`/`ftobjs.c` rendering glue for all
  four `FT_Render_Mode`s: control box → pixel bbox (floor/ceil as in
  `ft_glyphslot_preset_bitmap`) → translation → rasterization. NORMAL
  renders through `ftgrays`; LCD/LCD_V pad the cbox ±43/64, implode the
  buffer (x*3 / y*3) and apply the default five-tap FIR filter
  (`[0x08, 0x4D, 0x56, 0x4D, 0x08]`, ported from `ftlcdfil.c`); MONO
  goes through `src/ftraster1.cr`. The result is an
  `Ftrender::GlyphBitmap` (8-bit coverage or 1-bit MSB-first packed,
  top-down; `pitch` and `mode` fields included).
- `src/ftraster1.cr` — a port of the `ftraster.c` black-and-white
  rasterizer (FreeType 2.13.3): profile pool with y-turns, line/Bezier
  up/down splitting, the two-pass sweep (vertical + horizontal, MSB-first
  bits) with dropout/stub/smart handling, sub-banding. Used for
  FT_RENDER_MODE_MONO; honours `FT_OUTLINE_HIGH_PRECISION` (TrueType
  hinted outlines set it) and the dropout scan-mode flags in tags[0].
- `src/fttrigon.cr` — a port of `fttrigon.c` (fixed-point trigonometry:
  `FT_Vector_Rotate`, `FT_Vector_Norm_Len`, etc. — needed for
  projections onto arbitrary axes in the bytecode).
- `src/autofit/` — the auto-hinter (`src/autofit/*` of FreeType): the
  shared point/segment/edge machinery (`afhints.cr`), the latin writing
  system (`aflatin.cr` — global metrics with blue zones, stem widths,
  digit check, segment linking with the demerit scoring, edge hinting;
  the dummy `none_dflt` fallback is folded into `LatinMetrics`), the
  CJK writing system (`afcjk.cr` — per-dimension blue zones, the
  distance-based segment linking with serif de-linking, the
  `af_hint_normal_stem` grid fitter, `AF_SCALER_FLAG_NO_ADVANCE`), the
  style coverage scan with the lazily built per-style metrics
  (`afglobal.cr` — the hani fallback of CJK-enabled builds; a latin
  style without blue zones is disabled to `none_dflt', as in
  `af_latin_metrics_init_blues`), and the `af_loader_load_glyph` glue
  (`afloader.cr`) on top of both the TT and the CFF face (the CFF hook
  mirrors FT_LOAD_FORCE_AUTOHINT). Segment/edge indices replace the C
  pointer arithmetic; `afblue_data.cr`/`afranges_data.cr` are generated
  from the FreeType sources.
- `src/tt/ttgxvar.cr` — GX font variations (a 1:1 port of ttgxvar.c):
  `fvar'/`avar' (+ avar v2 store) parsing with design ↔ normalized
  coordinate conversion (`GXBlend.from_font'), `gvar' glyph deltas with
  the packed point/delta decoding, tuple application and IUP-style
  interpolation (`#apply_glyph_deltas'), and `HVAR'/`VVAR' advance
  adjustments through the ItemVariationStore/DeltaSetIndexMap machinery
  (`#advance_delta'). The loader hooks (`HintedFace#set_var_design',
  the HVAR-adjusted advance, the phantom/component delta calls in
  src/tt/loader.cr and the non-default-instance scaling from the
  unrounded 16.16 coordinates) are verified oracle-exact — hinted and
  unhinted — by spec/var_diff.cr. `cvar' CVT variations (including the
  `prep' rerun on coordinate changes and the GETVARIATION/GETDATA
  opcodes) are in place too (spec/var_cvar_diff.cr), as are CFF2
  variations — the CFF2 table layout, the `blend'/`vsindex' operators in
  charstrings and Private DICTs (cff_blend_doBlend writes the results
  back into the operand stack), HVAR advances and the vstore parsing
  (spec/cff2_var_diff.cr, SourceSerif4Variable) — and `MVAR' metric
  variations: the tagged deltas re-apply to the modelled font fields
  (typo/win/line-gap metrics, underline, strikeout, x-height) with
  FreeType's exact repeated-application semantics, including the derived
  ascender/descender/height adjustments of tt_apply_mvar
  (spec/var_mvar_diff.cr on a synthesized Liberation font);
  `Font#raw_table' hands this module the raw tables.
- `src/tt/sfnt.cr` — a minimal SFNT parser: head, maxp, hhea, hmtx,
  cmap (formats 4 and 12), loca, glyf, cvt, fpgm, prep, gasp, kern.
  Only what loading outlines and hinting need. WOFF1 wrappers are
  unwrapped into a plain SFNT before parsing (the `woff_open_font'
  approach, zlib via the Crystal stdlib) — `TT::Font`/`CFF::Face`
  accept `.woff` buffers directly; WOFF2 (brotli) is unwrapped the same
  way when built with `-Dwith_woff2` (see `src/tt/woff2.cr`).
  TrueType/OpenType collections (`.ttc`/`.otc`) are handled by slicing
  out the requested face: pass `face_index` to `TT::Font`/
  `TT::HintedFace`/`CFF::Face` (it reaches WOFF2 collections too).
- `src/tt/woff2.cr` — the WOFF2 counterpart (a port of FreeType's
  `sfwoff2.c`): header/table-directory parsing, the 255UShort/base128
  integer formats, brotli decompression of the table stream and the
  reconstruction of transformed `glyf'/`loca' (triplet decoding,
  bbox/nPoints/nContour substreams, composite glyphs) and `hmtx'.
  Opt-in: the file (and the brotli decoder) is only compiled with
  `-Dwith_woff2`; without the flag a `.woff2` buffer raises a ParseError
  saying so. The default build gains no C dependency. **Caveat: only
  build with `-Dwith_woff2` if you actually load `.woff2` buffers** —
  the brotli decoder is slow to compile **in release mode only** (about
  10 minutes, cold compiler cache; non-release builds compile at the
  usual speed), while the default build is fast. The
  brotli backend is selectable at compile time: the pure-Crystal decoder
  shard [brotli.cr](https://github.com/OrelSokolov/brotli.cr) by
  default, or libbrotlidec through FFI by adding `-Dnative_brotli` (an
  all-C reference build that compiles much faster; both pass the same
  WOFF2 acceptance diff).
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
  binary-coded decimal reals verbatim). CFF2 is parsed too (32-bit
  INDEX counts, the FDArray-only layout, the VariationStore offset and
  maxstack), including the Private DICT `blend'/`vsindex' operators —
  `CFF.build_blend_vector' is the shared cff_blend_build_vector port.
- `src/cff/cffinterp.cr` — the Type 2 charstring interpreter: a port of
  `psintrp.c` cf2_interpT2CharString (typed int/fixed operand stack,
  width parsing, path/arithmetic operators, flex, seac via endchar, the
  xorshift `random`) specialized to the unhinted no-stem-darkening
  mode, plus the unhinted cf2_glyphpath from `pshints.c` and the
  ps_builder outline callbacks from `psobjs.c`. 32-bit wrapping
  arithmetic is carried over explicitly. A tracer is built in
  (`CFF_TRACE=1`, the TT_TRACE counterpart).
- `src/cff/cffhints.cr` — the Adobe hinting engine: a port of
  `pshints.c` (CF2_Hint edge expansion with ghost/inverted pairs,
  the hint map — build/insert with initial-map recomputation, the
  two-pass optimum pixel positioning of `cf2_hintmap_adjustHints`,
  the piecewise-linear CS→DS map) and `psblues.c` (blue zones with
  family flat-edge matching, BlueScale cutoff, overshoot suppression /
  blue boost, `cf2_blues_capture`, the ideographic em-box heuristic)
  plus the HintMask object from `psintrp.c`. The hinted GlyphPath
  (per-subpath/hint-substitution maps, first-map closes) lives in
  `cffinterp.cr`; stem darkening (offsets, intersections, winding) is
  out — FT defaults to it off since 2.7.
- `src/cff/face.cr` — the CFF-flavoured OTF face: a port of
  `cff_slot_load` (cffgload.c) — advance from `hmtx`, FontMatrix →
  translate → FT_MulFix scale in the cffgload.c order — reusing the
  SFNT glue (cmap/hmtx) from `src/tt/sfnt.cr`. Returns the same
  `TT::LoadedGlyph` as the TrueType loader. CFF2 faces additionally
  support `set_var_design': the normalized coordinates drive the
  charstring/Private DICT blend machinery and the HVAR advance delta,
  and the Private DICTs are re-blended on coordinate changes.

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
renders through the same `Ftrender` as the TrueType path. `hint: true`
(default in FT terms: FT_LOAD_DEFAULT) runs the ported Adobe hinting
engine — bit-exact against it.

WOFF2 (`.woff2` webfonts) is opt-in: build with `-Dwith_woff2` (plus
`-Dnative_brotli` for the libbrotlidec FFI backend instead of the
pure-Crystal [brotli.cr](https://github.com/OrelSokolov/brotli.cr)
decoder). **Only do so if you actually load `.woff2` buffers** — pulling
in the brotli decoder makes **release** (`--release`) compilation
extremely slow (~10 minutes on a cold compiler cache); non-release
builds are unaffected and compile at the usual speed. Without the flags
the build stays fast and `.woff2` raises a ParseError. WOFF1 (`.woff`) needs no flags —
it is always compiled (stdlib zlib).

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
- **CFF (OTF), hinted (Adobe engine):** the port of `pshints.c`/
  `psblues.c` (stem hints, hint maps with two-pass optimum positioning,
  blue zones with family matching, overshoot suppression and the
  BlueScale cutoff, cntrmask counter maps, ghost/inverted pairs) —
  **632 875 glyphs / 140 OTF fonts / 12-37 px, 0 diff** against
  FT_LOAD_DEFAULT (Adobe engine, darkening off — the FT default since
  2.7), plus the CID font above (327 675 glyphs, 0 diff).
- **WOFF1:** 222 942 glyphs across 6 fonts (Liberation TTF, Roboto TTF,
  three OTFs and the CID Noto above, all re-wrapped as WOFF1 with
  zlib-compressed tables) — **0 diff** against the system libfreetype
  loading the same `.woff` files.
- **WOFF2 (opt-in, `-Dwith_woff2`):** 4 625 glyphs across 3 real webfonts
  (Roboto and Open Sans — hinted, i.e. the reconstructed `glyf' feeds the
  full bytecode pipeline, outline+bitmap+advance diffed; Lora —
  unhinted) — **0 diff** against the system libfreetype loading the same
  `.woff2` files. Covers transformed `glyf'/`loca' (simple, composite,
  empty glyphs, explicit and computed bboxes), transformed `hmtx' and
  short `loca' (indexToLocFormat 0).
- **MONO/LCD/LCD_V rendering:** **749 370 glyph bitmaps** across the
  DejaVu + Liberation corpus (38 fonts, mono/lcd/lcdv, 13/24 px) —
  **0 diff** against `FT_Render_Glyph` of the system libfreetype
  (bit-exact buffers, dimensions and offsets). The mono mode runs the
  ported `ftraster.c`; LCD/LCD_V go through the ftgrays path with the
  default FIR filter. NB: pixel-exact LCD output requires a libfreetype
  built with subpixel rendering enabled (`SUBPIXEL_RENDERING`), as the
  distro build here is.
- **TTC/OTC collections:** all **30 faces** of the system Noto CJK
  collections (NotoSansCJK/NotoSerifCJK Regular+Bold, CFF-flavoured;
  10+10 Sans + 5+5 Serif faces) loaded through
  `CFF::Face.new(data, face_index)' — outlines + advances, hinted
  (Adobe engine) and unhinted, **7 864 200 glyph comparisons, 0 diff**
  against the system libfreetype opening the same `.ttc' with the same
  face index.

### CFF limitations (honest)

- **Adobe hinting is ported** (`pshints.c`/`psblues.c` and the hint ops
  of `psintrp.c` — see `src/cff/cffhints.cr`); `load_glyph(gid, hint:
  true)` reproduces FT_LOAD_DEFAULT bit for bit. **Stem darkening is
  not ported and intentionally so**: FreeType itself defaults to
  `no-stem-darkening=TRUE` since 2.7, so the no-darkening output
  matches stock libfreetype (verified glyph-for-glyph). Enabling
  darkening via `FT_Property_Set` would diverge. Subfonts with a
  non-identity FontMatrix still load through the unhinted path.
- Bare CFF (`.cff` files with their own encoding/charset charmaps) is
  not parsed — only CFF1 and CFF2 in an SFNT/OTF and WOFF1 (which is
  unwrapped to SFNT transparently). WOFF2 is unwrapped too, but only in
  builds with `-Dwith_woff2` (the brotli decoder is compiled in only
  under that flag — the default build never pulls it in; the backend is
  the pure-Crystal brotli.cr shard, or libbrotlidec through FFI with the
  additional `-Dnative_brotli`; the reconstruction itself, including the
  transformed `glyf'/`hmtx', is pure Crystal). CFF2 charstring transforms
  are rejected.
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
- `crystal run --release spec/cff_hinted_diff.cr [-- fonts...]` — the
  hinted CFF acceptance diff against FT_LOAD_DEFAULT (Adobe engine,
  darkening off): 632 875 glyphs across 140 OTF fonts, 0 diff.
- `crystal run --release -Dwith_woff2 spec/woff2_diff.cr` — the WOFF2
  acceptance diff (see above). Skips itself with a note when the flag
  is absent, no corpus (`tmp_check/w2_*.woff2`) is found, or the
  passed files are missing — so it is safe to invoke unconditionally;
  it is intentionally not part of CI (the CI oracle FreeType is built
  without brotli and the flag would drag libbrotlidec into the link).
- `crystal run --release spec/ttc_diff.cr [-- fonts.ttc ...]` — the
  collection acceptance diff: every face of a `.ttc'/`.otc' (default
  corpus: the system Noto CJK collections) diffed against the system
  libfreetype opened with the same face index, hinted and unhinted.
- `crystal run --release spec/mono_lcd_diff.cr [-- fonts...]` — the
  MONO/LCD/LCD_V acceptance diff: every glyph of the corpus rendered
  through `Ftrender.render_glyph` in each mode and compared bit-for-bit
  with `FT_Render_Glyph` (749 370 bitmaps, 0 diff). LCD modes expect the
  oracle libfreetype to be built with subpixel rendering.
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
- Rendering covers all four `FT_Render_Mode`s (NORMAL via ftgrays, MONO
  via ftraster1, LCD/LCD_V with the default FIR filter). Overlap
  handling (FT_OUTLINE_OVERLAP) is not ported. Pixel-exact LCD/LCD_V
  output assumes subpixel rendering is enabled in the reference
  libfreetype (`SUBPIXEL_RENDERING`); distro builds usually have it.
- Square pixel sizes, grayscale (non-mono) rendering, non-tricky fonts
  — the scope the hint glue is specialized to (FT_LOAD_DEFAULT with
  v40 subpixel-hinting-minimal).

## License

MIT — see `shard.yml`. The port is derived from the FreeType source
(FTL/MIT-licensed); the original notices live in the file headers.

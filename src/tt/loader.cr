# TrueType hinted-glyph loading pipeline: the port of
# ~/freetype/src/truetype/ttgload.c `load_truetype_glyph' /
# `TT_Process_Simple_Glyph' / `TT_Process_Composite_Glyph' /
# `TT_Hint_Glyph' / `tt_loader_init' / `tt_size_run_prep', specialised to
# FT_LOAD_DEFAULT with v40 subpixel-hinting-minimal, square pixel sizes and
# grayscale (non-mono) rendering, on non-tricky fonts.
#
# Produces 26.6 outlines translated by -pp1.x plus the 26.6 horizontal
# advance (pp2.x - pp1.x), matching what FT_Load_Glyph leaves in the slot.
#
# Phantom point bookkeeping (critical): phantom points live in the zone
# tail beyond the outline point count -- `tt_prepare_zone' adds 4 to the
# zone size, and `outline->n_points' never includes them, so component
# phantoms are transient and get overwritten by subsequent points.

require "../fttrigon"
require "./sfnt"
require "./ttinterp"
require "./ttgxvar"

module TT
  # Fixed-point replicas of the LP64 FreeType helpers.
  module Fixed
    # FT_MulFix (ftcalc.c, FT_INT64 path).
    def self.mulfix(a : Int64, b : Int64) : Int64
      ab = a &* b
      (ab &+ 0x8000_i64 &- (ab < 0 ? 1_i64 : 0_i64)) >> 16
    end

    # FT_DivFix (ftcalc.c).
    def self.divfix(a : Int64, b : Int64) : Int64
      s = 1_i8
      ua = a
      if ua < 0
        s = -s
        ua = -ua
      end
      ub = b
      if ub < 0
        s = -s
        ub = -ub
      end
      q = ub > 0 ? ((ua.to_u64! << 16) &+ (ub.to_u64! >> 1)) // ub : 0x7FFF_FFFF_u64
      q_i = q.to_i64!
      s < 0 ? -q_i : q_i
    end

    # FT_MulDiv (ftcalc.c).
    def self.muldiv(a : Int64, b : Int64, c : Int64) : Int64
      s = 1_i8
      ua = a
      if ua < 0
        s = -s
        ua = -ua
      end
      ub = b
      if ub < 0
        s = -s
        ub = -ub
      end
      uc = c
      if uc < 0
        s = -s
        uc = -uc
      end
      d = uc > 0 ? ((ua.to_u64! &* ub.to_u64!) &+ (uc.to_u64! >> 1)) // uc : 0x7FFF_FFFF_u64
      d_i = d.to_i64!
      s < 0 ? -d_i : d_i
    end

    # FT_PIX_ROUND(x) = (x + 32) & ~63.
    def self.pix_round(x : Int64) : Int64
      (x &+ 32) & -64_i64
    end
  end

  # The GS subset that survives between the `prep' program and glyph
  # programs (TT_Save_Context): everything else resets to the default
  # graphics state at every TT_Run_Context.
  struct SizeGs
    property minimum_distance : Int64 = 64
    property control_value_cutin : Int64 = 68
    property single_width_cutin : Int64 = 0
    property single_width_value : Int64 = 0
    property delta_base : Int64 = 9
    property delta_shift : Int64 = 3
    property auto_flip : Bool = true
    property instruct_control : Int64 = 0
    property scan_control : Bool = false
    property scan_type : Int64 = 0
  end

  # A glyph loaded at the current pixel size.
  struct LoadedGlyph
    getter xs : Array(Int64)     # 26.6, origin at (0,0), y up
    getter ys : Array(Int64)
    getter tags : Array(UInt8)   # FT_CURVE_TAG_ON / CONIC
    getter contours : Array(Int32) # inclusive end point index per contour
    getter advance : Int64       # 26.6 horizontal advance

    def initialize(@xs, @ys, @tags, @contours, @advance)
    end
  end

  class HintedFace
    getter font : Font

    @px : Int32 = 0
    @x_scale : Int64 = 0_i64
    @y_scale : Int64 = 0_i64
    @tt_scale : Int64 = 0_i64 # ttmetrics.scale (square ppem -> x_scale)
    @size_gs : SizeGs = SizeGs.new
    @use_autohint = false
    @cvt_base : Array(Int64) = [] of Int64   # post-prep CVT (persistent)
    @storage_base : Array(Int64) = [] of Int64
    @fpgm_done = false
    @prep_px = -1
    @backward_compat = false
    @hinting_enabled = true # cleared when prep sets instruct_control bit 0
    # GX variations (ttgxvar.cr): nil for a static font. `doblend' mirrors
    # face->doblend — set by #set_var_design, gates every delta path.
    @blend : TT::GXBlend? = nil
    @doblend = false
    @design_coords : Array(Int64) = [] of Int64 # blend->coords (raw input)
    @normalized : Array(Int64) = [] of Int64    # blend->normalizedcoords
    # First VM failure ('fpgm'/'prep'/glyph program), for diagnostics:
    # once set, this face renders unhinted (see set_pixel_size/load_glyph).
    getter vm_error : String?

    # Hot-path scratch (reused across glyphs; nothing here escapes):
    # parsed simple-glyph points, the scaled zone copies, and the VM's
    # per-glyph CVT/storage restores.
    @chain = Set(Int32).new
    @scr_glyf_xs = Array(Int64).new(64, 0_i64)
    @scr_glyf_ys = Array(Int64).new(64, 0_i64)
    @scr_glyf_tags = Array(UInt8).new(64, 0_u8)
    @scr_glyf_contours = Array(Int32).new(8, 0)
    @scr_cur_x = Array(Int64).new(64, 0_i64)
    @scr_cur_y = Array(Int64).new(64, 0_i64)
    @scr_org_x = Array(Int64).new(64, 0_i64)
    @scr_org_y = Array(Int64).new(64, 0_i64)
    @scr_orus_x = Array(Int64).new(64, 0_i64)
    @scr_orus_y = Array(Int64).new(64, 0_i64)
    @scr_tags = Array(UInt8).new(68, 0_u8)
    @scr_contours = Array(Int32).new(8, 0)
    @scr_cvt = Array(Int64).new(0, 0_i64)
    @scr_storage = Array(Int64).new(0, 0_i64)
    @scr_pp = Array({Int64, Int64}).new(4, {0_i64, 0_i64})

    def initialize(data : Bytes, face_index : Int32 = 0)
      # Copy the buffer: callers routinely pass a slice into a temporary
      # String (File.read(...).to_slice), which the GC may collect while
      # the face is alive — the parsed tables would silently go garbage
      # mid-run. Fonts are a few hundred KB; the copy is the cheap half
      # of this safety.
      @font = Font.new(data.dup, face_index)
      # FT hands bytecode-less fonts to the auto-hinter (ftobjs.c: an SFNT
      # with a non-empty `loca', maxp.maxSizeOfInstructions == 0, and both
      # `fpgm' and `prep' EMPTY — not merely tiny: a 7-byte `prep' font
      # still goes through the bytecode path with no glyph programs).
      @use_autohint = @font.fpgm.empty? && @font.prep.empty? &&
                      @font.max_size_of_instructions == 0
      # Reserve extra stack slots for broken fonts (tt_size_init_bytecode in
      # ttobjs.c): 50% more than maxStackElements, minimum +128 — e.g. the
      # variable Ubuntu Sans Mono declares maxStackElements=0 yet ships a
      # `prep' program that pushes values.
      padded_stack = font.max_stack + {font.max_stack // 2, 128}.max
      @exec = TT::ExecContext.new(
        font.max_functions,
        font.max_instruction_defs,
        font.max_storage,
        padded_stack,
        font.max_twilight,
      )
    end

    # FT_Set_Var_Design_Coordinates (TT_Set_Var_Design): store the design
    # coordinates, normalize them, and turn on blending. Coordinates beyond
    # the axis count are dropped; missing ones default to the axes'
    # defaults. A no-op for static fonts. Changing the coordinates on a
    # size that already ran `prep' invalidates it — FreeType reloads the
    # `cvar'-adjusted CVT and resets size->cvt_ready so the `prep'
    # program reruns with the new values.
    def set_var_design(coords : Array(Int64)) : Nil
      blend = (@blend ||= TT::GXBlend.from_font(font) rescue nil)
      return if blend.nil?
      n = {coords.size, blend.num_axis}.min
      cs = Array(Int64).new(blend.num_axis, 0_i64)
      blend.num_axis.times do |i|
        cs[i] = i < n ? coords.unsafe_fetch(i) : blend.axis[i].default
      end
      @design_coords = cs
      @normalized = blend.to_normalized(cs)
      @doblend = true
      # TT_Set_Var_Design leaves the normalized coordinates in
      # face->blend, where the interpreter's GETVARIATION/GETDATA and
      # GETINFO's VARIATION GLYPH bit read them.
      @exec.variation_coords = @normalized.dup

      if @prep_px > 0
        @prep_px = -1 # force `fpgm'/`prep' rerun with the new CVT
        set_pixel_size(@px)
      end
    end

    # The current design coordinates (empty for a static/unset face).
    def var_design_coords : Array(Int64)
      @design_coords.dup
    end

    def num_glyphs : Int32
      font.num_glyphs
    end

    # Active size parameters for the auto-hint glue (af_loader scaler).
    def pixel_size : Int32
      @px
    end

    def x_scale : Int64
      @x_scale
    end

    def y_scale : Int64
      @y_scale
    end

    # FT_LOAD_NO_SCALE | FT_LOAD_LINEAR_DESIGN: the unhinted outline in
    # font units at origin (0,0) and the advance in font units — the
    # input the auto-hinter expects.
    def load_glyph_font_units(gid : Int32) : LoadedGlyph
      acc = Acc.new
      @chain.clear
      saved_x = @x_scale
      saved_y = @y_scale
      @x_scale = 0x10000_i64
      @y_scale = 0x10000_i64
      begin
        pp = load_glyph_rec(gid, 0, false, acc, @chain)
      ensure
        @x_scale = saved_x
        @y_scale = saved_y
      end
      advance = pp[1][0] &- pp[0][0]
      # TT_Load_Glyph translates the outline by -pp1.x = lsb - xMin even at
      # FT_LOAD_NO_SCALE (ttgload.c: `if (loader.pp1.x) FT_Outline_Translate').
      acc.xs.map! { |x| x &- pp[0][0] } if pp[0][0] != 0
      LoadedGlyph.new(acc.xs, acc.ys, acc.tags, acc.contour_ends, advance)
    end

    # Profiling helper (see TT::OPCOUNT_ENABLED).
    def opcode_counts : Array(Int64)
      @exec.opcode_counts
    end

    def set_pixel_size(px : Int32) : Nil
      return if px == @prep_px

      @px = px
      @x_scale = Fixed.divfix(px.to_i64 << 6, font.upem.to_i64)
      @y_scale = @x_scale # square ppem
      @tt_scale = @x_scale

      exec = @exec
      exec.ppem = @px
      exec.scale_x = @x_scale
      exec.scale_y = @y_scale
      exec.tt_scale = @tt_scale
      # VM contract mirrors C's face->cvt: raw font units shifted to 26.6;
      # with blending, the `cvar' deltas (in F26Dot6) are folded in, as
      # tt_face_load_cvt/tt_face_vary_cvt leave them in face->cvt.
      cvt_raw = font.cvt.map { |v| v.to_i64 &* 64 }
      if (blend = @blend) && @doblend
        deltas = blend.vary_cvt(cvt_raw.size, @normalized)
        cvt_raw.size.times { |i| cvt_raw[i] &+= deltas.unsafe_fetch(i) }
      end
      exec.cvt_raw = cvt_raw

      # --- `fpgm': once per face (tt_size_ready_bytecode).  C has size->cvt
      # scaled at this point; prep rescales from the raw table anyway.
      # A VM crash is not fatal: FreeType caches the error for the size
      # (size->bytecode_ready = error); we go one step further and keep
      # rendering — unhinted — so a broken font can never take the app down.
      unless @fpgm_done
        exec.cvt = font.cvt.map { |v| Fixed.mulfix(v.to_i64, @tt_scale) }
        begin
          exec.run_fpgm(font.fpgm)
        rescue ex : ExecutionError
          @vm_error = "'fpgm' failed: #{ex.message}"
        end
        @fpgm_done = true
      end

      # --- `prep': per size (tt_size_run_prep zeroes storage, scales the
      # CVT from cvt_raw, runs the program, saves the GS subset) ---
      begin
        exec.run_prep(font.prep)
      rescue ex : ExecutionError
        @vm_error = "#{@vm_error ? "#{@vm_error}; " : ""}'prep' failed: #{ex.message}"
      end

      gs = vm_save_gs
      @cvt_base = exec.cvt_base.dup
      @storage_base = exec.storage_base.dup

      # tt_loader_init: instruct_control checks after prep.
      if (gs.instruct_control & 1) != 0
        @hinting_enabled = false
      else
        @hinting_enabled = true
      end
      # A failed fpgm/prep leaves half-defined functions and GS behind —
      # never run glyph programs on such a face.
      @hinting_enabled = false if @vm_error
      if (gs.instruct_control & 2) != 0
        gs = SizeGs.new
      end
      # v40 backward compatibility (grayscale mode, non-tricky font).
      @backward_compat = (gs.instruct_control & 4) == 0

      @size_gs = gs
      @prep_px = px
    end

    # Auto-hinter hook: overridden by the autofit glue (autofit/afloader.cr)
    # when it is linked in — returns the auto-hinted glyph, or nil when the
    # autofit port is not available (then the plain bytecode path runs).
    def load_glyph_autohint(gid : Int32) : LoadedGlyph?
      nil
    end

    def load_glyph(gid : Int32, hint : Bool = true) : LoadedGlyph
      raise "call set_pixel_size first" if @prep_px <= 0
      hinted_load = hint # FT flag state (grid-fit applies to it)
      hint = false unless @hinting_enabled

      # FT_Load_Glyph hands fonts without bytecode (empty `fpgm' and a
      # `prep' of at most 7 bytes, ftobjs.c) to the auto-hinter.
      if hinted_load && @use_autohint
        ah = load_glyph_autohint(gid)
        return ah if ah
      end

      acc = Acc.new # fresh per glyph: its arrays ship out in LoadedGlyph
      @chain.clear
      begin
        pp = load_glyph_rec(gid, 0, hint, acc, @chain)
      rescue ex : ExecutionError
        # A glyph program crashed the VM. FreeType fails the whole load
        # here (callers blank the glyph); we prefer resilience — retry the
        # same glyph unhinted, so only the hinting of THIS glyph is lost.
        @vm_error = "#{@vm_error ? "#{@vm_error}; " : ""}gid #{gid}: #{ex.message}"
        acc.xs.clear
        acc.ys.clear
        acc.tags.clear
        acc.contour_ends.clear
        @chain.clear
        pp = load_glyph_rec(gid, 0, false, acc, @chain)
      end

      acc.xs.map! { |x| x &- pp[0][0] } if pp[0][0] != 0
      advance = pp[1][0] &- pp[0][0]
      # ft_glyphslot_grid_fit_metrics (ftobjs.c): FT_PIX_ROUNDs the advance
      # for every load without FT_LOAD_NO_HINTING, bytecode or not.
      advance = Fixed.pix_round(advance) if hinted_load
      LoadedGlyph.new(acc.xs, acc.ys, acc.tags, acc.contour_ends, advance)
    end

    # ---------------------------------------------------------------------

    # Point accumulator standing in for FT_GlyphLoader's base outline.
    private class Acc
      property xs : Array(Int64) = [] of Int64
      property ys : Array(Int64) = [] of Int64
      property tags : Array(UInt8) = [] of UInt8
      property contour_ends : Array(Int32) = [] of Int32

      def n_points : Int32
        @xs.size
      end
    end

    private def load_glyph_rec(gid : Int32, recurse : Int32, hint : Bool,
                               acc : Acc, chain : Set(Int32)) : Array({Int64, Int64})
      raise ParseError.new("composite recursion loop at glyph #{gid}") unless chain.add?(gid)
      raise ParseError.new("composite nesting too deep") if recurse > 64

      x_min, y_min, x_max, y_max = font.glyph_bbox(gid)
      byte_len = font.glyph_range(gid)[1] - font.glyph_range(gid)[0]
      n_contours = byte_len == 0 ? 0 : font.glyph_bytes(gid).size < 10 ? 0 : i16_of(font.glyph_bytes(gid), 0)
      if byte_len == 0 || n_contours == 0
        x_min = y_min = x_max = y_max = 0
      end

      aw, lsb = font.h_metrics(gid)
      tsb, ah = font.v_metrics(gid, y_max)

      # tt_face_get_metrics + tt_hadvance_adjust: HVAR owns the advance
      # (for composites the USE_MY_METRICS component's delta applies —
      # it is added in that component's own recursive call).
      if (blend = @blend) && @doblend && blend.has_hvar?
        aw &+= blend.advance_delta(gid, @normalized)
      end

      # tt_loader_set_pp (font units) -- into the shared scratch (the
      # array travels down the composite recursion unchanged).
      pp1x = x_min.to_i64 &- lsb
      pp = @scr_pp
      pp[0] = {pp1x, 0_i64}
      pp[1] = {pp1x &+ aw, 0_i64}
      pp[2] = {0_i64, y_max.to_i64 &+ tsb}
      pp[3] = {0_i64, y_max.to_i64 &+ tsb &- ah}
      # v40, non-mono render mode: pp3.x = pp4.x = advance / 2 (C division).
      half = aw.to_i64 // 2
      pp[2] = {half, pp[2][1]}
      pp[3] = {half, pp[3][1]}

      if byte_len == 0 || n_contours == 0
        # empty glyph: vary the phantom points (ttgload.c), then scale
        vary_phantoms(gid, pp)
        scale_pp(pp)
        chain.delete(gid)
        return pp
      end

      if n_contours > 0
        # simple glyph: phantoms are scaled together with the points in
        # TT_Process_Simple_Glyph -- pp stays in font units here (the
        # deltas are applied inside process_simple)
        process_simple(gid, pp, hint, acc)
      else
        # composite: vary the phantom points before scaling (ttgload.c
        # lines ~1583-1608), then scale and assemble
        vary_phantoms(gid, pp)
        scale_pp(pp)
        g = font.composite_glyph(gid).not_nil!
        process_composite(g, gid, pp, hint, acc, recurse, chain)
      end

      chain.delete(gid)
      pp
    end

    private def scale_pp(pp : Array({Int64, Int64})) : Nil
      pp[0] = {Fixed.mulfix(pp[0][0], @x_scale), 0_i64}
      pp[1] = {Fixed.mulfix(pp[1][0], @x_scale), 0_i64}
      pp[2] = {Fixed.mulfix(pp[2][0], @x_scale), Fixed.mulfix(pp[2][1], @y_scale)}
      pp[3] = {Fixed.mulfix(pp[3][0], @x_scale), Fixed.mulfix(pp[3][1], @y_scale)}
    end

    # TT_Vary_Apply_Glyph_Deltas on a phantom-only "outline" (ttgload.c's
    # four-element communication structure) — the composite/empty-glyph
    # path, applied in font units before scaling.
    private def vary_phantoms(gid : Int32, pp : Array({Int64, Int64})) : Nil
      blend = @blend
      return unless blend && @doblend

      xs = Array(Int64).new(4) { |i| pp.unsafe_fetch(i)[0] }
      ys = Array(Int64).new(4) { |i| pp.unsafe_fetch(i)[1] }
      d = blend.apply_glyph_deltas(gid, xs, ys, [] of Int32, @normalized,
                                   blend.has_hvar?, blend.has_vvar?)
      4.times do |i|
        pp[i] = {xs.unsafe_fetch(i) &+ d[:dx][i], ys.unsafe_fetch(i) &+ d[:dy][i]}
      end
    end

    private def process_simple(gid : Int32, pp : Array({Int64, Int64}),
                               hint : Bool, acc : Acc) : Nil
      # Parse into scratch (reused) buffers.
      n_real, instructions, _x_min, _y_min, _x_max, _y_max = font.simple_glyph_into(
        gid, @scr_glyf_xs, @scr_glyf_ys, @scr_glyf_tags, @scr_glyf_contours)
      raise ParseError.new("simple glyph expected") if n_real == 0
      n = n_real + 4

      cur_x = @scr_cur_x
      cur_y = @scr_cur_y
      cur_x.clear; cur_y.clear
      cur_x.concat(@scr_glyf_xs)
      cur_y.concat(@scr_glyf_ys)
      cur_x << pp[0][0]; cur_y << pp[0][1]
      cur_x << pp[1][0]; cur_y << pp[1][1]
      cur_x << pp[2][0]; cur_y << pp[2][1]
      cur_x << pp[3][0]; cur_y << pp[3][1]

      # TT_Vary_Apply_Glyph_Deltas on the whole zone (points + phantoms),
      # in font units, before the orus copy and the scaling (ttgload.c:
      # "Deltas apply to the unscaled data"). `ux'/`uy' keep the rounded
      # 26.6-of-font-units value (FT_fixedToFdot6) for the unrounded
      # scaling below.
      vary = false
      ur_x = ur_y = Array(Int64).new(0)
      if (blend = @blend) && @doblend
        contours = @scr_glyf_contours
        d = blend.apply_glyph_deltas(gid, cur_x, cur_y, contours,
                                     @normalized, blend.has_hvar?,
                                     blend.has_vvar?)
        ur_x = Array(Int64).new(n, 0_i64)
        ur_y = Array(Int64).new(n, 0_i64)
        n.times do |i|
          ur_x[i] = (cur_x[i] << 6) &+ d[:ux][i]
          ur_y[i] = (cur_y[i] << 6) &+ d[:uy][i]
          cur_x[i] &+= d[:dx][i]
          cur_y[i] &+= d[:dy][i]
        end
        pp[0] = {cur_x[n - 4], cur_y[n - 4]}
        pp[1] = {cur_x[n - 3], cur_y[n - 3]}
        pp[2] = {cur_x[n - 2], cur_y[n - 2]}
        pp[3] = {cur_x[n - 1], cur_y[n - 1]}
        vary = true
      end

      # orus copy happens BEFORE scaling (font units) when hinted.
      orus_x = @scr_orus_x
      orus_y = @scr_orus_y
      orus_x.clear; orus_x.concat(cur_x)
      orus_y.clear; orus_y.concat(cur_y)

      if vary
        # a non-default instance scales from the unrounded (16.16-precision)
        # coordinates, rounding to the nearest 1/64th (ttgload.c)
        n.times do |i|
          cur_x[i] = (Fixed.mulfix(ur_x[i], @x_scale) &+ 32) >> 6
          cur_y[i] = (Fixed.mulfix(ur_y[i], @y_scale) &+ 32) >> 6
        end
      else
        n.times do |i|
          cur_x[i] = Fixed.mulfix(cur_x[i], @x_scale)
          cur_y[i] = Fixed.mulfix(cur_y[i], @y_scale)
        end
      end

      tags = @scr_tags
      tags.clear
      tags.concat(@scr_glyf_tags)
      tags << 0_u8; tags << 0_u8; tags << 0_u8; tags << 0_u8
      contours = @scr_contours
      contours.clear; contours.concat(@scr_glyf_contours)

      # phantoms: with HVAR/VVAR and grid-fitting they come from the
      # unscaled values directly (ttgload.c — "already adjusted but
      # unscaled"); otherwise from the scaled outline points.
      if vary && (hb = @blend.not_nil!)
        if hb.has_hvar? && hint
          pp[0] = {Fixed.mulfix(pp[0][0], @x_scale), 0_i64}
          pp[1] = {Fixed.mulfix(pp[1][0], @x_scale), 0_i64}
        else
          pp[0] = {cur_x[n - 4], cur_y[n - 4]}
          pp[1] = {cur_x[n - 3], cur_y[n - 3]}
        end
        if hb.has_vvar? && hint
          pp[2] = {Fixed.mulfix(pp[2][0], @x_scale), Fixed.mulfix(pp[2][1], @y_scale)}
          pp[3] = {Fixed.mulfix(pp[3][0], @x_scale), Fixed.mulfix(pp[3][1], @y_scale)}
        else
          pp[2] = {cur_x[n - 2], cur_y[n - 2]}
          pp[3] = {cur_x[n - 1], cur_y[n - 1]}
        end
      else
        pp[0] = {cur_x[n - 4], cur_y[n - 4]}
        pp[1] = {cur_x[n - 3], cur_y[n - 3]}
        pp[2] = {cur_x[n - 2], cur_y[n - 2]}
        pp[3] = {cur_x[n - 1], cur_y[n - 1]}
      end

      if hint
        hint_glyph(cur_x, cur_y, tags, contours, n, instructions,
                   is_composite: false, pp: pp,
                   zone_start: 0, orus_x: orus_x, orus_y: orus_y)
      end

      base = acc.n_points
      acc.xs.concat(cur_x[0, n_real])
      acc.ys.concat(cur_y[0, n_real])
      acc.tags.concat(tags[0, n_real])
      contours.each { |e| acc.contour_ends << e + base }
    end

    private def process_composite(g : CompositeGlyph, gid : Int32,
                                  pp : Array({Int64, Int64}),
                                  hint : Bool, acc : Acc, recurse : Int32,
                                  chain : Set(Int32)) : Nil
      start_point = acc.n_points

      # TT_Vary_Apply_Glyph_Deltas on the composite's own "outline": one
      # point per component (arg1/arg2, font units) plus the scaled
      # phantoms, with one single-point contour per component. The extra
      # offsets go into the components' translations (ttgload.c).
      if (blend = @blend) && @doblend
        limit = g.components.size
        xs = Array(Int64).new(limit + 4, 0_i64)
        ys = Array(Int64).new(limit + 4, 0_i64)
        g.components.each_with_index do |comp, i|
          xs[i] = comp.arg1.to_i64
          ys[i] = comp.arg2.to_i64
        end
        4.times do |i|
          xs[limit + i] = pp.unsafe_fetch(i)[0]
          ys[limit + i] = pp.unsafe_fetch(i)[1]
        end
        contours = Array(Int32).new(limit) { |i| i }
        d = blend.apply_glyph_deltas(gid, xs, ys, contours, @normalized,
                                     blend.has_hvar?, blend.has_vvar?)
        # write back the varied translations (font units, FT_Int16 cast;
        # anchor-point components ignore theirs — deltas are zero there)
        comps = g.components.map_with_index do |comp, i|
          if (comp.flags & ARGS_ARE_XY_VALUES) != 0
            TT::Component.new(comp.flags, comp.index,
                              (comp.arg1.to_i64 &+ d[:dx][i]).to_i16!.to_i32,
                              (comp.arg2.to_i64 &+ d[:dy][i]).to_i16!.to_i32,
                              comp.transform)
          else
            comp
          end
        end
        # phantoms: with HVAR/VVAR the deltas are zeroed, so this is a
        # no-op exactly when FreeType skips the write-back
        pp[0] = {xs[limit], ys[limit]}
        pp[1] = {xs[limit + 1], ys[limit + 1]}
        pp[2] = {xs[limit + 2], ys[limit + 2]}
        pp[3] = {xs[limit + 3], ys[limit + 3]}
      else
        comps = g.components
      end

      comps.each do |comp|
        pp_saved = pp.dup
        num_base_points = acc.n_points

        load_glyph_rec(comp.index, recurse + 1, hint, acc, chain)

        unless (comp.flags & USE_MY_METRICS) != 0
          4.times { |i| pp[i] = pp_saved[i] }
        end

        next if acc.n_points == num_base_points

        process_component(comp, acc, start_point, num_base_points, hint)
      end

      # TT_Process_Composite_Glyph.
      if hint && !g.instructions.empty? && acc.n_points > start_point
        n_real = acc.n_points
        n = n_real - start_point + 4

        cur_x = acc.xs[start_point..].dup
        cur_y = acc.ys[start_point..].dup
        cur_x << pp[0][0]; cur_y << pp[0][1]
        cur_x << pp[1][0]; cur_y << pp[1][1]
        cur_x << pp[2][0]; cur_y << pp[2][1]
        cur_x << pp[3][0]; cur_y << pp[3][1]
        tags = acc.tags[start_point..] + [0_u8, 0_u8, 0_u8, 0_u8]
        contours = acc.contour_ends.map { |e| e - start_point }
        contours = contours.select { |e| e >= 0 }

        # untouch all zone points
        (n - 4).times { |i| tags[i] &= ~0x18_u8 }

        hint_glyph(cur_x, cur_y, tags, contours, n, g.instructions,
                   is_composite: true, pp: pp,
                   zone_start: 0, orus_x: nil, orus_y: nil)

        # write the hinted points back (phantoms stay transient)
        (n_real - start_point).times do |i|
          acc.xs[start_point + i] = cur_x[i]
          acc.ys[start_point + i] = cur_y[i]
          acc.tags[start_point + i] = tags[i]
        end
      end
    end

    # TT_Process_Composite_Component: transform + offset of the freshly
    # appended component points.
    private def process_component(comp : Component, acc : Acc,
                                  start_point : Int32, num_base_points : Int32,
                                  hint : Bool) : Nil
      first = num_base_points
      count = acc.n_points - num_base_points

      have_scale = (comp.flags & (WE_HAVE_A_SCALE | WE_HAVE_AN_XY_SCALE | WE_HAVE_A_2X2)) != 0

      if have_scale
        m = comp.transform
        count.times do |i|
          k = first + i
          x = acc.xs[k]
          y = acc.ys[k]
          acc.xs[k] = Fixed.mulfix(x, m.xx) &+ Fixed.mulfix(y, m.xy)
          acc.ys[k] = Fixed.mulfix(x, m.yx) &+ Fixed.mulfix(y, m.yy)
        end
      end

      if (comp.flags & ARGS_ARE_XY_VALUES) == 0
        # point matching: l-th point of the new component onto the k-th
        # point of the previously loaded components
        k = comp.arg1 + start_point
        l = comp.arg2 + num_base_points
        if k >= num_base_points || l >= acc.n_points
          raise ParseError.new("invalid composite point matching")
        end
        x = acc.xs[k] &- acc.xs[l]
        y = acc.ys[k] &- acc.ys[l]
      else
        x = comp.arg1.to_i64
        y = comp.arg2.to_i64
      end

      return if x == 0 && y == 0

      # SCALED_COMPONENT_OFFSET (TT_CONFIG_OPTION_COMPONENT_OFFSET_SCALED
      # is #undef in the reference build).
      if have_scale && (comp.flags & SCALED_COMPONENT_OFFSET) != 0
        m = comp.transform
        mac_xscale = Fttrigon.hypot(m.xx, m.xy)
        mac_yscale = Fttrigon.hypot(m.yy, m.yx)
        x = Fixed.mulfix(x, mac_xscale)
        y = Fixed.mulfix(y, mac_yscale)
      end

      x = Fixed.mulfix(x, @x_scale)
      y = Fixed.mulfix(y, @y_scale)

      if (comp.flags & ROUND_XY_TO_GRID) != 0 && hint
        # v40 approximates native ClearType's fine horizontal grid by
        # leaving X offsets of components unrounded (grayscale mode,
        # non-tricky font).
        y = Fixed.pix_round(y)
      end

      return if x == 0 && y == 0

      count.times do |i|
        acc.xs[first + i] &+= x
        acc.ys[first + i] &+= y
      end
    end

    # TT_Hint_Glyph: `cur' covers n = zone points + 4 phantoms.
    private def hint_glyph(cur_x : Array(Int64), cur_y : Array(Int64),
                           tags : Array(UInt8), contours : Array(Int32),
                           n : Int32, instructions : Bytes,
                           is_composite : Bool, pp : Array({Int64, Int64}),
                           zone_start : Int32,
                           orus_x : Array(Int64)?, orus_y : Array(Int64)?) : Nil
      n_ins = instructions.size

      # org = copy of cur, taken BEFORE phantom rounding (scratch buffers).
      org_x = nil
      org_y = nil
      if n_ins > 0
        org_x = @scr_org_x
        org_y = @scr_org_y
        org_x.clear; org_x.concat(cur_x)
        org_y.clear; org_y.concat(cur_y)
      end

      if is_composite
        # instructions refer to the already-hinted, scaled subglyphs
        orus_x = @scr_orus_x
        orus_y = @scr_orus_y
        orus_x.clear; orus_x.concat(cur_x)
        orus_y.clear; orus_y.concat(cur_y)
      end

      # round phantom points
      cur_x[n - 4] = Fixed.pix_round(cur_x[n - 4])
      cur_x[n - 3] = Fixed.pix_round(cur_x[n - 3])
      cur_y[n - 2] = Fixed.pix_round(cur_y[n - 2])
      cur_y[n - 1] = Fixed.pix_round(cur_y[n - 1])

      if n_ins > 0
        vm_run_glyph(cur_x, cur_y, org_x, org_y, orus_x.not_nil!, orus_y.not_nil!,
                     tags, contours, n, is_composite, instructions)
        # store drop-out mode in bits 5-7; set bit 2 as a marker (ttgload.c
        # TT_Hint_Glyph).  Only visible for simple glyphs: the C loader
        # writes to `current.outline.tags[0]', which sits at the glyph's
        # first point for simple glyphs (hinted before FT_GlyphLoader_Add)
        # but one past the end for composites (all components already
        # added), where the write is effectively discarded.
        unless is_composite
          tags[0] |= ((@exec.graphics_state.scan_type.to_u8! << 5) | 0x04_u8)
        end
      end

      # v40 backward compatibility: no x movement means no reason to
      # change bearings or advance widths.
      return if @backward_compat

      pp[0] = {cur_x[n - 4], cur_y[n - 4]}
      pp[1] = {cur_x[n - 3], cur_y[n - 3]}
      pp[2] = {cur_x[n - 2], cur_y[n - 2]}
      pp[3] = {cur_x[n - 1], cur_y[n - 1]}
    end

    private def i16_of(d : Bytes, off : Int32) : Int32
      ((d[off].to_u16 << 8) | d[off + 1]).to_i16!.to_i32
    end

    # ------------------------------------------------------------------
    # VM adapter -- the only place that touches TT::ExecContext.  Kept
    # deliberately thin so it can follow the interpreter's API.
    # ------------------------------------------------------------------

    @exec : TT::ExecContext

    # Run a glyph program with the zone installed (TT_Set_CodeRange +
    # exec.pts = zone + TT_Run_Context with GS = size->GS).
    private def vm_run_glyph(cur_x, cur_y, org_x, org_y, orus_x, orus_y,
                             tags, contours, n, is_composite, code) : Nil
      exec = @exec
      # per-glyph reset: load_context (inside run) restores CVT/storage
      # from the exec's post-prep bases and the GS to the saved subset on
      # top of defaults (TT_Load_Context + TT_Run_Context)
      exec.graphics_state = vm_gs_from(@size_gs)
      # ttgload.c: v40 grayscale sets backward_compatibility from
      # instruct_control bit 2 before each glyph run.
      exec.backward_compatibility = ((@size_gs.instruct_control & 4) ^ 4).to_i32!
      exec.ppem = @px
      exec.scale_x = is_composite ? (1_i64 << 16) : @x_scale
      exec.scale_y = is_composite ? (1_i64 << 16) : @y_scale
      exec.set_zone(cur_x, cur_y, org_x, org_y, orus_x, orus_y,
                    tags, contours, n)
      exec.is_composite = is_composite
      exec.run(code)
    end

    private def vm_gs_from(gs : SizeGs)
      base = TT::GraphicsState.default
      base.minimum_distance = gs.minimum_distance
      base.control_value_cutin = gs.control_value_cutin
      base.single_width_cutin = gs.single_width_cutin
      base.single_width_value = gs.single_width_value
      base.delta_base = gs.delta_base
      base.delta_shift = gs.delta_shift
      base.auto_flip = gs.auto_flip
      base.instruct_control = gs.instruct_control
      base.scan_control = gs.scan_control
      base.scan_type = gs.scan_type
      base
    end

    private def vm_save_gs : SizeGs
      gs = SizeGs.new
      e = @exec.graphics_state
      gs.minimum_distance = e.minimum_distance
      gs.control_value_cutin = e.control_value_cutin
      gs.single_width_cutin = e.single_width_cutin
      gs.single_width_value = e.single_width_value
      gs.delta_base = e.delta_base
      gs.delta_shift = e.delta_shift
      gs.auto_flip = e.auto_flip
      gs.instruct_control = e.instruct_control
      gs.scan_control = e.scan_control
      gs.scan_type = e.scan_type
      gs
    end

    private def vm_cvt : Array(Int64)
      @exec.cvt
    end

    private def vm_storage : Array(Int64)
      @exec.storage
    end
  end
end

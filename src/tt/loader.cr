# TrueType hinted-glyph loading pipeline (B2): the port of
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
    @cvt_base : Array(Int64) = [] of Int64   # post-prep CVT (persistent)
    @storage_base : Array(Int64) = [] of Int64
    @fpgm_done = false
    @prep_px = -1
    @backward_compat = false
    @hinting_enabled = true # cleared when prep sets instruct_control bit 0

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

    def initialize(data : Bytes)
      # Copy the buffer: callers routinely pass a slice into a temporary
      # String (File.read(...).to_slice), which the GC may collect while
      # the face is alive — the parsed tables would silently go garbage
      # mid-run. Fonts are a few hundred KB; the copy is the cheap half
      # of this safety.
      @font = Font.new(data.dup)
      @exec = TT::ExecContext.new(
        font.max_functions,
        font.max_instruction_defs,
        font.max_storage,
        font.max_stack,
        font.max_twilight,
      )
    end

    def num_glyphs : Int32
      font.num_glyphs
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
      # VM contract mirrors C's face->cvt: raw font units shifted to 26.6.
      exec.cvt_raw = font.cvt.map { |v| v.to_i64 &* 64 }

      # --- `fpgm': once per face (tt_size_ready_bytecode).  C has size->cvt
      # scaled at this point; prep rescales from the raw table anyway.
      unless @fpgm_done
        exec.cvt = font.cvt.map { |v| Fixed.mulfix(v.to_i64, @tt_scale) }
        exec.run_fpgm(font.fpgm)
        @fpgm_done = true
      end

      # --- `prep': per size (tt_size_run_prep zeroes storage, scales the
      # CVT from cvt_raw, runs the program, saves the GS subset) ---
      exec.run_prep(font.prep)

      gs = vm_save_gs
      @cvt_base = exec.cvt_base.dup
      @storage_base = exec.storage_base.dup

      # tt_loader_init: instruct_control checks after prep.
      if (gs.instruct_control & 1) != 0
        @hinting_enabled = false
      else
        @hinting_enabled = true
      end
      if (gs.instruct_control & 2) != 0
        gs = SizeGs.new
      end
      # v40 backward compatibility (grayscale mode, non-tricky font).
      @backward_compat = (gs.instruct_control & 4) == 0

      @size_gs = gs
      @prep_px = px
    end

    def load_glyph(gid : Int32, hint : Bool = true) : LoadedGlyph
      raise "call set_pixel_size first" if @prep_px <= 0
      hinted_load = hint # FT flag state (grid-fit applies to it)
      hint = false unless @hinting_enabled

      acc = Acc.new # fresh per glyph: its arrays ship out in LoadedGlyph
      @chain.clear
      pp = load_glyph_rec(gid, 0, hint, acc, @chain)

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
        # empty glyph: scale phantom points (ttgload.c shortcut path)
        scale_pp(pp)
        chain.delete(gid)
        return pp
      end

      if n_contours > 0
        # simple glyph: phantoms are scaled together with the points in
        # TT_Process_Simple_Glyph -- pp stays in font units here
        process_simple(gid, pp, hint, acc)
      else
        # composite: scale phantom points (ttgload.c lines ~1795-1807)
        scale_pp(pp)
        g = font.composite_glyph(gid).not_nil!
        process_composite(g, pp, hint, acc, recurse, chain)
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

      # orus copy happens BEFORE scaling (font units) when hinted.
      orus_x = @scr_orus_x
      orus_y = @scr_orus_y
      orus_x.clear; orus_x.concat(cur_x)
      orus_y.clear; orus_y.concat(cur_y)

      n.times do |i|
        cur_x[i] = Fixed.mulfix(cur_x[i], @x_scale)
        cur_y[i] = Fixed.mulfix(cur_y[i], @y_scale)
      end

      tags = @scr_tags
      tags.clear
      tags.concat(@scr_glyf_tags)
      tags << 0_u8; tags << 0_u8; tags << 0_u8; tags << 0_u8
      contours = @scr_contours
      contours.clear; contours.concat(@scr_glyf_contours)

      pp[0] = {cur_x[n - 4], cur_y[n - 4]}
      pp[1] = {cur_x[n - 3], cur_y[n - 3]}
      pp[2] = {cur_x[n - 2], cur_y[n - 2]}
      pp[3] = {cur_x[n - 1], cur_y[n - 1]}

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

    private def process_composite(g : CompositeGlyph, pp : Array({Int64, Int64}),
                                  hint : Bool, acc : Acc, recurse : Int32,
                                  chain : Set(Int32)) : Nil
      start_point = acc.n_points

      g.components.each do |comp|
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

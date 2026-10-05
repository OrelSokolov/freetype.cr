# CFF-flavoured OTF face: SFNT glue (cmap/hmtx from tt/sfnt.cr) around
# the CFF table parser and the Type 2 interpreter — the port of
# `cff_slot_load' (cffgload.c) specialised to FT_LOAD_NO_HINTING with
# stem darkening disabled:
#
#   - the Adobe engine renders the glyph at the unhinted "unity" scale,
#     leaving font-unit coordinates;
#   - the advance comes from `hmtx' when the face has any (OTF always
#     does), else from the charstring width;
#   - a non-identity FontMatrix is applied (FT_Outline_Transform) before
#     the final FT_MulFix scaling by x_scale — same operation order as
#     cffgload.c (matrix, offset, scale).
#
# `cff_slot_load' (cffgload.c) in both modes: unhinted (the Adobe engine
# renders the glyph at the "unity" scale, leaving font-unit coordinates)
# and hinted (the interpreter renders into 26.6 device space directly
# through the hint maps of cffhints.cr; non-identity FontMatrix subfonts
# fall back to unhinted).

require "../tt/sfnt"
require "../tt/loader" # TT::LoadedGlyph
require "../tt/ttgxvar"
require "./cffload"
require "./cffinterp"

module CFF
  class Face
    getter font : TT::Font
    getter cff : Font

    @px : Int32 = 0
    @x_scale : Int64 = 0_i64
    @blend : TT::GXBlend?
    @doblend : Bool = false
    @design_coords : Array(Int64) = [] of Int64
    @normalized : Array(Int64) = [] of Int64
    @vstore : TT::ItemVarStore?

    def initialize(data : Bytes, face_index : Int32 = 0)
      # Same buffer-copy rationale as TT::HintedFace.
      @font = TT::Font.new(data.dup, face_index)
      raise ParseError.new("not a CFF-flavoured font (no 'CFF ' table)") \
        if @font.cff_table.empty?
      @cff = Font.new(@font.cff_table, @font.upem)

      # cff_font_load parses the CFF2 VariationStore unconditionally (a
      # u16 length precedes the ItemVariationStore); the axis-count cross
      # check happens per blend against the fvar axes.
      if @cff.cff2? && (off = @cff.top_font.vstore_offset) > 0
        @vstore = TT::ItemVarStore.load(@cff.data, off + 2, 0) rescue nil
      end
    end

    def num_glyphs : Int32
      @font.num_glyphs
    end

    def glyph_index(codepoint : Int32) : Int32
      @font.glyph_index(codepoint)
    end

    def set_pixel_size(px : Int32) : Nil
      @px = px
      @x_scale = Fixed.divfix(px.to_i64 << 6, @font.upem.to_i64)
    end

    def pixel_size : Int32
      @px
    end

    def x_scale : Int64
      @x_scale
    end

    # CFF faces scale both axes alike (no anisotropic size support).
    def y_scale : Int64
      @x_scale
    end

    # FT_Set_Var_Design_Coordinates for a CFF2 face: normalize the design
    # coordinates through `fvar'/`avar' and make the CFF2 VariationStore
    # available to the charstring interpreter's blend operator. A no-op
    # for CFF1 faces and static fonts.
    def set_var_design(coords : Array(Int64)) : Nil
      blend = (@blend ||= TT::GXBlend.from_font(@font) rescue nil)
      return if blend.nil?
      n = {coords.size, blend.num_axis}.min
      cs = Array(Int64).new(blend.num_axis, 0_i64)
      blend.num_axis.times do |i|
        cs[i] = i < n ? coords.unsafe_fetch(i) : blend.axis[i].default
      end
      @design_coords = cs
      @normalized = blend.to_normalized(cs)
      @doblend = true
      # The CFF2 Private DICTs blend their hinting entries through the
      # VariationStore (cff_blend_doBlend); FreeType re-parses them
      # whenever the blend vector changes.
      @cff.reblend_private_dicts(@vstore, @normalized)
      # tt_apply_mvar (ftmm.c runs the driver's metrics_adjust whenever
      # the coordinates change): re-apply the `MVAR' metric deltas.
      blend.load_mvar(@font)
      blend.apply_mvar(@font, cs, @normalized)
    end

    # The current design coordinates (empty for a static/unset face).
    def var_design_coords : Array(Int64)
      @design_coords.dup
    end

    # The FT_LOAD_NO_SCALE variant of the unhinted load — what the
    # auto-hinter feeds on: the font-unit outline (FontMatrix/offset
    # applied exactly as in the scaled unhinted path, minus the final
    # scaling) and the unscaled advance.
    def load_glyph_font_units(gid : Int32) : TT::LoadedGlyph
      builder = Builder.new
      subfont = @cff.subfont_for(gid)
      glyph_width = 0

      begin
        if entry = @cff.charstring(gid)
          interp = Interpreter.new(@cff, builder, subfont,
                                   blend_store: @vstore,
                                   ndv: @doblend ? @normalized : nil)
          glyph_width = interp.run(entry[0], entry[1], false, 0_i64, 0_i64)
          builder.close_contour
        end
      rescue ex : InterpError
        return TT::LoadedGlyph.new([] of Int64, [] of Int64, [] of UInt8,
                                   [] of Int32, 0_i64)
      end

      advance : Int64
      if @font.num_h_metrics > 0
        advance = @font.h_metrics(gid)[0].to_i64
      else
        advance = glyph_width.to_i64
      end

      xs = builder.xs
      ys = builder.ys

      # Apply the font matrix, if any.
      if subfont.matrix_xx != 0x1_0000 || subfont.matrix_yy != 0x1_0000 ||
         subfont.matrix_xy != 0 || subfont.matrix_yx != 0
        i = 0
        while i < xs.size
          x = xs[i]
          y = ys[i]
          xs[i] = Fixed.mulfix(x, subfont.matrix_xx) &+
                  Fixed.mulfix(y, subfont.matrix_xy)
          ys[i] = Fixed.mulfix(x, subfont.matrix_yx) &+
                  Fixed.mulfix(y, subfont.matrix_yy)
          i += 1
        end
        advance = Fixed.mulfix(advance, subfont.matrix_xx)
      end

      if subfont.offset_x != 0 || subfont.offset_y != 0
        i = 0
        while i < xs.size
          xs[i] &+= subfont.offset_x
          ys[i] &+= subfont.offset_y
          i += 1
        end
        advance &+= subfont.offset_x
      end

      TT::LoadedGlyph.new(xs, ys, builder.tags, builder.contours, advance)
    end

    # An unhinted glyph at the current pixel size, shaped like
    # TT::LoadedGlyph: 26.6 outline at the glyph origin and the 26.6
    # horizontal advance (what FT_Load_Glyph leaves in the slot).
    # `hint: true` runs the ported Adobe hinting engine (pshints/psblues,
    # no stem darkening — the FT 2.7+ default): the interpreter renders
    # directly into 26.6 device space, so no matrix/scale pass follows.
    # Non-identity FontMatrix subfonts fall back to the unhinted path
    # (cffgload applies the matrix around the engine; not ported yet).
    def load_glyph(gid : Int32, hint : Bool = false) : TT::LoadedGlyph
      builder = Builder.new
      subfont = @cff.subfont_for(gid)
      x_scale = @x_scale

      # CID fonts may carry a subfont units-per-em different from the
      # top dict's: cff_slot_load folds the ratio into the scale.
      if @cff.subfonts.size > 0
        top_upm = @cff.top_font.units_per_em
        sub_upm = subfont.units_per_em
        if top_upm != sub_upm
          x_scale = Fixed.muldiv(x_scale, top_upm, sub_upm)
        end
      end

      identity_matrix = subfont.matrix_xx == 0x1_0000 &&
                        subfont.matrix_yy == 0x1_0000 &&
                        subfont.matrix_xy == 0 && subfont.matrix_yx == 0 &&
                        subfont.offset_x == 0 && subfont.offset_y == 0
      hinted = hint && identity_matrix

      glyph_width = 0
      begin
        if entry = @cff.charstring(gid)
          if hinted
            # cf2_getScaleAndHintFlag: (x_scale + 32) / 64 — the Adobe
            # engine then emits 26.6 device space directly.
            hint_scale = (x_scale &+ 32) // 64
            interp = Interpreter.new(@cff, builder, subfont, true, hint_scale,
                                     blend_store: @vstore,
                                     ndv: @doblend ? @normalized : nil)
          else
            interp = Interpreter.new(@cff, builder, subfont,
                                     blend_store: @vstore,
                                     ndv: @doblend ? @normalized : nil)
          end
          glyph_width = interp.run(entry[0], entry[1], false, 0_i64, 0_i64)
          # cf2_outline_close: one final close of the last contour (the
          # earlier ones are closed by the next subpath's moveTo).
          builder.close_contour
        end
      rescue ex : InterpError
        # FreeType fails the load and leaves an empty glyph slot.
        return TT::LoadedGlyph.new([] of Int64, [] of Int64, [] of UInt8,
                                   [] of Int32, 0_i64)
      end

      # Now set the metrics (cffgload.c): the advance comes from hmtx,
      # adjusted by `HVAR' for a variation instance (the CFF driver uses
      # the same sfnt metrics-variations service as the TrueType one).
      advance : Int64
      if @font.num_h_metrics > 0
        advance = @font.h_metrics(gid)[0].to_i64
      else
        advance = glyph_width.to_i64
      end
      if (blend = @blend) && @doblend && blend.has_hvar?
        advance &+= blend.advance_delta(gid, @normalized)
      end

      xs = builder.xs
      ys = builder.ys

      if hinted
        # The outline is already in 26.6 device space; the advance is
        # grid-fitted like the hinted slot (ft_glyphslot_grid_fit).
        advance = Fixed.mulfix(advance, x_scale)
        advance = (advance &+ 32) & ~63_i64
        return TT::LoadedGlyph.new(xs, ys, builder.tags, builder.contours,
                                   advance)
      end

      # Apply the font matrix, if any.
      if subfont.matrix_xx != 0x1_0000 || subfont.matrix_yy != 0x1_0000 ||
         subfont.matrix_xy != 0 || subfont.matrix_yx != 0
        i = 0
        while i < xs.size
          x = xs[i]
          y = ys[i]
          xs[i] = Fixed.mulfix(x, subfont.matrix_xx) &+
                  Fixed.mulfix(y, subfont.matrix_xy)
          ys[i] = Fixed.mulfix(x, subfont.matrix_yx) &+
                  Fixed.mulfix(y, subfont.matrix_yy)
          i += 1
        end
        advance = Fixed.mulfix(advance, subfont.matrix_xx)
      end

      if subfont.offset_x != 0 || subfont.offset_y != 0
        i = 0
        while i < xs.size
          xs[i] &+= subfont.offset_x
          ys[i] &+= subfont.offset_y
          i += 1
        end
        advance &+= subfont.offset_x
      end

      # Scale the outline and the advance.
      i = 0
      while i < xs.size
        xs[i] = Fixed.mulfix(xs[i], x_scale)
        ys[i] = Fixed.mulfix(ys[i], x_scale)
        i += 1
      end
      advance = Fixed.mulfix(advance, x_scale)

      TT::LoadedGlyph.new(xs, ys, builder.tags, builder.contours, advance)
    end
  end
end

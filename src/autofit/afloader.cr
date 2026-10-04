# afloader.cr — the `af_loader_load_glyph' glue (afloader.c) on top of
# the TT unhinted path: per-face style globals, per-style metrics
# scaling, the auto-hint pass itself, and the afloader metrics fixups
# (pp1/pp2 phantom handling and the hinted advance). The render mode is
# FT_RENDER_MODE_NORMAL (the acceptance scope).
require "./afglobal"
require "./aflatin"
require "../tt/loader"
require "../cff/face"

module Autofit
  # The face surface the auto-hinter loader works on — implemented by
  # TT::HintedFace and CFF::Face (the unhinted, unscaled glyph load is
  # what FT_Load_Glyph with NO_SCALE hands to af_loader_load_glyph).
  module AutohintFace
    abstract def font : TT::Font
    abstract def x_scale : Int64
    abstract def y_scale : Int64
    abstract def pixel_size : Int32
    abstract def set_pixel_size(px : Int32) : Nil
    abstract def load_glyph_font_units(gid : Int32) : TT::LoadedGlyph
  end

  # FontFaceAdapter over the TT/CFF face (no harfbuzz: single-character
  # clusters only).
  class TTAdapter
    include FontFaceAdapter

    def initialize(@face : AutohintFace, @font : TT::Font)
    end

    def glyph_index(codepoint : Int32) : Int32
      @font.glyph_index(codepoint)
    end

    def load_unscaled(gid : Int32) : {Array(Int64), Array(Int64), Array(UInt8), Array(Int32)}?
      g = @face.load_glyph_font_units(gid)
      {g.xs, g.ys, g.tags, g.contours}
    end
    def advance_unscaled(gid : Int32) : Int64
      @font.h_metrics(gid)[0].to_i64!
    end

    def italic? : Bool
      # sfobjs.c: OS/2 fsSelection bit 9 (oblique) or bit 0 (italic);
      # without an OS/2 table, head.macStyle bit 1.
      if @font.os2_version != 0xFFFF_u16
        (@font.os2_fs_selection & (0x200_u16 | 0x1_u16)) != 0
      else
        (@font.mac_style & 0x2_u16) != 0
      end
    end
  end

  class Loader
    getter face_globals : FaceGlobals

    @font : TT::Font

    def initialize(@face : AutohintFace)
      @font = @face.font
      @adapter = TTAdapter.new(@face, @font)
      @face_globals = FaceGlobals.new(@adapter, @font.num_glyphs, @font.upem)
      @hints = GlyphHints.new
    end

    def load_glyph(gid : Int32) : TT::LoadedGlyph
      globals = @face_globals
      metrics = globals.get_metrics(gid)

      # af_loader_reset + af_latin_metrics_scale (render mode NORMAL)
      metrics.scale(@face.x_scale, @face.y_scale, 0, 0, @face.pixel_size)

      # FT_Load_Glyph with NO_SCALE | IGNORE_TRANSFORM | LINEAR_DESIGN
      g = @face.load_glyph_font_units(gid)
      xs = g.xs
      ys = g.ys
      tags = g.tags
      contours = g.contours

      # hints->x_scale (post-scale-dim value for the dummy system)
      h_scale = metrics.dummy ? metrics.x_scale : metrics.axis[DIMENSION_HORZ].scale

      pp1x = 0_i64
      pp2x = Fixed.mulfix(g.advance, h_scale)

      unless xs.empty?
        nonbase = (globals.glyph_styles[gid] & NONBASE) != 0
        if metrics.is_a?(CjkMetrics)
          # af_cjk_hints_apply: no nonbase/italic handling
          Cjk.apply(@hints, metrics, xs, ys, tags, contours)
        else
          Latin.apply(@hints, metrics, gid, nonbase, @adapter.italic?,
                      xs, ys, tags, contours)
        end
      end

      # adjust the metrics for the hinting (af_loader_load_glyph; the
      # render mode is NORMAL, so AF_HINTS_DO_ADVANCE holds unless the
      # CJK writing system set AF_SCALER_FLAG_NO_ADVANCE). An empty
      # outline skips this entirely (`goto Hint_Metrics' in afloader.c):
      # the edge table is stale then (apply never ran for this glyph).
      hax = @hints.axis[DIMENSION_HORZ]
      no_advance = @hints.scaler_flags & SCALER_FLAG_NO_ADVANCE != 0
      if !xs.empty? && !no_advance && hax.edges.size > 1
        edge1 = hax.edges.first
        edge2 = hax.edges.last

        old_rsb = pp2x &- edge2.opos
        old_lsb = edge1.opos
        new_lsb = edge1.pos

        # remember unhinted values to account for rounding errors
        pp1x_uh = new_lsb &- old_lsb
        pp2x_uh = edge2.pos &+ old_rsb

        # prefer too much space over too little for very small sizes
        pp1x_uh &-= 8 if old_lsb < 24
        pp2x_uh &+= 8 if old_rsb < 24

        pp1x = Fixed.pix_round(pp1x_uh)
        pp2x = Fixed.pix_round(pp2x_uh)

        pp1x &-= 64 if pp1x >= new_lsb && old_lsb > 0
        pp2x &+= 64 if pp2x <= edge2.pos && old_rsb > 0
      else
        pp1x = Fixed.pix_round(pp1x)
        pp2x = Fixed.pix_round(pp2x)
      end

      # Hint_Metrics: translate by -pp1.x and derive the final advance
      if pp1x != 0
        xs.map! { |x| x &- pp1x }
      end

      if @font.is_fixed_pitch ||
         (globals.is_digit?(gid) && metrics.digits_have_same_width)
        advance = Fixed.pix_round(Fixed.mulfix(g.advance, h_scale))
      else
        # non-spacing glyphs stay as-is
        advance = g.advance != 0 ? pp2x &- pp1x : 0_i64
        advance = Fixed.pix_round(advance)
      end

      TT::LoadedGlyph.new(xs, ys, tags, contours, advance)
    end
  end

  # The auto-hinter hooks (see TT::HintedFace#load_glyph): each face
  # class builds its loader lazily, once per face.
  class ::TT::HintedFace
    include Autofit::AutohintFace

    def load_glyph_autohint(gid : Int32) : TT::LoadedGlyph?
      ah = @autohint
      if ah.nil?
        ah = Autofit::Loader.new(self)
        @autohint = ah
      end
      ah.load_glyph(gid)
    end

    @autohint : Autofit::Loader? = nil
  end

  # CFF faces reach the auto-hinter the way FT_LOAD_FORCE_AUTOHINT does
  # in FreeType (the CFF driver's own hinter otherwise wins).
  class ::CFF::Face
    include Autofit::AutohintFace

    def load_glyph_autohint(gid : Int32) : TT::LoadedGlyph?
      ah = @autohint
      if ah.nil?
        ah = Autofit::Loader.new(self)
        @autohint = ah
      end
      ah.load_glyph(gid)
    end

    @autohint : Autofit::Loader? = nil
  end
end

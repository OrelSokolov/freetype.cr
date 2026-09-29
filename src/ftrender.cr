# Crystal port of the FreeType "smooth" render glue that sits between a
# loaded FT_Outline and the ftgrays rasterizer (~/freetype/src/smooth/
# ftsmooth.c `ft_smooth_render` + src/base/ftobjs.c
# `ft_glyphslot_preset_bitmap`, FT_RENDER_MODE_NORMAL path):
#
#   1. control box of the (26.6) outline — min/max over all points;
#   2. pixel box: floor on the min edges, ceil on the max edges
#      (`Adjust` rounding in ft_glyphslot_preset_bitmap);
#   3. translate the outline by (-64*left, 64*(rows - top)) so the pixel
#      box lands at the bitmap origin;
#   4. rasterize into a top-down 8-bit coverage bitmap.
#
# Together with Ftgrays this is the complete FT_LOAD_RENDER (gray)
# pipeline for an unhinted outline; bit-exact against FreeType.
#
# Overlap handling (FT_OUTLINE_OVERLAP) and the LCD paths are not ported:
# glyph baking uses the plain NORMAL path only.

require "./ftgrays"

module Ftrender
  # A rasterized glyph: pixel placement relative to the pen (left = bearing
  # of the bitmap's left column, top = baseline row of the bitmap's top
  # row, y up) plus the top-down 8-bit coverage bitmap (stride = width).
  struct GlyphBitmap
    getter width : Int32
    getter height : Int32
    getter left : Int32
    getter top : Int32
    getter buffer : Bytes

    def initialize(@width : Int32, @height : Int32, @left : Int32, @top : Int32,
                   @buffer : Bytes)
    end

    def self.blank : GlyphBitmap
      new(0, 0, 0, 0, Bytes.new(0))
    end
  end

  # Rasterizer reused across glyphs (its cell rows warm up and stop
  # allocating after the first few renders). NOT thread-safe — the
  # glyph bake is single-threaded per face in both freetype-cr and the
  # egui backend; concurrent bakes would need their own Raster.
  @@raster = Ftgrays::Raster.new

  # FT_RENDER_MODE_NORMAL equivalent for a 26.6 outline (y up).
  def self.render_glyph(outline : Ftgrays::Outline) : GlyphBitmap
    return GlyphBitmap.blank if outline.xs.empty? || outline.contours.empty?

    # FT_Outline_Get_CBox: control box over every point.
    x_min = outline.xs.min
    x_max = outline.xs.max
    y_min = outline.ys.min
    y_max = outline.ys.max

    # ft_glyphslot_preset_bitmap, Adjust: floor on min, ceil on max
    # (arithmetic shifts; the remainders are the low 6 bits of 26.6).
    # NB: explicit parens — `>>` binds looser than `+` in Crystal.
    px_min = x_min >> 6
    px_max = (x_max >> 6) + (((x_max & 63) + 63) >> 6)
    py_min = y_min >> 6
    py_max = (y_max >> 6) + (((y_max & 63) + 63) >> 6)

    width = (px_max - px_min).to_i32!
    height = (py_max - py_min).to_i32!
    return GlyphBitmap.blank if width <= 0 || height <= 0

    left = px_min.to_i32!
    top = py_max.to_i32!

    # ft_smooth_render translation: origin at the bitmap's bottom-left.
    x_shift = -64_i64 &* left
    y_shift = 64_i64 &* height &- 64_i64 &* top

    buffer = @@raster.render(outline, width, height, x_shift, y_shift)
    GlyphBitmap.new(width, height, left, top, buffer)
  end
end

# Crystal port of the FreeType "smooth" render glue that sits between a
# loaded FT_Outline and the ftgrays rasterizer (~/freetype/src/smooth/
# ftsmooth.c `ft_smooth_render` + src/base/ftobjs.c
# `ft_glyphslot_preset_bitmap`):
#
#   1. control box of the (26.6) outline — min/max over all points;
#   2. pixel box: floor on the min edges, ceil on the max edges
#      (`Adjust` rounding in ft_glyphslot_preset_bitmap);
#   3. translate the outline by (-64*left, 64*(rows - top)) so the pixel
#      box lands at the bitmap origin;
#   4. rasterize into a top-down 8-bit coverage bitmap.
#
# FT_RENDER_MODE_NORMAL is the plain path (bit-exact against FreeType).
# The subpixel modes are the FT_CONFIG_OPTION_SUBPIXEL_RENDERING build
# of FreeType 2.13 (what Debian/Ubuntu ship): FT_RENDER_MODE_LCD/LCD_V
# implode the outline by 3 on the respective axis, render 8-bit
# coverage, then run the default five-tap FIR filter
# {0x08,0x4D,0x56,0x4D,0x08} in place (ftlcdil.c `ft_lcd_filter_fir`);
# the cbox is padded by 43 subpixels (ft_lcd_padding) on both ends of
# the filtered axis so the filter has room.
#
# FT_RENDER_MODE_MONO is routed to the black rasterizer port
# (ftraster1.cr) and packed MSB-first like FreeType's mono bitmaps.

require "./ftgrays"
require "./ftraster1"

module Ftrender
  # Render mode: the FT_Render_Mode subset the pipeline supports.
  enum Mode
    Normal # FT_RENDER_MODE_NORMAL (8-bit coverage)
    Lcd    # FT_RENDER_MODE_LCD (3 subpixels per pixel, horizontally)
    LcdV   # FT_RENDER_MODE_LCD_V (3 subpixels per pixel, vertically)
    Mono   # FT_RENDER_MODE_MONO (1-bit, MSB-first packed)
  end

  # A rasterized glyph: pixel placement relative to the pen (left = bearing
  # of the bitmap's left column, top = baseline row of the bitmap's top
  # row, y up) plus the bitmap. For Normal/Lcd/LcdV the buffer is 8-bit
  # coverage, top-down, stride = width (for the subpixel modes width is
  # the padded triplicated width — RGB triplets after filtering). For
  # Mono the buffer is packed 1 bit per pixel, MSB first, top-down, one
  # row per `pitch` bytes.
  struct GlyphBitmap
    getter width : Int32
    getter height : Int32
    getter left : Int32
    getter top : Int32
    getter buffer : Bytes
    getter pitch : Int32
    getter mode : Mode

    def initialize(@width : Int32, @height : Int32, @left : Int32, @top : Int32,
                   @buffer : Bytes, @mode : Mode = Mode::Normal)
      @pitch = @width == 0 ? 0 : (@mode.mono? ? ((@width + 15) >> 4) << 1 : @width)
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

  # Default LCD filter weights (FT_Library_SetLcdFilter DEFAULT,
  # ftlcdfil.c). Non-zero end taps mean the ft_lcd_padding widening is
  # the full 43 subpixels on each side.
  LCD_WEIGHTS = {0x08_u32, 0x4D_u32, 0x56_u32, 0x4D_u32, 0x08_u32}

  # FT_RENDER_MODE_NORMAL equivalent for a 26.6 outline (y up).
  def self.render_glyph(outline : Ftgrays::Outline, mode : Mode = Mode::Normal) : GlyphBitmap
    return GlyphBitmap.blank if outline.xs.empty? || outline.contours.empty?

    case mode
    when .normal? then render_normal(outline)
    when .lcd?    then render_lcd(outline)
    when .lcd_v?  then render_lcdv(outline)
    when .mono?   then render_mono(outline)
    else                raise ArgumentError.new("unsupported render mode")
    end
  end

  private def self.preset_adjust(x_min, x_max, y_min, y_max)
    # ft_glyphslot_preset_bitmap, Adjust: floor on min, ceil on max
    # (arithmetic shifts; the remainders are the low 6 bits of 26.6).
    # NB: explicit parens — `>>` binds looser than `+` in Crystal.
    px_min = x_min >> 6
    px_max = (x_max >> 6) + (((x_max & 63) + 63) >> 6)
    py_min = y_min >> 6
    py_max = (y_max >> 6) + (((y_max & 63) + 63) >> 6)
    {px_min, px_max, py_min, py_max}
  end

  private def self.render_normal(outline : Ftgrays::Outline) : GlyphBitmap
    px_min, px_max, py_min, py_max =
      preset_adjust(outline.xs.min, outline.xs.max, outline.ys.min, outline.ys.max)

    width = (px_max - px_min).to_i32!
    height = (py_max - py_min).to_i32!
    return GlyphBitmap.blank if width <= 0 || height <= 0

    left = px_min.to_i32!
    top = py_max.to_i32!

    # ft_smooth_render translation: origin at the bitmap's bottom-left.
    tx = -64_i64 &* left
    ty = 64_i64 &* height &- 64_i64 &* top

    buffer = @@raster.render(outline, width, height, tx, ty)
    GlyphBitmap.new(width, height, left, top, buffer)
  end

  private def self.render_lcd(outline : Ftgrays::Outline) : GlyphBitmap
    # ft_lcd_padding widens the filtered axis by 43 subpixels per side
    # (the default weights have non-zero end taps).
    x_min = outline.xs.min &- 43
    x_max = outline.xs.max &+ 43
    px_min, px_max, py_min, py_max =
      preset_adjust(x_min, x_max, outline.ys.min, outline.ys.max)

    width = (px_max - px_min).to_i32!    # logical pixels
    height = (py_max - py_min).to_i32!
    return GlyphBitmap.blank if width <= 0 || height <= 0

    left = px_min.to_i32!
    top = py_max.to_i32!
    width3 = width &* 3

    # ft_smooth_raster_lcd (SUBPIXEL build): implode x by 3 — the
    # pre-translation (x + tx)*3 equals x*3 + 3*tx.
    xs3 = outline.xs.map { |x| x &* 3 }
    outline3 = Ftgrays::Outline.new(xs3, outline.ys, outline.tags,
                                    outline.contours, outline.flags)
    tx = -64_i64 &* left &* 3
    ty = 64_i64 &* height &- 64_i64 &* top

    buffer = @@raster.render(outline3, width3, height, tx, ty)
    lcd_filter_fir_h(buffer, width3, height)
    GlyphBitmap.new(width3, height, left, top, buffer, Mode::Lcd)
  end

  private def self.render_lcdv(outline : Ftgrays::Outline) : GlyphBitmap
    y_min = outline.ys.min &- 43
    y_max = outline.ys.max &+ 43
    px_min, px_max, py_min, py_max =
      preset_adjust(outline.xs.min, outline.xs.max, y_min, y_max)

    width = (px_max - px_min).to_i32!
    height = (py_max - py_min).to_i32! # logical pixels
    return GlyphBitmap.blank if width <= 0 || height <= 0

    left = px_min.to_i32!
    top = py_max.to_i32!
    height3 = height &* 3

    # ft_smooth_raster_lcdv: implode y by 3. The y translation is the
    # NORMAL one computed from the LOGICAL height (rows/3 in
    # ft_smooth_render because preset already tripled bitmap->rows).
    ys3 = outline.ys.map { |y| y &* 3 }
    outline3 = Ftgrays::Outline.new(outline.xs, ys3, outline.tags,
                                    outline.contours, outline.flags)
    tx = -64_i64 &* left
    ty = (64_i64 &* height &- 64_i64 &* top) &* 3

    buffer = @@raster.render(outline3, width, height3, tx, ty)
    lcd_filter_fir_v(buffer, width, height3)
    GlyphBitmap.new(width, height3, left, top, buffer, Mode::LcdV)
  end

  private def self.render_mono(outline : Ftgrays::Outline) : GlyphBitmap
    # ft_glyphslot_preset_bitmap MONO branch: asymmetric rounding so the
    # pixel center is always included, plus the collapsed-bbox fixup.
    x_min = outline.xs.min
    x_max = outline.xs.max
    y_min = outline.ys.min
    y_max = outline.ys.max

    # the tiny remainder box: same (x & 63) subpixel extraction
    px_min = (x_min >> 6) + ((x_min & 63) + 31 >> 6)
    px_max = (x_max >> 6) + ((x_max & 63) + 32 >> 6)
    if px_min == px_max
      if ((x_min & 63) + 31 & 63) - 31 + (((x_max & 63) + 32 & 63) - 32) < 0
        px_min -= 1
      else
        px_max += 1
      end
    end

    py_min = (y_min >> 6) + ((y_min & 63) + 31 >> 6)
    py_max = (y_max >> 6) + ((y_max & 63) + 32 >> 6)
    if py_min == py_max
      if ((y_min & 63) + 31 & 63) - 31 + (((y_max & 63) + 32 & 63) - 32) < 0
        py_min -= 1
      else
        py_max += 1
      end
    end

    width = (px_max - px_min).to_i32!
    height = (py_max - py_min).to_i32!
    return GlyphBitmap.blank if width <= 0 || height <= 0

    left = px_min.to_i32!
    top = py_max.to_i32!

    tx = -64_i64 &* left
    ty = 64_i64 &* height &- 64_i64 &* top

    buffer = Ftraster1.render(outline, width, height, tx, ty)
    GlyphBitmap.new(width, height, left, top, buffer, Mode::Mono)
  end

  # --- ft_lcd_filter_fir (ftlcdfil.c), in place -------------------------

  private def self.shift_clamp(x : UInt32) : UInt8
    x >>= 8
    x > 255 ? 255_u8 : x.to_u8!
  end

  # Horizontal pass over a top-down buffer (stride = width), bottom-up
  # like FreeType (the direction does not change the result — each line
  # is filtered left to right independently).
  private def self.lcd_filter_fir_h(buf : Bytes, width : Int32, height : Int32) : Nil
    return if width < 2
    w = LCD_WEIGHTS

    height.times do |r|
      line = r &* width
      val = buf[line].to_u32
      fir2 = w[2] &* val
      fir3 = w[3] &* val
      fir4 = w[4] &* val

      val = buf[line &+ 1].to_u32
      fir1 = fir2 &+ w[1] &* val
      fir2 = fir3 &+ w[2] &* val
      fir3 = fir4 &+ w[3] &* val
      fir4 = w[4] &* val

      xx = 2
      while xx < width
        val = buf[line &+ xx].to_u32
        fir0 = fir1 &+ w[0] &* val
        fir1 = fir2 &+ w[1] &* val
        fir2 = fir3 &+ w[2] &* val
        fir3 = fir4 &+ w[3] &* val
        fir4 = w[4] &* val

        buf[line &+ xx &- 2] = shift_clamp(fir0)
        xx += 1
      end

      buf[line &+ xx &- 2] = shift_clamp(fir1)
      buf[line &+ xx &- 1] = shift_clamp(fir2)
    end
  end

  # Vertical pass over a top-down buffer (stride = width). FreeType
  # walks from the bottom row upward, writing two rows above the read
  # head; mirrored here on the top-down layout (r counts down).
  private def self.lcd_filter_fir_v(buf : Bytes, width : Int32, height : Int32) : Nil
    return if height < 2
    w = LCD_WEIGHTS

    width.times do |c|
      # `col` = row index of the read head; starts at the bottom row.
      col = height &- 1
      val = buf[col &* width &+ c].to_u32
      fir2 = w[2] &* val
      fir3 = w[3] &* val
      fir4 = w[4] &* val

      col -= 1
      val = buf[col &* width &+ c].to_u32
      fir1 = fir2 &+ w[1] &* val
      fir2 = fir3 &+ w[2] &* val
      fir3 = fir4 &+ w[3] &* val
      fir4 = w[4] &* val

      col -= 1
      while col >= 0
        val = buf[col &* width &+ c].to_u32
        fir0 = fir1 &+ w[0] &* val
        fir1 = fir2 &+ w[1] &* val
        fir2 = fir3 &+ w[2] &* val
        fir3 = fir4 &+ w[3] &* val
        fir4 = w[4] &* val

        # C writes to col[pitch*2] relative to the CURRENT (post-decrement)
        # position, i.e. two rows below the value just read.
        buf[(col &+ 2) &* width &+ c] = shift_clamp(fir0)
        col -= 1
      end

      buf[(col &+ 2) &* width &+ c] = shift_clamp(fir1)
      buf[(col &+ 1) &* width &+ c] = shift_clamp(fir2)
    end
  end
end

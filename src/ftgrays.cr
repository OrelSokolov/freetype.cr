# Crystal port of FreeType's `ftgrays.c` scan-converter (snapshot 2.14.3,
# ~/freetype/src/smooth/ftgrays.c): the "perfect" anti-aliasing renderer
# that computes the exact per-pixel coverage of an outline by straight
# segments. Bézier arcs are flattened first — conics by a 64-bit DDA,
# cubics by adaptive bisection — exactly like the C original.
#
# Bit-exactness rules carried over from the C code:
#
#   * all hot-path arithmetic uses wrapping ops (&+ &- &*), C semantics;
#   * `>>` is an arithmetic shift (same as gcc/clang on signed ints);
#   * `/ 2` in outline decomposition is C integer division — truncation
#     toward zero (`tdiv`), NOT floor;
#   * the slanted-line fast division replicates FT_UDIVPREP/FT_UDIV
#     (multiply by 0xFFFFFFFF/divisor, shift right by 32);
#   * cells left of the clip region collapse onto x = min_ex - 1 and take
#     part in the coverage run, but are never written as pixels;
#   * the fill rule keeps FreeType's trickery: for the non-zero rule the
#     sign bit flips the coverage and clamps at 255, for even-odd bit 8
#     flips it and the byte store truncates higher bits.
#
# The C render pool / band bisection is replaced by dynamically grown
# per-row cell arrays: cells integrate exact areas per pixel row, so the
# sweep result does not depend on how rows were banded.
#
# Input coordinates are 26.6 fixed point (FT outline convention), y up;
# `tx`/`ty` are 26.6 translations folded into the upscale. The output is
# a top-down 8-bit coverage bitmap with stride = width.

module Ftgrays
  PIXEL_BITS = 8
  ONE_PIXEL  = 1 << PIXEL_BITS # 256 subpixel units per pixel

  FT_OUTLINE_EVEN_ODD_FILL = 0x2

  alias TPos    = Int64 # subpixel coordinate (1/256 px internally)
  alias TCoord  = Int32 # integer scanline/pixel coordinate
  alias TArea   = Int32 # cell areas, coordinate products

  # FT_CURVE_TAG values (tags[i] & 3).
  TAG_ON    = 1
  TAG_CONIC = 0
  TAG_CUBIC = 2

  # A glyph outline in 26.6 fixed point, y up: the FT_Outline subset the
  # rasterizer consumes.
  class Outline
    getter xs : Array(Int64)
    getter ys : Array(Int64)
    getter tags : Array(UInt8)
    getter contours : Array(Int32) # index of each contour's last point
    getter flags : Int32

    def initialize(@xs : Array(Int64), @ys : Array(Int64),
                   @tags : Array(UInt8), @contours : Array(Int32),
                   @flags : Int32 = 0)
    end
  end

  # One coverage cell: exact area accumulated inside pixel (x, ey).
  private class Cell
    property x : TCoord
    property cover : TArea = 0
    property area : TArea = 0

    def initialize(@x : TCoord)
    end
  end

  class Raster
    # Debug: when set, render_line calls are recorded here (test tooling).
    class_property lines_log : Array(String)? = nil
    class_property conic_log : Array(String)? = nil

    @buf : Bytes = Bytes.new(0)
    @width : Int32 = 0
    @height : Int32 = 0
    @min_ex : Int32 = 0
    @min_ey : Int32 = 0
    @max_ex : Int32 = 0
    @max_ey : Int32 = 0
    @ycells : Array(Array(Cell)) = [] of Array(Cell)
    @x : TPos = 0
    @y : TPos = 0
    @cell : Cell? = nil
    @tx : Int64 = 0 # 26.6 translation folded into the upscale
    @ty : Int64 = 0

    # Rasterize `outline` clipped to [0,width) x [0,height), after the
    # 26.6 translation (tx, ty). Returns a top-down coverage bitmap.
    def render(outline : Outline, width : Int32, height : Int32,
               tx : Int64 = 0, ty : Int64 = 0) : Bytes
      buf = Bytes.new(width * height)
      return buf if width <= 0 || height <= 0
      return buf if outline.contours.empty? || outline.xs.empty?
      unless outline.xs.size == outline.contours.last + 1
        raise ArgumentError.new("invalid outline: n_points != contours[-1] + 1")
      end

      @buf = buf
      @width = width
      @height = height
      @min_ex = 0
      @min_ey = 0
      @max_ex = width
      @max_ey = height
      @ycells = Array(Array(Cell)).new(height) { [] of Cell }
      @x = 0
      @y = 0
      @cell = nil
      @tx = tx
      @ty = ty

      decompose(outline)
      sweep(outline)
      buf
    end

    # --- FT_Outline_Decompose (ftoutln.c, shift = 0, delta = 0) ----------

    # --- FT_Outline_Decompose (ftoutln.c, shift = 0, delta = 0) ----------
    #
    # The 26.6 translation (tx, ty) is applied when points are READ here —
    # matching FT_Outline_Translate running BEFORE the decomposition, so
    # the v_start/v_middle midpoints round on the translated coordinates
    # ((a + b) / 2 in C truncates toward zero; tdiv replicates it).

    private def decompose(o : Outline) : Nil
      last = -1
      o.contours.each do |contour_end|
        first = last + 1
        last = contour_end
        raise ArgumentError.new("invalid outline: empty contour") if last < first

        limit = last
        v_start_x = o.xs[first] &+ @tx
        v_start_y = o.ys[first] &+ @ty
        v_last_x = o.xs[last] &+ @tx
        v_last_y = o.ys[last] &+ @ty
        vc_x = v_start_x
        vc_y = v_start_y

        i = first
        tag = o.tags[first] & 3
        # A contour cannot start with a cubic control point!
        raise ArgumentError.new("invalid outline: cubic at contour start") if tag == TAG_CUBIC

        closed = false
        if tag == TAG_CONIC
          # First point is conic control. Yes, this happens.
          if (o.tags[last] & 3) == TAG_ON
            # Start at the last point if it is on the curve.
            v_start_x = v_last_x
            v_start_y = v_last_y
            limit -= 1
          else
            # If both first and last points are conic, start at their
            # middle and keep its position for closure.
            v_start_x = (v_start_x + v_last_x).tdiv(2)
            v_start_y = (v_start_y + v_last_y).tdiv(2)
          end
          i -= 1
        end

        move_to(v_start_x, v_start_y)

        while i < limit
          i += 1
          tag = o.tags[i] & 3
          case tag
          when TAG_ON
            line_to(o.xs[i] &+ @tx, o.ys[i] &+ @ty)
          when TAG_CONIC
            vc_x = o.xs[i] &+ @tx
            vc_y = o.ys[i] &+ @ty

            # Do_Conic: consume a run of conic arcs.
            looping = true
            while looping
              if i < limit
                i += 1
                tag2 = o.tags[i] & 3
                vec_x = o.xs[i] &+ @tx
                vec_y = o.ys[i] &+ @ty
                if tag2 == TAG_ON
                  conic_to(vc_x, vc_y, vec_x, vec_y)
                  looping = false
                elsif tag2 == TAG_CONIC
                  mid_x = (vc_x + vec_x).tdiv(2)
                  mid_y = (vc_y + vec_y).tdiv(2)
                  conic_to(vc_x, vc_y, mid_x, mid_y)
                  vc_x = vec_x
                  vc_y = vec_y
                else
                  raise ArgumentError.new("invalid outline: cubic inside conic run")
                end
              else
                conic_to(vc_x, vc_y, v_start_x, v_start_y)
                looping = false
                closed = true
              end
            end
          else # TAG_CUBIC
            if i + 1 > limit || (o.tags[i + 1] & 3) != TAG_CUBIC
              raise ArgumentError.new("invalid outline: lone cubic control")
            end
            i += 2
            c1x = o.xs[i - 2] &+ @tx
            c1y = o.ys[i - 2] &+ @ty
            c2x = o.xs[i - 1] &+ @tx
            c2y = o.ys[i - 1] &+ @ty
            if i <= limit
              cubic_to(c1x, c1y, c2x, c2y, o.xs[i] &+ @tx, o.ys[i] &+ @ty)
            else
              cubic_to(c1x, c1y, c2x, c2y, v_start_x, v_start_y)
              closed = true
            end
          end
        end

        # Close the contour with a line segment.
        line_to(v_start_x, v_start_y) unless closed
      end
    end

    # --- outline emitters (26.6 in — already translated by decompose —
    # upscaled into 1/256 px) ---------------------------------------------

    private def move_to(x : Int64, y : Int64) : Nil
      px = x &* 4
      py = y &* 4
      set_cell(trunc(px), trunc(py))
      @x = px
      @y = py
    end

    private def line_to(x : Int64, y : Int64) : Nil
      render_line(x &* 4, y &* 4)
    end

    private def conic_to(cx : Int64, cy : Int64, x : Int64, y : Int64) : Nil
      render_conic(cx &* 4, cy &* 4, x &* 4, y &* 4)
    end

    private def cubic_to(c1x : Int64, c1y : Int64, c2x : Int64, c2y : Int64,
                         x : Int64, y : Int64) : Nil
      render_cubic(c1x &* 4, c1y &* 4, c2x &* 4, c2y &* 4, x &* 4, y &* 4)
    end

    private def trunc(v : TPos) : TCoord
      (v >> PIXEL_BITS).to_i32!
    end

    private def fract(v : TPos) : TCoord
      (v & (ONE_PIXEL - 1)).to_i32!
    end

    # --- cells --------------------------------------------------------------

    # Move the current cell to a new position. Everything outside the
    # clipping region lands in a nil dumpster cell; cells to the left of
    # the clip collapse onto x = min_ex - 1 (they still accumulate cover
    # for the sweep, but are never written as pixels).
    private def set_cell(ex : TCoord, ey : TCoord) : Nil
      if ey < @min_ey || ey >= @max_ey || ex >= @max_ex
        @cell = nil
      else
        ex = {ex, @min_ex - 1}.max
        row = @ycells[ey - @min_ey]

        # Binary search the sorted-by-x cell row (the C code walks a
        # linked list kept in the same order).
        lo = 0
        hi = row.size
        while lo < hi
          mid = (lo + hi) // 2
          if row[mid].x < ex
            lo = mid + 1
          else
            hi = mid
          end
        end

        if lo < row.size && row[lo].x == ex
          @cell = row[lo]
        else
          cell = Cell.new(ex)
          row.insert(lo, cell)
          @cell = cell
        end
      end
    end

    # FT_INTEGRATE: add cover `a` and trapezoid area `a*b` to the cell.
    private def integrate(a : Int32, b : Int32) : Nil
      if cell = @cell
        cell.cover = cell.cover &+ a
        cell.area = cell.area &+ a &* b
      end
    end

    # --- straight segments (gray_render_line, FT_INT64 variant) -----------

    private def udiv_prep(cond : Bool, b : Int64) : Int64
      # FT_UDIVPREP: b_r = c ? (FT_Int64)0xFFFFFFFF / b : 0  (C trunc div)
      cond ? 4294967295_i64.tdiv(b) : 0_i64
    end

    private def udiv(a : Int64, b_r : Int64) : TCoord
      # FT_UDIV: (TCoord)( ((FT_UInt64)a * (FT_UInt64)(b_r)) >> 32 )
      ((a.to_u64! &* b_r.to_u64!) >> 32).to_i32!
    end

    private def render_line(to_x : TPos, to_y : TPos) : Nil
      if (lines_log = @@lines_log)
        lines_log << "#{to_x} #{to_y}"
      end
      ey1 = trunc(@y)
      ey2 = trunc(to_y)

      # Perform vertical clipping.
      if (ey1 >= @max_ey && ey2 >= @max_ey) ||
         (ey1 < @min_ey && ey2 < @min_ey)
        @x = to_x
        @y = to_y
        return
      end

      ex1 = trunc(@x)
      ex2 = trunc(to_x)
      fx1 = fract(@x)
      fy1 = fract(@y)

      dx = to_x - @x
      dy = to_y - @y

      fx2 = 0
      fy2 = 0

      if ex1 == ex2 && ey1 == ey2 # inside one cell
        # nothing — the final integrate below covers it
      elsif dy == 0 # ex1 != ex2: any horizontal line
        set_cell(ex2, ey2)
        @x = to_x
        @y = to_y
        return
      elsif dx == 0 # vertical line
        if dy > 0
          loop do
            integrate(ONE_PIXEL - fy1, fx1 * 2)
            fy1 = 0
            ey1 += 1
            set_cell(ex1, ey1)
            break if ey1 == ey2
          end
        else
          loop do
            integrate(0 - fy1, fx1 * 2)
            fy1 = ONE_PIXEL
            ey1 -= 1
            set_cell(ex1, ey1)
            break if ey1 == ey2
          end
        end
        # NB: no early return — C falls through to the final integrate
        # here (only the horizontal branch does `goto End`).
      else # any other line
        prod = dx &* fy1 &- dy &* fx1
        dx_r = udiv_prep(ex1 != ex2, dx)
        dy_r = udiv_prep(ey1 != ey2, dy)

        # The fundamental value `prod` determines which side and the exact
        # coordinate where the line exits the current cell.
        loop do
          if prod &- dx &* ONE_PIXEL > 0 && prod <= 0 # left
            fx2 = 0
            fy2 = udiv(-prod, -dx_r)
            prod -= dy &* ONE_PIXEL
            integrate(fy2 - fy1, fx1 + fx2)
            fx1 = ONE_PIXEL
            fy1 = fy2
            ex1 -= 1
          elsif prod &- dx &* ONE_PIXEL &+ dy &* ONE_PIXEL > 0 &&
                prod &- dx &* ONE_PIXEL <= 0 # up
            prod -= dx &* ONE_PIXEL
            fx2 = udiv(-prod, dy_r)
            fy2 = ONE_PIXEL
            integrate(fy2 - fy1, fx1 + fx2)
            fx1 = fx2
            fy1 = 0
            ey1 += 1
          elsif prod &+ dy &* ONE_PIXEL >= 0 &&
                prod &- dx &* ONE_PIXEL &+ dy &* ONE_PIXEL <= 0 # right
            prod += dy &* ONE_PIXEL
            fx2 = ONE_PIXEL
            fy2 = udiv(prod, dx_r)
            integrate(fy2 - fy1, fx1 + fx2)
            fx1 = 0
            fy1 = fy2
            ex1 += 1
          else # down
            fx2 = udiv(prod, -dy_r)
            fy2 = 0
            prod += dx &* ONE_PIXEL
            integrate(fy2 - fy1, fx1 + fx2)
            fx1 = fx2
            fy1 = ONE_PIXEL
            ey1 -= 1
          end

          set_cell(ex1, ey1)
          break if ex1 == ex2 && ey1 == ey2
        end
      end

      fx2 = fract(to_x)
      fy2 = fract(to_y)
      integrate(fy2 - fy1, fx1 + fx2)

      @x = to_x
      @y = to_y
    end

    # --- conic Béziers (gray_render_conic, FT_INT64 DDA variant) ----------

    private def left_shift(a : Int64, b : Int32) : Int64
      # LEFT_SHIFT: (FT_Int64)( (FT_UInt64)a << b )
      (a.to_u64! << b).to_i64!
    end

    private def render_conic(p1x : TPos, p1y : TPos, p2x : TPos, p2y : TPos) : Nil
      p0x = @x
      p0y = @y

      # Short-cut the arc that crosses the current band.
      if (trunc(p0y) >= @max_ey && trunc(p1y) >= @max_ey && trunc(p2y) >= @max_ey) ||
         (trunc(p0y) < @min_ey && trunc(p1y) < @min_ey && trunc(p2y) < @min_ey)
        @x = p2x
        @y = p2y
        return
      end

      bx = p1x - p0x
      by = p1y - p0y
      ax = p2x - p1x - bx # p0.x + p2.x - 2 * p1.x
      ay = p2y - p1y - by # p0.y + p2.y - 2 * p1.y

      dx = ax.abs
      dy = ay.abs
      dx = dy if dx < dy

      if dx <= ONE_PIXEL // 4
        if (conic_log = @@conic_log)
          conic_log << "p0=#{p0x},#{p0y} p1=#{p1x},#{p1y} p2=#{p2x},#{p2y} flat"
        end
        render_line(p2x, p2y)
        return
      end

      # Each bisection reduces the deviation exactly 4-fold, so the
      # number of necessary segments can be calculated up front.
      shift = 16
      loop do
        dx >>= 2
        shift -= 1
        break unless dx > ONE_PIXEL // 4
      end
      count = 0x10000_u32 >> shift
      if (conic_log = @@conic_log)
        conic_log << "p0=#{p0x},#{p0y} p1=#{p1x},#{p1y} p2=#{p2x},#{p2y} " \
                     "a=#{ax},#{ay} b=#{bx},#{by} shift=#{shift} count=#{count}"
      end

      # Forward-difference DDA on 64-bit values scaled by 2^32:
      #   P(t) = P0 + 2*B*t + A*t^2,  Q(h,t) = 2*B*h + A*h^2 + 2*A*h*t,
      #   R = 2*A*h^2 constant — P += Q; Q += R per step.
      rx = left_shift(ax, shift &+ shift)
      ry = left_shift(ay, shift &+ shift)

      qx = left_shift(bx, shift &+ 17) &+ rx
      qy = left_shift(by, shift &+ 17) &+ ry

      rx &*= 2
      ry &*= 2

      px = left_shift(p0x, 32)
      py = left_shift(p0y, 32)

      loop do
        px &+= qx
        py &+= qy
        qx &+= rx
        qy &+= ry

        render_line(px >> 32, py >> 32)

        count &-= 1
        break if count == 0
      end
    end

    # --- cubic Béziers (gray_render_cubic: adaptive bisection) ------------

    private def render_cubic(c1x : TPos, c1y : TPos, c2x : TPos, c2y : TPos,
                             p3x : TPos, p3y : TPos) : Nil
      # bez_stack: 16*3 + 1 points; arc[k] is the current sub-arc with
      # arc[k+3] the anchor and arc[k+0] the tip (de Casteljau in place).
      # Array, not StaticArray: split_cubic mutates it through the
      # reference (StaticArray is a value type — a copy would be split).
      xs = Array.new(49, 0_i64)
      ys = Array.new(49, 0_i64)

      xs[0] = p3x
      ys[0] = p3y
      xs[1] = c2x
      ys[1] = c2y
      xs[2] = c1x
      ys[2] = c1y
      xs[3] = @x
      ys[3] = @y

      # Short-cut the arc that crosses the current band.
      if (trunc(ys[0]) >= @max_ey && trunc(ys[1]) >= @max_ey &&
          trunc(ys[2]) >= @max_ey && trunc(ys[3]) >= @max_ey) ||
         (trunc(ys[0]) < @min_ey && trunc(ys[1]) < @min_ey &&
          trunc(ys[2]) < @min_ey && trunc(ys[3]) < @min_ey)
        @x = xs[0]
        @y = ys[0]
        return
      end

      k = 0
      loop do
        # With each split, control points quickly converge towards the
        # chord trisection points; these distances decide flatness.
        if (2 &* xs[k] &- 3 &* xs[k + 1] &+ xs[k + 3]).abs > ONE_PIXEL // 2 ||
           (2 &* ys[k] &- 3 &* ys[k + 1] &+ ys[k + 3]).abs > ONE_PIXEL // 2 ||
           (xs[k] &- 3 &* xs[k + 2] &+ 2 &* xs[k + 3]).abs > ONE_PIXEL // 2 ||
           (ys[k] &- 3 &* ys[k + 2] &+ 2 &* ys[k + 3]).abs > ONE_PIXEL // 2
          split_cubic(xs, ys, k)
          k += 3
          next
        end

        render_line(xs[k], ys[k])

        break if k == 0
        k -= 3
      end
    end

    # gray_split_cubic: de Casteljau bisection of the arc at `k`.
    private def split_cubic(xs : Array(Int64), ys : Array(Int64),
                            k : Int32) : Nil
      xs[k + 6] = xs[k + 3]
      a = xs[k] &+ xs[k + 1]
      b = xs[k + 1] &+ xs[k + 2]
      c = xs[k + 2] &+ xs[k + 3]
      xs[k + 5] = c >> 1
      c &+= b
      xs[k + 4] = c >> 2
      xs[k + 1] = a >> 1
      a &+= b
      xs[k + 2] = a >> 2
      xs[k + 3] = (a &+ c) >> 3

      ys[k + 6] = ys[k + 3]
      a = ys[k] &+ ys[k + 1]
      b = ys[k + 1] &+ ys[k + 2]
      c = ys[k + 2] &+ ys[k + 3]
      ys[k + 5] = c >> 1
      c &+= b
      ys[k + 4] = c >> 2
      ys[k + 1] = a >> 1
      a &+= b
      ys[k + 2] = a >> 2
      ys[k + 3] = (a &+ c) >> 3
    end

    # --- sweep (gray_sweep) -------------------------------------------------

    # FT_FILL_RULE: scale the area and apply the fill rule to get the
    # coverage byte. The top fill bit drives the non-zero rule, the
    # eighth bit the even-odd rule; higher bytes clamp (non-zero) or get
    # truncated by the byte store (even-odd).
    private def fill_rule(area : TArea, fill : Int32) : Int32
      coverage = area >> (PIXEL_BITS * 2 + 1 - 8)
      coverage = ~coverage if (coverage & fill) != 0
      coverage = 255 if coverage > 255 && (fill & Int32::MIN) != 0
      coverage
    end

    private def sweep(o : Outline) : Nil
      fill = (o.flags & FT_OUTLINE_EVEN_ODD_FILL) != 0 ? 0x100 : Int32::MIN

      @height.times do |ey| # y up; the buffer is top-down
        row = @ycells[ey]
        x = @min_ex
        cover : TArea = 0
        line = (@height - 1 - ey) * @width

        row.each do |cell|
          if cover != 0 && cell.x > x
            coverage = fill_rule(cover, fill)
            @buf.fill(coverage.to_u8!, line + x, cell.x - x)
          end

          cover = cover &+ cell.cover &* (ONE_PIXEL * 2)
          area = cover &- cell.area

          if area != 0 && cell.x >= @min_ex
            coverage = fill_rule(area, fill)
            @buf[line + cell.x] = coverage.to_u8!
          end

          x = cell.x + 1
        end

        if cover != 0 # only if cropped
          coverage = fill_rule(cover, fill)
          @buf.fill(coverage.to_u8!, line + x, @max_ex - x)
        end
      end
    end
  end
end

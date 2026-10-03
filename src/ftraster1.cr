# Crystal port of FreeType's `black' rasterizer (src/raster/ftraster.c,
# FreeType 2.13.3) — the profile-based scan-line converter used for
# FT_RENDER_MODE_MONO. This is the classic FT 1.x rewrite: the outline
# is decomposed into `profiles' (per-scanline intersection stacks that
# grow up from the render pool bottom, with the sorted y-turn extrema
# in a second stack growing down from the pool top), then swept twice —
# a vertical pass filling spans plus drop-out control, and a horizontal
# pass (outline flipped) that fixes perfectly aligned horizontal edges.
# All arithmetic is C-like: wrapping `&*' products, truncating division,
# arithmetic shifts.
#
# Layout detail carried over from C: profiles and their coordinate
# arrays grow up in the pool; the y-turn list grows down, its base
# (`max_buff') moving down by one slot per insertion — which shifts the
# stored turns for free; Insert_Y_Turns' in-place ripple write (running
# one slot past the array head, into the just-freed slot) is reproduced
# index by index.
#
# Entry point: Ftraster1.render(outline, width, height, tx, ty) —
# translates the 26.6 outline by (tx, ty) like ftrend1.c's
# ft_raster1_render, then renders a 1-bit MSB-first top-down bitmap
# with pitch = ((width + 15) >> 4) << 1, bit-exact against FreeType.

require "./ftgrays"

module Ftraster1
  def self.render(outline : Ftgrays::Outline, width : Int32, height : Int32,
                  tx : Int64 = 0_i64, ty : Int64 = 0_i64) : Bytes
    pitch = ((width + 15) >> 4) << 1
    buf = Bytes.new(pitch * height)
    return buf if width <= 0 || height <= 0
    return buf if outline.contours.empty? || outline.xs.empty?
    if outline.xs.size != outline.contours.last + 1
      raise ArgumentError.new("invalid outline: n_points != contours[-1] + 1")
    end

    Worker.new(outline, buf, width, height, pitch, tx, ty).render_glyph
    buf
  end

  class Worker
    enum State
      Unknown
      Ascending
      Descending
      Flat
    end

    # profile flag bits (ftraster.c)
    FLOW_UP          = 0x08_i64
    OVERSHOOT_TOP    = 0x10_i64
    OVERSHOOT_BOTTOM = 0x20_i64
    DROPOUT          = 0x40_i64

    # outline flags consumed here (ftimage.h)
    OUTLINE_IGNORE_DROPOUTS = 0x8
    OUTLINE_SMART_DROPOUTS  = 0x10
    OUTLINE_INCLUDE_STUBS   = 0x20
    OUTLINE_HIGH_PRECISION  = 0x100
    OUTLINE_SINGLE_PASS     = 0x200

    # curve tag bits (ftimage.h); the scan mode rides in bit 2
    TAG_ON           = 0x01_u8
    TAG_CONIC        = 0x00_u8
    TAG_CUBIC        = 0x02_u8
    TAG_HAS_SCANMODE = 0x04_u8

    # error classes (subset of rasterrs.h)
    ERR_OK             = 0
    ERR_INVALID        = 1
    ERR_OVERFLOW       = 2

    # Profile header words in the pool: link, next, offset, height,
    # start, flags, X — the intersection coordinates follow from +7.
    LINK   = 0
    NEXT   = 1
    OFFSET = 2
    HEIGHT = 3
    START  = 4
    FLAGS  = 5
    X      = 6
    PROF_WORDS = 7

    MAX_BEZIER = 32
    PIXEL_BITS = 6
    POOL_SIZE  = 2048 # FT_MAX_BLACK_POOL

    @pool : Array(Int64)
    @top : Int32 = 0
    @max_buff : Int32 = 0

    @err : Int32 = ERR_OK
    @drop_out_control : Int64 = 0

    @last_x : Int64 = 0
    @last_y : Int64 = 0
    @min_y : Int64 = 0
    @max_yl : Int64 = 0

    @num_profs : Int32 = 0
    @num_turns : Int32 = 0

    @c_profile : Int32 = -1
    @f_profile : Int32 = -1
    @g_profile : Int32 = -1

    @state : State = State::Unknown

    @precision_bits : Int32 = 6
    @precision : Int64 = 64
    @precision_half : Int64 = 32
    @precision_scale : Int64 = 1
    @precision_step : Int64 = 32

    @buf : Bytes
    @b_top : Int32
    @b_right : Int32
    @b_pitch : Int32
    @b_line : Int32 = 0

    @horizontal : Bool = false

    @outline : Ftgrays::Outline
    @tx : Int64
    @ty : Int64

    # Bezier stack (conic needs 2*32+1 = 65 slots, cubic 3*32+1 = 97)
    @ax : Array(Int64)
    @ay : Array(Int64)

    def initialize(@outline : Ftgrays::Outline, @buf : Bytes,
                   width : Int32, height : Int32, pitch : Int32,
                   @tx : Int64, @ty : Int64)
      @pool = Array(Int64).new(POOL_SIZE, 0_i64)
      @b_top = height - 1
      @b_right = width - 1
      @b_pitch = pitch
      @ax = Array(Int64).new(3*MAX_BEZIER + 1, 0_i64)
      @ay = Array(Int64).new(3*MAX_BEZIER + 1, 0_i64)
    end

    # --- entry (Render_Glyph) ----------------------------------------------

    def render_glyph : Nil
      set_high_precision((@outline.flags & OUTLINE_HIGH_PRECISION) != 0)

      @drop_out_control = 0
      @drop_out_control |= 2 if (@outline.flags & OUTLINE_IGNORE_DROPOUTS) != 0
      @drop_out_control |= 4 if (@outline.flags & OUTLINE_SMART_DROPOUTS) != 0
      @drop_out_control |= 1 if (@outline.flags & OUTLINE_INCLUDE_STUBS) == 0

      @horizontal = false
      render_single_pass(0, 0, @b_top)
      return if (@outline.flags & OUTLINE_SINGLE_PASS) != 0
      @horizontal = true
      render_single_pass(1, 0, @b_right)
    end

    private def set_high_precision(high : Bool) : Nil
      if high
        @precision_bits = 12
        @precision_step = 256
      else
        @precision_bits = 6
        @precision_step = 32
      end
      @precision = 1_i64 << @precision_bits
      @precision_half = @precision >> 1
      @precision_scale = @precision >> PIXEL_BITS
    end

    # --- fixed-point helpers ------------------------------------------------

    private def floor64(x : Int64) : Int64
      x & -@precision
    end

    private def ceiling64(x : Int64) : Int64
      (x + @precision - 1) & -@precision
    end

    private def trunc64(x : Int64) : Int64
      x >> @precision_bits
    end

    private def frac64(x : Int64) : Int64
      x & (@precision - 1)
    end

    # SCALED: translate + scale onto the pixel-center grid.
    private def scaled(x : Int64) : Int64
      (x &+ @tx) &* @precision_scale &- @precision_half
    end

    private def scaled_y(y : Int64) : Int64
      (y &+ @ty) &* @precision_scale &- @precision_half
    end

    private def is_bottom_overshoot(x : Int64) : Bool
      ceiling64(x) - x >= @precision_half
    end

    private def is_top_overshoot(x : Int64) : Bool
      x - floor64(x) >= @precision_half
    end

    private def smart(p : Int64, q : Int64) : Int64
      floor64((p &+ q &+ (@precision &* 63 // 64)) >> 1)
    end

    # FT_MulDiv_No_Round (ftcalc.c, FT_INT64 path).
    private def muldiv_no_round(a_ : Int64, b_ : Int64, c_ : Int64) : Int64
      s = 1
      a = a_ < 0 ? (0_u64 &- a_.to_u64!) : a_.to_u64!
      s = -s if a_ < 0
      b = b_ < 0 ? (0_u64 &- b_.to_u64!) : b_.to_u64!
      s = -s if b_ < 0
      c = c_ < 0 ? (0_u64 &- c_.to_u64!) : c_.to_u64!
      s = -s if c_ < 0

      d = c > 0 ? (a &* b) // c : 0x7FFFFFFF_u64
      d_ = d.to_i64!
      s < 0 ? (0_i64 &- d_) : d_
    end

    # FMulDiv: the product is known to fit into the type.
    private def fmuldiv(a : Int64, b : Int64, c : Int64) : Int64
      (a &* b).tdiv(c)
    end

    # --- profile construction -----------------------------------------------

    # Insert_Y_Turns: returns true on success. The y-turn list lives at
    # pool[max_buff ..]; a new turn ripples the values below the insert
    # position down one slot (the last write lands at base-1, the slot
    # freed by the max_buff decrement) — exactly the C in-place shift.
    private def insert_y_turns(y : Int64, top : Int32) : Bool
      n = @num_turns
      base = @max_buff

      @pool[base + n] = top.to_i64 if n == 0 || top > @pool[base + n]

      # C: while ( n-- && y < y_turns[n] ); — find the last index with
      # y_turns[n] <= y, or -1 when y is below them all.
      n -= 1
      while n >= 0 && y < @pool[base + n]
        n -= 1
      end

      if n < 0 || y > @pool[base + n]
        @max_buff -= 1
        if @max_buff <= @top
          @err = ERR_OVERFLOW
          return false
        end

        # do { y2 = y_turns[n]; y_turns[n] = y; y = y2 } while ( n-- >= 0 )
        k = n
        while k >= 0
          y2 = @pool[base + k]
          @pool[base + k] = y
          y = y2
          k -= 1
        end
        @pool[base - 1] = y # the k == -1 iteration

        @num_turns += 1
      end

      true
    end

    private def new_profile(a_state : State) : Bool
      if @c_profile < 0 || @pool[@c_profile + HEIGHT] != 0
        @c_profile = @top
        @top += PROF_WORDS
        if @top >= @max_buff
          @err = ERR_OVERFLOW
          return false
        end
        @pool[@c_profile + HEIGHT] = 0
      end

      @pool[@c_profile + FLAGS] = @drop_out_control

      e : Int64
      case a_state
      in State::Ascending
        @pool[@c_profile + FLAGS] |= FLOW_UP
        @pool[@c_profile + FLAGS] |= OVERSHOOT_BOTTOM if is_bottom_overshoot(@last_y)
        e = ceiling64(@last_y)
      in State::Descending
        @pool[@c_profile + FLAGS] |= OVERSHOOT_TOP if is_top_overshoot(@last_y)
        e = floor64(@last_y)
      in State::Unknown, State::Flat
        @err = ERR_INVALID
        return false
      end

      e = @max_yl if e > @max_yl
      e = @min_y if e < @min_y
      @pool[@c_profile + START] = trunc64(e)

      if @last_y == e
        @pool[@top] = @last_x
        @top += 1
      end

      @state = a_state
      true
    end

    private def end_profile : Bool
      p = @c_profile
      h = @top - (p + PROF_WORDS)

      if h < 0
        @err = ERR_INVALID
        return false
      end
      return true if h == 0

      @pool[p + HEIGHT] = h

      bottom : Int32
      top : Int32
      if @pool[p + FLAGS] & FLOW_UP != 0
        @pool[p + FLAGS] |= OVERSHOOT_TOP if is_top_overshoot(@last_y)

        bottom = @pool[p + START].to_i32!
        top = bottom + h
        @pool[p + OFFSET] = 0
        @pool[p + X] = @pool[p + PROF_WORDS]
      else
        @pool[p + FLAGS] |= OVERSHOOT_BOTTOM if is_bottom_overshoot(@last_y)

        top = @pool[p + START].to_i32! + 1
        bottom = top - h
        @pool[p + START] = bottom
        @pool[p + OFFSET] = h - 1
        @pool[p + X] = @pool[p + PROF_WORDS + h - 1]
      end

      return false unless insert_y_turns(bottom.to_i64, top)

      # preliminary values to be finalized
      @g_profile = p if @g_profile < 0
      @pool[p + NEXT] = @g_profile
      @pool[p + LINK] = @top
      @num_profs += 1

      true
    end

    # Finalize_Profile_Table: fix the contour `next' loops and terminate
    # the link chain.
    private def finalize_profile_table : Nil
      n = @num_profs
      p = @f_profile
      return if p < 0

      while n > 1
        n -= 1
        q = @pool[p + LINK].to_i32!
        @pool[p + NEXT] = q if @pool[q + NEXT] == @pool[p + NEXT]
        p = q
      end
      @pool[p + LINK] = -1
    end

    # --- Bezier split --------------------------------------------------------

    private def split_conic(base : Int32) : Nil
      a = @ax[base] &+ @ax[base + 1]
      b = @ax[base + 1] &+ @ax[base + 2]
      @ax[base + 4] = @ax[base + 2]
      @ax[base + 3] = b >> 1
      @ax[base + 2] = (a &+ b) >> 2
      @ax[base + 1] = a >> 1

      a = @ay[base] &+ @ay[base + 1]
      b = @ay[base + 1] &+ @ay[base + 2]
      @ay[base + 4] = @ay[base + 2]
      @ay[base + 3] = b >> 1
      @ay[base + 2] = (a &+ b) >> 2
      @ay[base + 1] = a >> 1
    end

    private def split_cubic(base : Int32) : Nil
      a = @ax[base] &+ @ax[base + 1]
      b = @ax[base + 1] &+ @ax[base + 2]
      c = @ax[base + 2] &+ @ax[base + 3]
      @ax[base + 6] = @ax[base + 3]
      @ax[base + 5] = c >> 1
      c = c &+ b
      @ax[base + 4] = c >> 2
      @ax[base + 1] = a >> 1
      a = a &+ b
      @ax[base + 2] = a >> 2
      @ax[base + 3] = (a &+ c) >> 3

      a = @ay[base] &+ @ay[base + 1]
      b = @ay[base + 1] &+ @ay[base + 2]
      c = @ay[base + 2] &+ @ay[base + 3]
      @ay[base + 6] = @ay[base + 3]
      @ay[base + 5] = c >> 1
      c = c &+ b
      @ay[base + 4] = c >> 2
      @ay[base + 1] = a >> 1
      a = a &+ b
      @ay[base + 2] = a >> 2
      @ay[base + 3] = (a &+ c) >> 3
    end

    # --- line/bezier scanline conversion -------------------------------------

    private def line_up(x1 : Int64, y1 : Int64, x2 : Int64, y2 : Int64,
                        miny : Int64, maxy : Int64) : Bool
      return true if y2 < miny || y1 > maxy

      e2 = y2 > maxy ? maxy : floor64(y2)
      e = y1 < miny ? miny : ceiling64(y1)
      e += @precision if y1 == e
      return true if e2 < e

      size = (trunc64(e2 - e) + 1).to_i32!
      if @top + size >= @max_buff
        @err = ERR_OVERFLOW
        return false
      end

      dx = x2 - x1
      dy = y2 - y1

      if dx == 0 # very easy
        size.times do
          @pool[@top] = x1
          @top += 1
        end
        return true
      end

      ix = muldiv_no_round(e - y1, dx, dy)
      x1 += ix
      @pool[@top] = x1
      @top += 1

      size -= 1
      if size > 0
        ax_ = dx &* (e - y1) &- dy &* ix # remainder
        ix = fmuldiv(@precision, dx, dy)
        rx = dx &* @precision &- dy &* ix # remainder
        dxs = 1_i64

        if x2 < x1
          ax_ = -ax_
          rx = -rx
          dxs = -dxs
        end

        while size > 0
          x1 += ix
          ax_ += rx
          if ax_ >= dy
            ax_ -= dy
            x1 += dxs
          end
          @pool[@top] = x1
          @top += 1
          size -= 1
        end
      end

      true
    end

    private def line_down(x1 : Int64, y1 : Int64, x2 : Int64, y2 : Int64,
                          miny : Int64, maxy : Int64) : Bool
      line_up(x1, -y1, x2, -y2, -maxy, -miny)
    end

    private def bezier_up(degree : Int32, arc : Int32, conic : Bool,
                          miny : Int64, maxy : Int64) : Bool
      y1 = @ay[arc + degree]
      y2 = @ay[arc]

      return true if y2 < miny || y1 > maxy

      e2 = y2 > maxy ? maxy : floor64(y2)
      e = y1 < miny ? miny : ceiling64(y1)
      e += @precision if y1 == e
      return true if e2 < e

      if @top + (trunc64(e2 - e) + 1).to_i32! >= @max_buff
        @err = ERR_OVERFLOW
        return false
      end

      loop do
        y2 = @ay[arc]
        x2 = @ax[arc]

        if y2 > e
          dy = y2 - @ay[arc + degree]
          dx = x2 - @ax[arc + degree]

          # split condition should be invariant of direction
          if dy > @precision_step || dx > @precision_step || -dx > @precision_step
            conic ? split_conic(arc) : split_cubic(arc)
            arc += degree
          else
            @pool[@top] = x2 - fmuldiv(y2 - e, dx, dy)
            @top += 1
            e += @precision
            arc -= degree
          end
        else
          if y2 == e
            @pool[@top] = x2
            @top += 1
            e += @precision
          end
          arc -= degree
        end

        break unless e <= e2
      end

      true
    end

    private def bezier_down(degree : Int32, arc : Int32, conic : Bool,
                            miny : Int64, maxy : Int64) : Bool
      (degree + 1).times { |i| @ay[arc + i] = -@ay[arc + i] }

      result = bezier_up(degree, arc, conic, -maxy, -miny)

      @ay[arc] = -@ay[arc]
      result
    end

    private def line_to(x : Int64, y : Int64) : Bool
      if y != @last_y
        state = @last_y < y ? State::Ascending : State::Descending

        if @state != state
          return false if @state != State::Unknown && !end_profile
          return false unless new_profile(state)
        end

        if state.ascending?
          return false unless line_up(@last_x, @last_y, x, y, @min_y, @max_yl)
        else
          return false unless line_down(@last_x, @last_y, x, y, @min_y, @max_yl)
        end
      end

      @last_x = x
      @last_y = y
      true
    end

    private def conic_to(cx : Int64, cy : Int64, x : Int64, y : Int64) : Bool
      arc = 0
      @ax[2] = @last_x
      @ay[2] = @last_y
      @ax[1] = cx
      @ay[1] = cy
      @ax[0] = x
      @ay[0] = y

      loop do
        y1 = @ay[arc + 2]
        y2 = @ay[arc + 1]
        y3 = @ay[arc]
        x3 = @ax[arc]

        ymin = y1 <= y3 ? y1 : y3
        ymax = y1 <= y3 ? y3 : y1

        if y2 < floor64(ymin) || y2 > ceiling64(ymax)
          # this arc has no given direction, split it!
          split_conic(arc)
          arc += 2
        elsif y1 == y3
          # this arc is flat, advance position and pop the stack
          arc -= 2
          @last_x = x3
          @last_y = y3
        else
          state_bez = y1 < y3 ? State::Ascending : State::Descending
          if @state != state_bez
            return false if @state != State::Unknown && !end_profile
            return false unless new_profile(state_bez)
          end

          if state_bez.ascending?
            return false unless bezier_up(2, arc, true, @min_y, @max_yl)
          else
            return false unless bezier_down(2, arc, true, @min_y, @max_yl)
          end
          arc -= 2

          @last_x = x3
          @last_y = y3
        end

        break unless arc >= 0
      end

      true
    end

    private def cubic_to(cx1 : Int64, cy1 : Int64, cx2 : Int64, cy2 : Int64,
                         x : Int64, y : Int64) : Bool
      arc = 0
      @ax[3] = @last_x
      @ay[3] = @last_y
      @ax[2] = cx1
      @ay[2] = cy1
      @ax[1] = cx2
      @ay[1] = cy2
      @ax[0] = x
      @ay[0] = y

      loop do
        y1 = @ay[arc + 3]
        y2 = @ay[arc + 2]
        y3 = @ay[arc + 1]
        y4 = @ay[arc]
        x4 = @ax[arc]

        ymin1 = y1 <= y4 ? y1 : y4
        ymax1 = y1 <= y4 ? y4 : y1
        ymin2 = y2 <= y3 ? y2 : y3
        ymax2 = y2 <= y3 ? y3 : y2

        if ymin2 < floor64(ymin1) || ymax2 > ceiling64(ymax1)
          split_cubic(arc)
          arc += 3
        elsif y1 == y4
          arc -= 3
          @last_x = x4
          @last_y = y4
        else
          state_bez = y1 < y4 ? State::Ascending : State::Descending
          if @state != state_bez
            return false if @state != State::Unknown && !end_profile
            return false unless new_profile(state_bez)
          end

          if state_bez.ascending?
            return false unless bezier_up(3, arc, false, @min_y, @max_yl)
          else
            return false unless bezier_down(3, arc, false, @min_y, @max_yl)
          end
          arc -= 3

          @last_x = x4
          @last_y = y4
        end

        break unless arc >= 0
      end

      true
    end

    # --- outline decomposition ----------------------------------------------

    # Point coordinate on the pixel-center grid, flipped when the
    # horizontal pass swaps the axes.
    private def px(i : Int32) : Int64
      @horizontal ? scaled_y(@outline.ys.unsafe_fetch(i)) : scaled(@outline.xs.unsafe_fetch(i))
    end

    private def py(i : Int32) : Int64
      @horizontal ? scaled(@outline.xs.unsafe_fetch(i)) : scaled_y(@outline.ys.unsafe_fetch(i))
    end

    private def decompose_curve(first : Int32, last : Int32) : Bool
      xs = @outline.xs
      tags = @outline.tags

      v_start_x = px(first)
      v_start_y = py(first)
      v_last_x = px(last)
      v_last_y = py(last)

      v_control_x = v_start_x
      v_control_y = v_start_y

      point = first
      limit = last

      # set scan mode if necessary
      if tags.unsafe_fetch(first) & TAG_HAS_SCANMODE != 0
        @drop_out_control = tags.unsafe_fetch(first).to_i64! >> 5
      end

      tag = tags.unsafe_fetch(first) & 0x03

      # A contour cannot start with a cubic control point!
      if tag == TAG_CUBIC
        @err = ERR_INVALID
        return false
      end

      # check first point to determine origin
      if tag == TAG_CONIC
        # first point is conic control.  Yes, this happens.
        if tags.unsafe_fetch(last) & 0x03 == TAG_ON
          # start at last point if it is on the curve
          v_start_x = v_last_x
          v_start_y = v_last_y
          limit -= 1
        else
          # if both first and last points are conic, start at their
          # middle and record its position for closure
          v_start_x = (v_start_x + v_last_x).tdiv(2)
          v_start_y = (v_start_y + v_last_y).tdiv(2)
        end
        point -= 1
      end

      @last_x = v_start_x
      @last_y = v_start_y

      while point < limit
        point += 1

        tag = tags.unsafe_fetch(point) & 0x03

        case tag
        when TAG_ON # emit a single line_to
          return false unless line_to(px(point), py(point))
        when TAG_CONIC # consume conic arcs
          v_control_x = px(point)
          v_control_y = py(point)

          # Do_Conic loop
          loop do
            if point < limit
              point += 1
              tag2 = tags.unsafe_fetch(point) & 0x03

              x3 = px(point)
              y3 = py(point)

              if tag2 == TAG_ON
                return false unless conic_to(v_control_x, v_control_y, x3, y3)
                break
              end

              if tag2 != TAG_CONIC
                @err = ERR_INVALID
                return false
              end

              v_middle_x = (v_control_x + x3).tdiv(2)
              v_middle_y = (v_control_y + y3).tdiv(2)

              return false unless conic_to(v_control_x, v_control_y,
                                           v_middle_x, v_middle_y)

              v_control_x = x3
              v_control_y = y3
            else
              return false unless conic_to(v_control_x, v_control_y,
                                           v_start_x, v_start_y)
              return true # Close
            end
          end
        else # FT_CURVE_TAG_CUBIC
          if point + 1 > limit || tags.unsafe_fetch(point + 1) & 0x03 != TAG_CUBIC
            @err = ERR_INVALID
            return false
          end

          point += 2

          x1 = px(point - 2)
          y1 = py(point - 2)
          x2 = px(point - 1)
          y2 = py(point - 1)

          if point <= limit
            x3 = px(point)
            y3 = py(point)

            return false unless cubic_to(x1, y1, x2, y2, x3, y3)
          else
            return false unless cubic_to(x1, y1, x2, y2, v_start_x, v_start_y)
            return true # Close
          end
        end
      end

      # close the contour with a line segment
      return false unless line_to(v_start_x, v_start_y)

      true
    end

    private def convert_glyph : Bool
      @f_profile = -1
      @c_profile = -1

      @top = 0
      @max_buff = POOL_SIZE - 1 # top reserve

      @num_turns = 0
      @num_profs = 0

      last = -1
      @outline.contours.each do |cend|
        @state = State::Unknown
        @g_profile = -1

        first = last + 1
        last = cend

        return false unless decompose_curve(first, last)

        # g_profile can stay nil if the contour was too small to be
        # drawn or degenerate.
        next if @g_profile < 0

        # we must now check whether the extreme arcs join or not
        if frac64(@last_y) == 0 && @last_y >= @min_y && @last_y <= @max_yl
          if (@pool[@g_profile + FLAGS] & FLOW_UP) ==
             (@pool[@c_profile + FLAGS] & FLOW_UP)
            @top -= 1
          end
        end

        return false unless end_profile

        @f_profile = @g_profile if @f_profile < 0
      end

      finalize_profile_table if @f_profile >= 0

      true
    end

    # --- sweep ----------------------------------------------------------------

    # InsNew: insert into the list sorted by X (returns the new head).
    private def ins_new(head : Int32, profile : Int32) : Int32
      x = @pool[profile + X]
      if head < 0 || @pool[head + X] >= x
        @pool[profile + LINK] = head.to_i64
        return profile
      end
      prev = head
      while (nxt = @pool[prev + LINK].to_i32!) >= 0 && @pool[nxt + X] < x
        prev = nxt
      end
      @pool[profile + LINK] = @pool[prev + LINK]
      @pool[prev + LINK] = profile.to_i64
      head
    end

    # Increment: advance the profiles to the next scanline, drop the
    # exhausted ones, and keep the list sorted (single-swap bubble with
    # restart, like the C).
    private def increment(head : Int32, flow : Int32) : Int32
      p = head
      prev = -1
      while p >= 0
        nxt = @pool[p + LINK].to_i32!
        @pool[p + HEIGHT] -= 1
        if @pool[p + HEIGHT] != 0
          @pool[p + OFFSET] += flow
          @pool[p + X] = @pool[p + PROF_WORDS + @pool[p + OFFSET].to_i32!]
          prev = p
        else
          if prev < 0
            head = nxt
          else
            @pool[prev + LINK] = nxt
          end
        end
        p = nxt
      end

      # then make sure the list remains sorted
      loop do
        break if head < 0
        cur = head
        prev = -1
        swapped = false
        while (nxt = @pool[cur + LINK].to_i32!) >= 0
          if @pool[cur + X] <= @pool[nxt + X]
            prev = cur
            cur = nxt
          else
            if prev < 0
              head = nxt
            else
              @pool[prev + LINK] = nxt
            end
            @pool[cur + LINK] = @pool[nxt + LINK]
            @pool[nxt + LINK] = cur.to_i64
            swapped = true
            break # restart
          end
        end
        break unless swapped
      end

      head
    end

    private def draw_sweep : Nil
      waiting = @f_profile
      draw_left = -1
      draw_right = -1

      min_y = @pool[@max_buff].to_i32!
      max_y = @pool[@max_buff + @num_turns].to_i32! - 1

      sweep_init(min_y, max_y)

      yti = @max_buff
      y = min_y
      while y <= max_y
        # check waiting list for new profile activations
        p = waiting
        prev = -1
        while p >= 0
          nxt = @pool[p + LINK].to_i32!
          if @pool[p + START] == y
            if prev < 0
              waiting = nxt
            else
              @pool[prev + LINK] = nxt
            end
            if @pool[p + FLAGS] & FLOW_UP != 0
              draw_left = ins_new(draw_left, p)
            else
              draw_right = ins_new(draw_right, p)
            end
          else
            prev = p
          end
          p = nxt
        end

        yti += 1
        y_turn = @pool[yti].to_i32!

        loop do # do { trace } while ( ++y < y_turn )
          dropouts = 0

          pl = draw_left
          pr = draw_right

          while pl >= 0 && pr >= 0
            x1 = @pool[pl + X]
            x2 = @pool[pr + X]

            # TrueType should have x2 > x1, but can be opposite by
            # mistake or in CFF/Type1 — fix it then
            if x1 > x2
              x1, x2 = x2, x1
            end

            if ceiling64(x1) <= floor64(x2)
              sweep_span(y, x1, x2)
            else
              drop_out_control = @pool[pl + FLAGS] & 7

              skip = false
              if drop_out_control & 2 != 0
                skip = true
              elsif drop_out_control & 1 != 0
                # upper stub test
                if @pool[pl + HEIGHT] == 1 &&
                   @pool[pl + NEXT] == pr &&
                   !((@pool[pl + FLAGS] & OVERSHOOT_TOP != 0) &&
                     x2 - x1 >= @precision_half)
                  skip = true
                end
                # lower stub test
                if !skip && @pool[pl + OFFSET] == 0 &&
                   @pool[pr + NEXT] == pl &&
                   !((@pool[pl + FLAGS] & OVERSHOOT_BOTTOM != 0) &&
                     x2 - x1 >= @precision_half)
                  skip = true
                end
              end

              unless skip
                if drop_out_control & 4 != 0
                  x2s = smart(x1, x2)
                  x1s = x1 > x2s ? x2s + @precision : x2s - @precision
                  x2 = x2s
                  x1 = x1s
                else
                  x2 = floor64(x2)
                  x1 = ceiling64(x1)
                end

                @pool[pl + X] = x2
                @pool[pr + X] = x1

                # mark profile for drop-out processing
                @pool[pl + FLAGS] |= DROPOUT
                dropouts += 1
              end
            end

            pl = @pool[pl + LINK].to_i32!
            pr = @pool[pr + LINK].to_i32!
          end

          # handle drop-outs _after_ the span drawing
          pl = draw_left
          pr = draw_right

          while dropouts > 0
            if pl < 0 || pr < 0
              break # cannot happen with well-formed profile pairs
            end
            if @pool[pl + FLAGS] & DROPOUT != 0
              sweep_drop(y, @pool[pl + X], @pool[pr + X])
              @pool[pl + FLAGS] &= ~DROPOUT
              dropouts -= 1
            end
            pl = @pool[pl + LINK].to_i32!
            pr = @pool[pr + LINK].to_i32!
          end

          sweep_step

          draw_left = increment(draw_left, 1)
          draw_right = increment(draw_right, -1)

          y += 1
          break unless y < y_turn
        end
      end
    end

    # --- the two sweep procedure sets ----------------------------------------

    private def sweep_init(min : Int32, max : Int32) : Nil
      # Horizontal_Sweep_Init does nothing.
      @b_line = (@b_top - min) * @b_pitch unless @horizontal
    end

    private def sweep_span(y : Int32, x1 : Int64, x2 : Int64) : Nil
      if @horizontal
        e1l = ceiling64(x1)
        e2l = floor64(x2)

        # The vertical sweep mishandles horizontal lines through pixel
        # centers, so aligned span edges are checked here.
        if x1 == e1l
          e1 = trunc64(e1l).to_i32!
          if e1 >= 0 && e1 <= @b_top
            idx = @b_top * @b_pitch + (y >> 3) - e1 * @b_pitch
            @buf[idx] |= 0x80_u8 >> (y & 7)
          end
        end

        if x2 == e2l
          e2 = trunc64(e2l).to_i32!
          if e2 >= 0 && e2 <= @b_top
            idx = @b_top * @b_pitch + (y >> 3) - e2 * @b_pitch
            @buf[idx] |= 0x80_u8 >> (y & 7)
          end
        end
      else
        e1 = trunc64(ceiling64(x1)).to_i32!
        e2 = trunc64(floor64(x2)).to_i32!

        if e2 >= 0 && e1 <= @b_right
          e1 = 0 if e1 < 0
          e2 = @b_right if e2 > @b_right

          c1 = e1 >> 3
          c2 = e2 >> 3

          f1 = (0xFF >> (e1 & 7)).to_u8!
          f2 = ((~0x7F) >> (e2 & 7)).to_u8!

          target = @b_line + c1
          c2 -= c1

          if c2 > 0
            @buf[target] |= f1
            c2 -= 1
            while c2 > 0
              target += 1
              @buf[target] = 0xFF_u8
              c2 -= 1
            end
            @buf[target + 1] |= f2
          else
            @buf[target] |= (f1 & f2)
          end
        end
      end
    end

    private def sweep_drop(y : Int32, x1 : Int64, x2 : Int64) : Nil
      e1 = trunc64(x1).to_i32!
      e2 = trunc64(x2).to_i32!

      if @horizontal
        # undocumented but confirmed: if the drop-out would land outside
        # of the bounding box, use the pixel inside of it instead
        if e1 < 0 || e1 > @b_top
          e1 = e2
        elsif e2 >= 0 && e2 <= @b_top
          idx = @b_top * @b_pitch + (y >> 3) - e2 * @b_pitch
          return if @buf[idx] & (0x80_u8 >> (y & 7)) != 0
        end

        if e1 >= 0 && e1 <= @b_top
          idx = @b_top * @b_pitch + (y >> 3) - e1 * @b_pitch
          @buf[idx] |= 0x80_u8 >> (y & 7)
        end
      else
        if e1 < 0 || e1 > @b_right
          e1 = e2
        elsif e2 >= 0 && e2 <= @b_right
          return if @buf[@b_line + (e2 >> 3)] & (0x80_u8 >> (e2 & 7)) != 0
        end

        if e1 >= 0 && e1 <= @b_right
          @buf[@b_line + (e1 >> 3)] |= 0x80_u8 >> (e1 & 7)
        end
      end
    end

    private def sweep_step : Nil
      @b_line -= @b_pitch unless @horizontal
    end

    # --- single pass with sub-banding -----------------------------------------

    private def render_single_pass(flipped : Int32, y_min_in : Int32, y_max_in : Int32) : Nil
      y_min = y_min_in
      y_max = y_max_in
      band_stack = StaticArray(Int32, 32).new(0)
      band_top = 0

      loop do
        @min_y = y_min.to_i64 &* @precision
        @max_yl = y_max.to_i64 &* @precision

        @err = ERR_OK

        if convert_glyph
          draw_sweep if @f_profile >= 0

          band_top -= 1
          break if band_top < 0

          y_max = y_min - 1
          y_min = band_stack[band_top]
        else
          return if @err != ERR_OVERFLOW
          return if y_min == y_max # still Raster_Overflow

          y_mid = (y_min + y_max) >> 1

          band_stack[band_top] = y_min
          band_top += 1
          y_min = y_mid + 1
        end
      end
    end
  end
end

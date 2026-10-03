# Type 2 charstring interpreter for unhinted CFF glyph loading — a port
# of the Adobe engine subset FreeType runs for FT_LOAD_NO_HINTING with
# stem darkening disabled:
#
#   - `psintrp.c' cf2_interpT2CharString: operand stack (typed
#     int/fixed like CF2), width parsing, all path/arithmetic operators,
#     subr nesting, storage, the xorshift `random', seac via endchar;
#   - `pshints.c' cf2_glyphpath reduced to the no-hint/no-darken mode:
#     a queue of one path element, zero-length line removal, synthesized
#     closes, and the CS->DS map (at unhinted "unity" scale 1/64 the
#     emitted 16.16 value truncated by >>10 is numerically the font-unit
#     coordinate; `cff_slot_load' scales afterwards — see face.cr);
#   - `psobjs.c' ps_builder_*: the outline callbacks (start/close
#     contour, coincident-endpoint and single-point contour trimming).
#
# 32-bit wrapping arithmetic (ADD_INT32 et al.) is carried over: the VM
# works on 16.16 Int32 values stored in Int64 with explicit i32 wraps.

require "./cffload"
require "./cffhints"

module CFF
  class InterpError < Exception
  end

  # Opcode tracer (CFF_TRACE=1), the TT_TRACE counterpart: per-opcode
  # dump of the VM state, zero cost when the flag is off.
  def self.trace? : Bool
    @@trace = ENV["CFF_TRACE"]? == "1" unless @@trace_resolved
    @@trace_resolved = true
    @@trace
  end

  def self.trace(msg : String) : Nil
    STDERR.puts msg
  end

  @@trace = false
  @@trace_resolved = false

  # Outline accumulator: the cf2_builder_* callbacks + ps_builder_*.
  # Points arrive as 16.16 device values and are stored `>> 10' (the
  # Adobe-engine branch of ps_builder_add_point), which at the unhinted
  # unity scale leaves plain font-unit coordinates.
  class Builder
    getter xs : Array(Int64) = [] of Int64
    getter ys : Array(Int64) = [] of Int64
    getter tags : Array(UInt8) = [] of UInt8
    getter contours : Array(Int32) = [] of Int32 # inclusive end index
    property? path_begun : Bool = false

    def move_to(x : Int64, y : Int64) : Nil
      # cf2_builder_moveTo: two successive moves close the contour twice.
      close_contour
      @path_begun = false
    end

    def line_to(x0 : Int64, y0 : Int64, x1 : Int64, y1 : Int64) : Nil
      unless @path_begun
        start_point(x0, y0)
      end
      add_point(x1, y1, 1_u8)
    end

    def cube_to(x0, y0, x1, y1, x2, y2, x3, y3) : Nil
      unless @path_begun
        start_point(x0, y0)
      end
      add_point(x1, y1, 2_u8)
      add_point(x2, y2, 2_u8)
      add_point(x3, y3, 1_u8)
    end

    private def start_point(x : Int64, y : Int64) : Nil
      @path_begun = true
      # ps_builder_add_contour: finalize the previous contour's end.
      @contours[@contours.size - 1] = @xs.size - 1 if @contours.size > 0
      @contours << @xs.size
      add_point(x, y, 1_u8)
    end

    private def add_point(x : Int64, y : Int64, tag : UInt8) : Nil
      @xs << (x >> 10)
      @ys << (y >> 10)
      @tags << tag
    end

    # ps_builder_close_contour.
    def close_contour : Nil
      first = @contours.size <= 1 ? 0 : @contours[@contours.size - 2] + 1

      # A contour was started but no points were added.
      if !@contours.empty? && first == @xs.size
        @contours.pop
        return
      end

      # Don't include the last point if it coincides with the first and
      # is an on-curve point.
      if @xs.size > 1
        if @xs[first] == @xs[@xs.size - 1] && @ys[first] == @ys[@ys.size - 1] &&
           @tags[@tags.size - 1] == 1_u8
          @xs.pop; @ys.pop; @tags.pop
        end
      end

      unless @contours.empty?
        if first == @xs.size - 1
          # A contour of a single point: drop it entirely.
          @contours.pop
          @xs.pop; @ys.pop; @tags.pop
        else
          @contours[@contours.size - 1] = @xs.size - 1
        end
      end
    end
  end

  # The cf2_GlyphPath: coordinates are CS 16.16, the map to DS is
  # FT_MulFix by the unity scale 1/64 (0x0400) in unhinted mode, or a
  # real hint map per subpath/hint-substitution zone in hinted mode.
  # Darkening (offsets, intersections, winding) is not part of this
  # port: with darken == FALSE the offsets are zero and the joins are
  # contiguous, so the intersection machinery never fires.
  class GlyphPath
    getter hint_scale : Int64 # the hint map scale (innerTransform.d)
    getter initial_hint_map : HintMap?
    getter blues : Blues?

    @scale_x : Int64
    @hinted : Bool
    @hint_map : HintMap?
    @first_hint_map : HintMap?
    @mask : HintMask?
    @h_stems : Array(StemHint)?
    @v_stems : Array(StemHint)?
    @blues : Blues?
    @hint_origin_y : Int64 = 0_i64

    def initialize(@builder : Builder, hinted : Bool = false,
                   scale_x : Int64 = 0x0400_i64, scale_y : Int64 = 0x0400_i64,
                   h_stems : Array(StemHint)? = nil,
                   v_stems : Array(StemHint)? = nil,
                   mask : HintMask? = nil, blues : Blues? = nil,
                   hint_origin_y : Int64 = 0_i64)
      @hinted = hinted
      @scale_x = scale_x
      @scale_y = scale_y
      @hint_scale = scale_y
      @h_stems = h_stems
      @v_stems = v_stems
      @mask = mask
      @blues = blues
      @hint_origin_y = hint_origin_y
      @scale = scale_y
      if hinted
        # One initial map shared by the working, first and counter maps
        # (cf2_glyphpath_init links them all to initialHintMap).
        @initial_hint_map = HintMap.new(scale_y)
        @hint_map = HintMap.new(scale_y, @initial_hint_map)
        @first_hint_map = HintMap.new(scale_y, @initial_hint_map)
      end
      @start = {0_i64, 0_i64}
      @current_cs = {0_i64, 0_i64}
      @current_ds = {0_i64, 0_i64}
      @offset_start0 = {0_i64, 0_i64}
      @offset_start1 = {0_i64, 0_i64}
      @prev_p0 = {0_i64, 0_i64}
      @prev_p1 = {0_i64, 0_i64}
      @prev_p2 = {0_i64, 0_i64}
      @prev_p3 = {0_i64, 0_i64}
      @prev_op = :line
      @move_is_pending = false
      @path_is_open = false
      @path_is_closing = false
      @elem_is_queued = false
      @hintmap_valid = !hinted
    end

    def reset_hint_state(h_stems : Array(StemHint), v_stems : Array(StemHint),
                         mask : HintMask, blues : Blues,
                         hint_origin_y : Int64) : Nil
      return unless @hinted
      @h_stems = h_stems
      @v_stems = v_stems
      @mask = mask
      @blues = blues
      @hint_origin_y = hint_origin_y
      @initial_hint_map = HintMap.new(@scale_y)
      @hint_map = HintMap.new(@scale_y, @initial_hint_map)
      @first_hint_map = HintMap.new(@scale_y, @initial_hint_map)
      @hintmap_valid = false
      @move_is_pending = true
      @path_is_open = false
      @path_is_closing = false
      @elem_is_queued = false
      @current_cs = {0_i64, 0_i64}
      @start = {0_i64, 0_i64}
    end

    def move_to(x : Int64, y : Int64) : Nil
      close_open_path
      @start = {x, y}
      @current_cs = {x, y}
      @move_is_pending = true
      if (hm = @hint_map) && (m = @mask)
        hm.build(@h_stems.not_nil!, @v_stems.not_nil!, m,
                 @hint_origin_y, false, @blues.not_nil!) \
          unless hm.valid && !m.is_new
        @first_hint_map.not_nil!.copy_from(hm)
      end
      @hintmap_valid = true # moveTo builds the hint map
    end

    def line_to(x : Int64, y : Int64) : Nil
      new_hint_map = false
      if (m = @mask)
        new_hint_map = m.is_new && !@path_is_closing
      end
      # Ignore zero-length lines when the hint map is unchanged.
      return if @current_cs == {x, y} && !new_hint_map

      if @move_is_pending
        push_move(@current_cs)
        @move_is_pending = false
        @path_is_open = true
        @offset_start1 = {x, y}
      end

      push_prev_elem(@current_cs, false) if @elem_is_queued

      @elem_is_queued = true
      @prev_op = :line
      @prev_p0 = @current_cs
      @prev_p1 = {x, y}
      @current_cs = {x, y}

      if new_hint_map && (hm = @hint_map) && (m = @mask)
        hm.build(@h_stems.not_nil!, @v_stems.not_nil!, m,
                 @hint_origin_y, false, @blues.not_nil!)
      end
    end

    def curve_to(x1, y1, x2, y2, x3, y3) : Nil
      if @move_is_pending
        push_move(@current_cs)
        @move_is_pending = false
        @path_is_open = true
        @offset_start1 = {x1, y1}
      end

      push_prev_elem(@current_cs, false) if @elem_is_queued

      @elem_is_queued = true
      @prev_op = :cube
      @prev_p0 = @current_cs
      @prev_p1 = {x1, y1}
      @prev_p2 = {x2, y2}
      @prev_p3 = {x3, y3}
      @current_cs = {x3, y3}

      if (hm = @hint_map) && (m = @mask) && m.is_new
        hm.build(@h_stems.not_nil!, @v_stems.not_nil!, m,
                 @hint_origin_y, false, @blues.not_nil!)
      end
    end

    def close_open_path : Nil
      return unless @path_is_open

      @path_is_closing = true
      line_to(@start[0], @start[1])

      if @elem_is_queued
        push_prev_elem(@offset_start0, true)
      end

      @move_is_pending = true
      @path_is_open = false
      @path_is_closing = false
      @elem_is_queued = false
    end

    private def hint_point(x : Int64, y : Int64,
                           map : HintMap? = nil) : {Int64, Int64}
      if hm = map
        # cf2_glyphpath_hintPoint with outer transform identity and a
        # zero fractional translation.
        {Fixed.mulfix(@scale_x, x), hm.map(y)}
      else
        {Fixed.mulfix(x, @scale), Fixed.mulfix(y, @scale)}
      end
    end

    private def push_move(start : {Int64, Int64}) : Nil
      unless @hintmap_valid
        # First subpath missing a moveto: synthesize one at `start'.
        move_to(@start[0], @start[1])
      end
      pt1 = hint_point(start[0], start[1], @hint_map)
      @builder.move_to(pt1[0], pt1[1])
      @current_ds = pt1
      @offset_start0 = start
    end

    private def push_prev_elem(next_p0 : {Int64, Int64}, close : Bool) : Nil
      # Unhinted/undarkened: offsets are zero and elements are contiguous,
      # so the join-intersection machinery of cf2_glyphpath_pushPrevElem
      # never fires (prevP1 == nextP0 and useIntersection stays FALSE).
      pt0 = @current_ds
      first_map = close ? @first_hint_map : nil

      case @prev_op
      when :line
        pt1 = hint_point(@prev_p1[0], @prev_p1[1], first_map || @hint_map)
        if pt0 != pt1
          @builder.line_to(pt0[0], pt0[1], pt1[0], pt1[1])
          @current_ds = pt1
        end
      when :cube
        pt1 = hint_point(@prev_p1[0], @prev_p1[1], @hint_map)
        pt2 = hint_point(@prev_p2[0], @prev_p2[1], @hint_map)
        pt3 = hint_point(@prev_p3[0], @prev_p3[1], @hint_map)
        @builder.cube_to(pt0[0], pt0[1], pt1[0], pt1[1],
                         pt2[0], pt2[1], pt3[0], pt3[1])
        @current_ds = pt3
      end

      # Connecting line from the end of the previous element to nextP0
      # (always evaluated when closing; zero-length otherwise).
      pt1c = hint_point(next_p0[0], next_p0[1], first_map || @hint_map)
      if pt1c != @current_ds
        @builder.line_to(@current_ds[0], @current_ds[1], pt1c[0], pt1c[1])
        @current_ds = pt1c
      end
    end
  end

  # cf2_stack: operand stack with typed entries.
  private class OpStack
    struct Num
      getter type : Int8 # 0 = fixed, 2 = int (CF2 enum order)
      getter i : Int32   # int payload
      getter r : Int64   # 16.16 payload

      def self.int(v : Int32)
        new(2_i8, v, v.to_i64 << 16)
      end

      def self.fixed(v : Int64)
        new(0_i8, 0, v)
      end

      def initialize(@type, @i, @r)
      end

      def int? : Int32?
        @type == 2 ? @i : nil
      end

      def real : Int64
        @type == 2 ? @i.to_i64 << 16 : @r
      end
    end

    getter vals : Array(Num) = [] of Num
    property error : String? = nil

    def size : Int32
      @vals.size
    end

    def clear : Nil
      @vals.clear
    end

    def push_int(v : Int32) : Nil
      if @vals.size >= 48
        CFF.trace("stack overflow push_int(#{v})") if CFF.trace?
        @error = "stack overflow"
        return
      end
      @vals << Num.int(v)
    end

    def push_fixed(v : Int64) : Nil
      if @vals.size >= 48
        CFF.trace("stack overflow push_fixed(#{v})") if CFF.trace?
        @error = "stack overflow"
        return
      end
      @vals << Num.fixed(v)
    end

    def pop_int : Int32
      n = @vals.pop? || begin
        @error = "stack underflow"
        return 0
      end
      unless v = n.int?
        @error = "type mismatch"
        return 0
      end
      v
    end

    def pop_fixed : Int64
      n = @vals.pop? || begin
        @error = "stack underflow"
        return 0_i64
      end
      n.real
    end

    def get_real(idx : Int32) : Int64
      n = @vals[idx]? || begin
        @error = "stack overflow"
        return 0_i64
      end
      n.real
    end

    def set_real(idx : Int32, v : Int64) : Nil
      if n = @vals[idx]?
        @vals[idx] = Num.fixed(v)
      else
        @error = "stack overflow"
      end
    end

    def roll(count : Int32, shift : Int32) : Nil
      return if count < 2
      if count > @vals.size
        @error = "stack overflow"
        return
      end

      if shift < 0
        shift = -((-shift) % count)
      else
        shift %= count
      end
      return if shift == 0

      offset = @vals.size - count
      region = @vals[offset, count]
      count.times do |i|
        @vals[offset + i] = region[(i + shift) % count]
      end
    end
  end

  # One charstring (or subroutine) being read. A class: the interpreter
  # holds it via the buffers array and mutates the read position.
  private class Buf
    property pos : Int32
    getter end_pos : Int32

    def initialize(@data : Bytes, @start : Int32, @end_pos : Int32)
      @pos = @start
    end

    def done? : Bool
      @pos >= @end_pos
    end

    def read_byte : UInt8
      raise InterpError.new("charstring read past end") if @pos >= @end_pos
      v = CFF.u8(@data, @pos)
      @pos += 1
      v
    end

    def skip(n : Int32) : Nil
      @pos += n
    end
  end

  # 32-bit wrapping helpers (ADD_INT32/SUB_INT32 on CF2_Fixed).
  private def self.i32(v : Int64) : Int64
    v.to_i32!.to_i64
  end

  def self.add32(a : Int64, b : Int64) : Int64
    i32(a &+ b)
  end

  def self.sub32(a : Int64, b : Int64) : Int64
    i32(a &- b)
  end

  # FT_SqrtFixed (ftcalc.c, INT64 path): sqrt of a 16.16 value.
  def self.sqrt_fixed(v : UInt32) : UInt32
    return 0_u32 if v == 0
    r = (v.to_u64 << 16) - 1
    q = 1_u32 << ((17 + (31 - v.leading_zeros_count)) >> 1)
    loop do
      t = q
      q = (t + (r // t).to_u32! + 1) >> 1
      break if q == t
    end
    q
  end

  # The interpreter. One instance per glyph run.
  class Interpreter
    @font : Font
    @data : Bytes
    @builder : Builder
    @path : GlyphPath
    @stack : OpStack
    @subfont : SubFont
    @storage : Array(Int64)
    @buffers : Array(Buf)
    @cur_x : Int64 = 0_i64
    @cur_y : Int64 = 0_i64
    @have_width : Bool = false
    @width : Int64 = 0_i64
    @h_stems : Int32 = 0
    @v_stems : Int32 = 0
    @hintmask_valid : Bool = false
    @instruction_limit : UInt32 = 20_000_000_u32
    # Hinted engine state (cff_interpT2CharString's hint objects).
    @hinted : Bool = false
    @hint_scale : Int64 = 0x0400_i64
    @h_stem_hints : Array(StemHint) = [] of StemHint
    @v_stem_hints : Array(StemHint) = [] of StemHint
    @hint_mask : HintMask = HintMask.new
    @hint_origin_y : Int64 = 0_i64

    private def add32(a : Int64, b : Int64) : Int64
      CFF.add32(a, b)
    end

    private def sub32(a : Int64, b : Int64) : Int64
      CFF.sub32(a, b)
    end

    def initialize(font : Font, builder : Builder, @subfont : SubFont,
                   hinted : Bool = false, scale : Int64 = 0x0400_i64)
      @font = font
      @data = font.data
      @builder = builder
      @hinted = hinted
      @hint_scale = scale
      if hinted
        @path = GlyphPath.new(builder, hinted: true, scale_x: scale,
                              scale_y: scale, h_stems: @h_stem_hints,
                              v_stems: @v_stem_hints, mask: @hint_mask,
                              blues: Blues.new(@subfont, scale))
      else
        @path = GlyphPath.new(builder)
      end
      @stack = OpStack.new
      @storage = Array(Int64).new(32, 0_i64)
      @buffers = [] of Buf
    end

    # Run one glyph charstring; returns the width in font units
    # (cf2_setGlyphWidth's cf2_fixedToInt of the accumulated value).
    def run(start : Int32, len : Int32, doing_seac : Bool,
            cur_x : Int64, cur_y : Int64) : Int32
      @buffers = [Buf.new(@data, start, start + len)]
      @cur_x = cur_x
      @cur_y = cur_y
      @have_width = false
      @width = @subfont.default_width << 16
      @h_stems = 0
      @v_stems = 0
      @hintmask_valid = false
      if @hinted
        @h_stem_hints.clear
        @v_stem_hints.clear
        @hint_mask = HintMask.new
        @path.reset_hint_state(@h_stem_hints, @v_stem_hints, @hint_mask,
                               Blues.new(@subfont, @path.hint_scale), cur_y)
      end

      interpret(doing_seac)
      # cf2_setGlyphWidth: *decoder->glyph_width = cf2_fixedToInt(width)
      ((@width.to_u32! &+ 0x8000_u32) >> 16).to_u16.to_i16.to_i32
    end

    private def buf : Buf
      @buffers[@buffers.size - 1]
    end

    private def check_stack_error : Nil
      if e = @stack.error
        raise InterpError.new(e)
      end
    end

    private def interpret(doing_seac : Bool) : Nil
      while true
        op1 : Int32
        if buf.done?
          op1 = @buffers.size > 1 ? 11 : 14 # RETURN / ENDCHAR
        else
          op1 = buf.read_byte.to_i32
        end

        @instruction_limit &-= 1
        raise InterpError.new("instruction limit") if @instruction_limit == 0

        if CFF.trace?
          pos = buf.pos - 1
          CFF.trace("lvl=#{@buffers.size - 1} pos=#{pos} op=#{op1} " \
                    "nstack=#{@stack.size} cur=#{@cur_x},#{@cur_y}")
        end

        case op1
        when 0, 2, 17, 9, 13 # reserved (9/13: T1-only ops)
          # unknown op — clear the stack
        when 15 # vsindex: CFF1 ignores
        when 16 # blend: CFF1 ignores
        when 1, 18 # hstem, hstemhm
          if @hintmask_valid
            # never add hints after the mask is computed
          else
            @h_stems = do_stems(@h_stems, @hinted ? @h_stem_hints : nil)
          end
        when 3, 23 # vstem, vstemhm
          if @hintmask_valid
            # invalid
          else
            @v_stems = do_stems(@v_stems, @hinted ? @v_stem_hints : nil)
          end
        when 4 # vmoveto
          if @stack.size > 1 && !@have_width
            @width = add32(@stack.get_real(0), @subfont.nominal_width << 16)
          end
          @have_width = true
          @cur_y = add32(@cur_y, @stack.pop_fixed)
          @path.move_to(@cur_x, @cur_y)
          check_stack_error
        when 5 # rlineto
          idx = 0
          count = @stack.size
          while idx + 2 <= count
            @cur_x = add32(@cur_x, @stack.get_real(idx))
            @cur_y = add32(@cur_y, @stack.get_real(idx + 1))
            @path.line_to(@cur_x, @cur_y)
            idx += 2
          end
          @stack.clear
          next
        when 6, 7 # hlineto, vlineto
          is_x = op1 == 6
          @stack.size.times do |idx|
            v = @stack.get_real(idx)
            if is_x
              @cur_x = add32(@cur_x, v)
            else
              @cur_y = add32(@cur_y, v)
            end
            is_x = !is_x
            @path.line_to(@cur_x, @cur_y)
          end
          @stack.clear
          next
        when 8, 24 # rrcurveto, rcurveline
          count = @stack.size
          idx = 0
          while idx + 6 <= count
            x1 = add32(@stack.get_real(idx + 0), @cur_x)
            y1 = add32(@stack.get_real(idx + 1), @cur_y)
            x2 = add32(@stack.get_real(idx + 2), x1)
            y2 = add32(@stack.get_real(idx + 3), y1)
            x3 = add32(@stack.get_real(idx + 4), x2)
            y3 = add32(@stack.get_real(idx + 5), y2)
            @path.curve_to(x1, y1, x2, y2, x3, y3)
            @cur_x = x3
            @cur_y = y3
            idx += 6
          end
          if op1 == 24 # rcurveline
            @cur_x = add32(@cur_x, @stack.get_real(idx))
            @cur_y = add32(@cur_y, @stack.get_real(idx + 1))
            @path.line_to(@cur_x, @cur_y)
          end
          @stack.clear
          next
        when 10, 29 # callsubr, callgsubr
          if @buffers.size >= 16
            raise InterpError.new("subr nesting overflow")
          end
          subr_num = @stack.pop_int
          check_stack_error

          if op1 == 29
            idx = subr_num + CFF.subr_bias(@font.global_subrs.count)
            entry = @font.global_subrs.element(@data, idx)
          else
            subrs = @subfont.local_subrs
            raise InterpError.new("no local subrs") unless subrs
            idx = subr_num + CFF.subr_bias(subrs.count)
            entry = subrs.element(@data, idx)
          end
          raise InterpError.new("subr lookup") unless entry
          @buffers << Buf.new(@data, entry[0], entry[0] + entry[1])
          next
        when 11 # return
          if @buffers.size < 2
            raise InterpError.new("return from top level")
          end
          @buffers.pop
          next
        when 14 # endchar
          if @stack.size == 1 || @stack.size == 5
            unless @have_width
              @width = add32(@stack.get_real(0), @subfont.nominal_width << 16)
            end
          end
          @have_width = true

          @path.close_open_path

          if @stack.size > 1 # implied seac
            raise InterpError.new("nested seac") if doing_seac
            if @stack.size != 4 && @stack.size != 5
              raise InterpError.new("bad endchar arg count")
            end
            achar = @stack.pop_int
            bchar = @stack.pop_int
            check_stack_error
            @cur_y = @stack.pop_fixed
            @cur_x = @stack.pop_fixed

            run_seac_component(achar)
            run_seac_component(bchar)
          end
          return
        when 19, 20 # hintmask, cntrmask
          if @stack.size > 1 && @hintmask_valid
            # invalid hint mask: do not consume the mask bytes
          else
            # Implied vstemhm: parse the width, collect the stems.
            @v_stems = do_stems(@v_stems, @hinted ? @v_stem_hints : nil)
            mask_len = (@h_stems + @v_stems + 7) // 8
            raise InterpError.new("too many hints") if @h_stems + @v_stems > 96
            raise InterpError.new("hint mask past end") if buf.pos + mask_len > buf.end_pos
            if @hinted
              if op1 == 19
                @hint_mask.read(buf, @h_stems + @v_stems)
              else
                # cntrmask: read into a separate mask, then build a throw-
                # away hint map to place and lock the counters' stems.
                counter_mask = HintMask.new
                counter_mask.read(buf, @h_stems + @v_stems)
                counter_map = HintMap.new(@path.hint_scale)
                counter_map.initial_map = @path.initial_hint_map
                counter_map.build(@h_stem_hints, @v_stem_hints, counter_mask,
                                  0_i64, false, @path.blues.not_nil!)
              end
            else
              buf.skip(mask_len)
            end
            # Only the hintmask operator validates the (real) mask; a
            # cntrmask reads into a separate struct (cf2_hintmask_read on
            # counterMask), leaving hintMask itself invalid.
            @hintmask_valid = true if op1 == 19
          end
        when 21 # rmoveto
          if @stack.size > 2 && !@have_width
            @width = add32(@stack.get_real(0), @subfont.nominal_width << 16)
          end
          @have_width = true
          @cur_y = add32(@cur_y, @stack.pop_fixed)
          @cur_x = add32(@cur_x, @stack.pop_fixed)
          @path.move_to(@cur_x, @cur_y)
          check_stack_error
        when 22 # hmoveto
          if @stack.size > 1 && !@have_width
            @width = add32(@stack.get_real(0), @subfont.nominal_width << 16)
          end
          @have_width = true
          @cur_x = add32(@cur_x, @stack.pop_fixed)
          @path.move_to(@cur_x, @cur_y)
          check_stack_error
        when 25 # rlinecurve
          count = @stack.size
          idx = 0
          while idx + 6 < count
            @cur_x = add32(@cur_x, @stack.get_real(idx + 0))
            @cur_y = add32(@cur_y, @stack.get_real(idx + 1))
            @path.line_to(@cur_x, @cur_y)
            idx += 2
          end
          while idx < count
            x1 = add32(@stack.get_real(idx + 0), @cur_x)
            y1 = add32(@stack.get_real(idx + 1), @cur_y)
            x2 = add32(@stack.get_real(idx + 2), x1)
            y2 = add32(@stack.get_real(idx + 3), y1)
            x3 = add32(@stack.get_real(idx + 4), x2)
            y3 = add32(@stack.get_real(idx + 5), y2)
            @path.curve_to(x1, y1, x2, y2, x3, y3)
            @cur_x = x3
            @cur_y = y3
            idx += 6
          end
          @stack.clear
          next
        when 26 # vvcurveto
          count1 = @stack.size
          count = count1 & ~2
          idx = count1 - count
          while idx < count
            if (count - idx) & 1 == 1
              x1 = add32(@stack.get_real(idx), @cur_x)
              idx += 1
            else
              x1 = @cur_x
            end
            y1 = add32(@stack.get_real(idx + 0), @cur_y)
            x2 = add32(@stack.get_real(idx + 1), x1)
            y2 = add32(@stack.get_real(idx + 2), y1)
            x3 = x2
            y3 = add32(@stack.get_real(idx + 3), y2)
            @path.curve_to(x1, y1, x2, y2, x3, y3)
            @cur_x = x3
            @cur_y = y3
            idx += 4
          end
          @stack.clear
          next
        when 27 # hhcurveto
          count1 = @stack.size
          count = count1 & ~2
          idx = count1 - count
          while idx < count
            if (count - idx) & 1 == 1
              y1 = add32(@stack.get_real(idx), @cur_y)
              idx += 1
            else
              y1 = @cur_y
            end
            x1 = add32(@stack.get_real(idx + 0), @cur_x)
            x2 = add32(@stack.get_real(idx + 1), x1)
            y2 = add32(@stack.get_real(idx + 2), y1)
            x3 = add32(@stack.get_real(idx + 3), x2)
            y3 = y2
            @path.curve_to(x1, y1, x2, y2, x3, y3)
            @cur_x = x3
            @cur_y = y3
            idx += 4
          end
          @stack.clear
          next
        when 28 # 16-bit integer
          b1 = buf.read_byte.to_i32
          b2 = buf.read_byte.to_i32
          @stack.push_int(((b1 << 8) | b2).to_i16!.to_i32)
          check_stack_error
          next
        when 30, 31 # vhcurveto, hvcurveto
          count1 = @stack.size
          count = count1 & ~2
          idx = count1 - count
          alternate = op1 == 31
          while idx < count
            if alternate
              x1 = add32(@stack.get_real(idx + 0), @cur_x)
              y1 = @cur_y
              x2 = add32(@stack.get_real(idx + 1), x1)
              y2 = add32(@stack.get_real(idx + 2), y1)
              y3 = add32(@stack.get_real(idx + 3), y2)
              if count - idx == 5
                x3 = add32(@stack.get_real(idx + 4), x2)
                idx += 1
              else
                x3 = x2
              end
              alternate = false
            else
              x1 = @cur_x
              y1 = add32(@stack.get_real(idx + 0), @cur_y)
              x2 = add32(@stack.get_real(idx + 1), x1)
              y2 = add32(@stack.get_real(idx + 2), y1)
              x3 = add32(@stack.get_real(idx + 3), x2)
              if count - idx == 5
                y3 = add32(@stack.get_real(idx + 4), y2)
                idx += 1
              else
                y3 = y2
              end
              alternate = true
            end
            @path.curve_to(x1, y1, x2, y2, x3, y3)
            @cur_x = x3
            @cur_y = y3
            idx += 4
          end
          @stack.clear
          next
        when 12 # escape: two-byte operators
          op2 = buf.read_byte.to_i32
          case op2
          when 34 # hflex
            flex_read = {true, false, true, true, true, false,
                         true, false, true, false, true, false}
            do_flex(flex_read, false)
            next
          when 35 # flex
            flex_read = {true, true, true, true, true, true,
                         true, true, true, true, true, true}
            do_flex(flex_read, false)
            # C uses `break' here (stack is cleared below).
          when 36 # hflex1
            flex_read = {true, true, true, true, true, false,
                         true, false, true, true, true, false}
            do_flex(flex_read, false)
            next
          when 37 # flex1
            flex_read = {true, true, true, true, true, true,
                         true, true, true, true, false, false}
            do_flex(flex_read, true)
            next
          when 8, 13, 19, 25, 31, 32
            # reserved
          when 0 # dotsection: ignore
          when 1, 2 # vstem3/hstem3: T1 only, unknown here
          when 3 # and
            arg2 = @stack.pop_fixed
            arg1 = @stack.pop_fixed
            @stack.push_int(arg1 != 0 && arg2 != 0 ? 1 : 0)
            check_stack_error
            next
          when 4 # or
            arg2 = @stack.pop_fixed
            arg1 = @stack.pop_fixed
            @stack.push_int(arg1 != 0 || arg2 != 0 ? 1 : 0)
            check_stack_error
            next
          when 5 # not
            arg = @stack.pop_fixed
            @stack.push_int(arg == 0 ? 1 : 0)
            check_stack_error
            next
          when 9 # abs
            arg = @stack.pop_fixed
            if arg < -0x7FFF_FFFF_i64
              @stack.push_fixed(0x7FFF_FFFF_i64)
            else
              @stack.push_fixed(arg < 0 ? -arg : arg)
            end
            check_stack_error
            next
          when 10 # add
            s2 = @stack.pop_fixed
            s1 = @stack.pop_fixed
            @stack.push_fixed(add32(s1, s2))
            check_stack_error
            next
          when 11 # sub
            s2 = @stack.pop_fixed
            s1 = @stack.pop_fixed
            @stack.push_fixed(sub32(s1, s2))
            check_stack_error
            next
          when 12 # div
            divisor = @stack.pop_fixed
            dividend = @stack.pop_fixed
            @stack.push_fixed(Fixed.divfix(dividend, divisor))
            check_stack_error
            next
          when 14 # neg
            arg = @stack.pop_fixed
            if arg < -0x7FFF_FFFF_i64
              @stack.push_fixed(0x7FFF_FFFF_i64)
            else
              @stack.push_fixed(-arg)
            end
            check_stack_error
            next
          when 15 # eq
            arg2 = @stack.pop_fixed
            arg1 = @stack.pop_fixed
            @stack.push_int(arg1 == arg2 ? 1 : 0)
            check_stack_error
            next
          when 18 # drop
            @stack.pop_fixed
            check_stack_error
            next
          when 20 # put
            idx = @stack.pop_int
            val = @stack.pop_fixed
            @storage[idx] = val if idx >= 0 && idx < 32
            check_stack_error
            next
          when 21 # get
            idx = @stack.pop_int
            @stack.push_fixed(idx >= 0 && idx < 32 ? @storage[idx] : 0_i64)
            check_stack_error
            next
          when 22 # ifelse
            cond2 = @stack.pop_fixed
            cond1 = @stack.pop_fixed
            arg2 = @stack.pop_fixed
            arg1 = @stack.pop_fixed
            @stack.push_fixed(cond1 <= cond2 ? arg1 : arg2)
            check_stack_error
            next
          when 23 # random
            r = ((@subfont.random & 0xFFFF_u32) + 1).to_i64
            @subfont.random = CFF.cff_random(@subfont.random)
            @stack.push_fixed(r)
            check_stack_error
            next
          when 24 # mul
            f2 = @stack.pop_fixed
            f1 = @stack.pop_fixed
            @stack.push_fixed(Fixed.mulfix(f1, f2))
            check_stack_error
            next
          when 26 # sqrt
            arg = @stack.pop_fixed
            arg = arg > 0 ? CFF.sqrt_fixed(arg.to_u32!).to_i64 : 0_i64
            @stack.push_fixed(arg)
            check_stack_error
            next
          when 27 # dup
            arg = @stack.pop_fixed
            @stack.push_fixed(arg)
            @stack.push_fixed(arg)
            check_stack_error
            next
          when 28 # exch
            arg2 = @stack.pop_fixed
            arg1 = @stack.pop_fixed
            @stack.push_fixed(arg2)
            @stack.push_fixed(arg1)
            check_stack_error
            next
          when 29 # index
            idx = @stack.pop_int
            size = @stack.size
            if size > 0
              gr_idx = if idx < 0
                size - 1
              elsif idx >= size
                0
              else
                size - 1 - idx
              end
              @stack.push_fixed(@stack.get_real(gr_idx))
            end
            check_stack_error
            next
          when 30 # roll
            shift = @stack.pop_int
            count = @stack.pop_int
            @stack.roll(count, shift)
            check_stack_error
            next
          else
            # 6,7 (seac/sbw: T1 only), 16,17 (callothersubr/pop), 33
            # (setcurrentpoint) and everything >= 38: unknown for CFF.
          end
        else # numbers
          if op1 <= 246
            @stack.push_int(op1 - 139)
            check_stack_error
            next
          elsif op1 <= 250
            b = buf.read_byte.to_i32
            @stack.push_int((op1 - 247) * 256 + b + 108)
            check_stack_error
            next
          elsif op1 <= 254
            b = buf.read_byte.to_i32
            @stack.push_int(-((op1 - 251) * 256 + b) - 108)
            check_stack_error
            next
          else # 255: 16.16 fixed
            b1 = buf.read_byte.to_u32
            b2 = buf.read_byte.to_u32
            b3 = buf.read_byte.to_u32
            b4 = buf.read_byte.to_u32
            v = ((b1 << 24) | (b2 << 16) | (b3 << 8) | b4).to_i32!.to_i64
            @stack.push_fixed(v)
            check_stack_error
            next
          end
        end

        @stack.clear
      end
    end

    # cf2_doStems: width parsing plus stem hint collection — unhinted
    # mode only keeps the counts (for the mask byte lengths), hinted
    # mode pushes real CF2_StemHint records with delta positions.
    private def do_stems(stems : Int32, into : Array(StemHint)?) : Int32
      count = @stack.size
      has_width_arg = (count & 1) == 1

      if has_width_arg && !@have_width
        @width = add32(@stack.get_real(0), @subfont.nominal_width << 16)
      end
      @have_width = true

      added = 0
      position = 0_i64
      i = has_width_arg ? 1 : 0
      while i + 1 < count
        min = position = add32(position, @stack.get_real(i))
        max = position = add32(position, @stack.get_real(i + 1))
        into << StemHint.new(min, max) if into
        added += 1
        i += 2
      end
      @stack.clear
      stems + added
    end

    # cf2_doFlex.
    private def do_flex(read_from_stack : Tuple(Bool, Bool, Bool, Bool, Bool, Bool,
                                                Bool, Bool, Bool, Bool, Bool, Bool),
                        conditional_last_read : Bool) : Nil
      vals = StaticArray(Int64, 14).new(0_i64)
      vals[0] = @cur_x
      vals[1] = @cur_y
      idx = 0
      is_hflex = !read_from_stack[9]
      top = is_hflex ? 9 : 10

      i = 0
      while i < top
        vals[i + 2] = vals[i]
        if read_from_stack[i]
          vals[i + 2] = add32(vals[i + 2], @stack.get_real(idx))
          idx += 1
        end
        i += 1
      end

      vals[9 + 2] = @cur_y if is_hflex

      if conditional_last_read
        last_is_x = sub32(vals[10], @cur_x).abs > sub32(vals[11], @cur_y).abs
        last_val = @stack.get_real(idx)
        if last_is_x
          vals[12] = add32(vals[10], last_val)
          vals[13] = @cur_y
        else
          vals[12] = @cur_x
          vals[13] = add32(vals[11], last_val)
        end
      else
        if read_from_stack[10]
          vals[12] = add32(vals[10], @stack.get_real(idx))
          idx += 1
        else
          vals[12] = @cur_x
        end
        if read_from_stack[11]
          vals[13] = add32(vals[11], @stack.get_real(idx))
        else
          vals[13] = @cur_y
        end
      end

      2.times do |j|
        @path.curve_to(vals[j * 6 + 2], vals[j * 6 + 3],
                       vals[j * 6 + 4], vals[j * 6 + 5],
                       vals[j * 6 + 6], vals[j * 6 + 7])
      end

      @stack.clear
      @cur_x = vals[12]
      @cur_y = vals[13]
    end

    # A seac component: Adobe Standard Encoding code -> charstring.
    private def run_seac_component(code : Int32) : Nil
      gid = @font.glyph_by_stdcharcode(code)
      raise InterpError.new("seac component lookup") if gid < 0
      entry = @font.charstring(gid)
      raise InterpError.new("seac component charstring") unless entry

      x0, y0 = @cur_x, @cur_y
      sub = Interpreter.new(@font, @builder, @subfont, @hinted, @hint_scale)
      sub.run(entry[0], entry[1], true, x0, y0)
      # The component's glyphpath is shared through @builder; the accent
      # keeps its translation, the base starts at the origin (0, 0).
      @cur_x = 0_i64
      @cur_y = 0_i64
    end
  end
end

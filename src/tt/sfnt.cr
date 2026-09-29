# SFNT (TrueType) table parser for the self-contained hinting pipeline
# (B2).  Mirrors what FreeType's sfnt/truetype drivers extract for glyph
# loading and bytecode interpretation:
#
#   - table directory, `head' (upem, indexToLocFormat), `maxp' (glyph count
#     + interpreter maxima), `hhea'/`hmtx', `vhea'/`vmtx', `OS/2' (typo
#     metrics for the vertical phantom emulation of TT_Get_VMetrics),
#     `loca'/`glyf' (simple + composite glyph decoding), `cvt ', `fpgm',
#     `prep', `cmap' (formats 4/12, FT's default-charmap selection) and
#     `kern' (legacy format 0) for codepoint lookup and kerning.
#
# Only what the pipeline needs is parsed; variations (fvar/gvar), embedded
# bitmaps and hdmx are intentionally out of scope.

module TT
  # Composite glyph flags (ttgload.c).
  ARGS_ARE_WORDS          = 0x0001_u16
  ARGS_ARE_XY_VALUES      = 0x0002_u16
  ROUND_XY_TO_GRID        = 0x0004_u16
  WE_HAVE_A_SCALE         = 0x0008_u16
  MORE_COMPONENTS         = 0x0020_u16
  WE_HAVE_AN_XY_SCALE     = 0x0040_u16
  WE_HAVE_A_2X2           = 0x0080_u16
  WE_HAVE_INSTR           = 0x0100_u16
  USE_MY_METRICS          = 0x0200_u16
  OVERLAP_COMPOUND        = 0x0400_u16
  SCALED_COMPONENT_OFFSET = 0x0800_u16

  # Simple glyph flag bits (ttgload.c).
  ON_CURVE_POINT = 0x01_u8
  X_SHORT_VECTOR = 0x02_u8
  Y_SHORT_VECTOR = 0x04_u8
  REPEAT_FLAG    = 0x08_u8
  X_POSITIVE     = 0x10_u8 # X_SAME when not X_SHORT_VECTOR
  SAME_X         = 0x10_u8
  Y_POSITIVE     = 0x20_u8
  SAME_Y         = 0x20_u8

  # 2.14 -> 16.16 matrix of a composite component (FT reads the shorts and
  # multiplies by 4).
  struct Matrix
    getter xx : Int64
    getter xy : Int64
    getter yx : Int64
    getter yy : Int64

    def initialize(@xx : Int64, @xy : Int64, @yx : Int64, @yy : Int64)
    end

    def self.identity : Matrix
      new(1_i64 << 16, 0, 0, 1_i64 << 16)
    end
  end

  struct Component
    getter flags : UInt16
    getter index : Int32
    getter arg1 : Int32 # font units (XY) or base point number
    getter arg2 : Int32
    getter transform : Matrix

    def initialize(@flags, @index, @arg1, @arg2, @transform)
    end
  end

  struct SimpleGlyph
    getter x_min : Int32
    getter y_min : Int32
    getter x_max : Int32
    getter y_max : Int32
    getter contour_ends : Array(Int32) # inclusive point index per contour
    getter tags : Array(UInt8)         # masked to FT_CURVE_TAG_ON
    getter xs : Array(Int64)           # font units
    getter ys : Array(Int64)
    getter instructions : Bytes

    def initialize(@x_min, @y_min, @x_max, @y_max,
                   @contour_ends, @tags, @xs, @ys, @instructions)
    end

    def n_points : Int32
      @xs.size
    end
  end

  struct CompositeGlyph
    getter x_min : Int32
    getter y_min : Int32
    getter x_max : Int32
    getter y_max : Int32
    getter components : Array(Component)
    getter instructions : Bytes

    def initialize(@x_min, @y_min, @x_max, @y_max,
                   @components, @instructions)
    end
  end

  class ParseError < Exception
  end

  # `cmap' format 4 (16-bit segmented mapping), decoded once. The lookup
  # keeps the raw subtable because idRangeOffset addressing is positional
  # (byte offset relative to the idRangeOffset[i] slot itself).
  struct Cmap4
    getter seg_ends : Array(UInt16)
    getter seg_starts : Array(UInt16)
    getter seg_deltas : Array(Int16)
    getter seg_range_offs : Array(UInt16)
    getter range_offs_base : Int32 # byte offset of idRangeOffset[] in `sub'
    getter sub : Bytes

    def initialize(@seg_ends, @seg_starts, @seg_deltas, @seg_range_offs,
                   @range_offs_base, @sub)
    end

    def lookup(cp : Int32) : Int32
      return 0 if cp > 0xFFFF || cp < 0
      # Binary search the segment with end >= cp (tt_cmap4_char_index).
      lo = 0
      hi = @seg_ends.size
      while lo < hi
        mid = (lo + hi) // 2
        if @seg_ends[mid] < cp
          lo = mid + 1
        else
          hi = mid
        end
      end
      return 0 if lo >= @seg_ends.size
      return 0 if cp < @seg_starts[lo]
      ro = @seg_range_offs[lo]
      if ro == 0
        return ((cp + @seg_deltas[lo].to_i32) & 0xFFFF).to_i32
      end
      addr = @range_offs_base + 2*lo + ro.to_i32 + 2*(cp - @seg_starts[lo].to_i32)
      return 0 if addr < 0 || addr + 2 > @sub.size
      g = (@sub[addr].to_u16 << 8) | @sub[addr + 1]
      return 0 if g == 0
      ((g + @seg_deltas[lo].to_i32) & 0xFFFF).to_i32
    end
  end

  # `cmap' format 12 (32-bit segmented coverage), decoded once.
  struct Cmap12
    getter group_starts : Array(Int64)
    getter group_ends : Array(Int64)
    getter group_gids : Array(Int64)

    def initialize(@group_starts, @group_ends, @group_gids)
    end

    def lookup(cp : Int32) : Int32
      lo = 0
      hi = @group_starts.size
      while lo < hi
        mid = (lo + hi) // 2
        if @group_ends[mid] < cp
          lo = mid + 1
        else
          hi = mid
        end
      end
      return 0 if lo >= @group_starts.size
      return 0 if cp < @group_starts[lo]
      (@group_gids[lo] + (cp - @group_starts[lo])).to_i32
    end
  end

  # One `kern' format 0 subtable (legacy version-0 layout, horizontal
  # coverage only — everything else FT skips, so do we).
  struct Kern0
    getter pairs : Array({Int32, Int32, Int32}) # {left, right, value FUnits}
    getter sorted : Bool

    def initialize(@pairs, @sorted)
    end

    def lookup(left : Int32, right : Int32) : Int32
      key = {left, right}
      if @sorted
        lo = 0
        hi = @pairs.size
        while lo < hi
          mid = (lo + hi) // 2
          l, r, v = @pairs[mid]
          cmp = l != left ? (l <=> left) : (r <=> right)
          if cmp < 0
            lo = mid + 1
          elsif cmp > 0
            hi = mid
          else
            return v
          end
        end
      else
        @pairs.each do |l, r, v|
          return v if l == left && r == right
        end
      end
      0
    end
  end

  class Font
    getter num_glyphs : Int32
    getter upem : Int32
    getter index_to_loc_format : Int32 # 0 = short, 1 = long
    getter num_h_metrics : Int32
    getter num_v_metrics : Int32
    getter vertical_info : Bool
    getter os2_version : UInt16 # 0xFFFF when there is no OS/2 table
    getter typo_ascender : Int32
    getter typo_descender : Int32
    getter os2_fs_selection : UInt16 = 0_u16 # USE_TYPO_METRICS = bit 7 (0x80)
    getter us_win_ascent : Int32 = 0
    getter us_win_descent : Int32 = 0
    getter hhea_ascender : Int32
    getter hhea_descender : Int32
    getter max_points : Int32
    getter max_contours : Int32
    getter max_twilight : Int32
    getter max_storage : Int32
    getter max_functions : Int32
    getter max_instruction_defs : Int32
    getter max_stack : Int32
    getter cvt : Array(Int32) # raw font units
    getter fpgm : Bytes
    getter prep : Bytes
    getter ascender : Int32 = 0   # FT_Face->ascender (see the selection below)
    getter descender : Int32 = 0 # FT_Face->descender, negative

    @data : Bytes
    @glyf : Bytes = Bytes.new(0)
    @loca : Bytes = Bytes.new(0)
    @hmtx : Bytes = Bytes.new(0)
    @vmtx : Bytes = Bytes.new(0)
    @cmap4 : Cmap4?
    @cmap12 : Cmap12?
    @kern_tables : Array(Kern0) = [] of Kern0

    def initialize(@data : Bytes)
      d = @data
      raise ParseError.new("not an SFNT font (too small)") if d.size < 12

      num_tables = u16(d, 4)
      tables = Hash(String, Tuple(Int32, Int32)).new
      i = 0
      while i < num_tables
        off = 12 + 16*i
        raise ParseError.new("table directory out of bounds") if off + 16 > d.size
        tag = String.new(d[off, 4])
        tables[tag] = {i32(d, off + 8), i32(d, off + 12)} # offset, length
        i += 1
      end

      head = table(tables, "head")
      check_len(head, 54, "head")
      upem = u16(d, head[0] + 18)
      raise ParseError.new("invalid unitsPerEm") if upem == 0
      @upem = upem.to_i32
      @index_to_loc_format = i16(d, head[0] + 50).to_i32

      maxp = table(tables, "maxp")
      check_len(maxp, 6, "maxp")
      @num_glyphs = u16(d, maxp[0] + 4).to_i32
      if maxp[1] >= 32 && u32(d, maxp[0]) == 0x0001_0000
        @max_points = u16(d, maxp[0] + 6).to_i32
        @max_contours = u16(d, maxp[0] + 8).to_i32
        @max_twilight = u16(d, maxp[0] + 16).to_i32
        @max_storage = u16(d, maxp[0] + 18).to_i32
        @max_functions = u16(d, maxp[0] + 20).to_i32
        @max_instruction_defs = u16(d, maxp[0] + 22).to_i32
        @max_stack = u16(d, maxp[0] + 24).to_i32
      else
        # version 0.5 (CFF-flavoured) or truncated: interpreter maxima = 0
        @max_points = @max_contours = @max_twilight = 0
        @max_storage = @max_functions = @max_instruction_defs = @max_stack = 0
      end

      hhea = table(tables, "hhea")
      check_len(hhea, 36, "hhea")
      @num_h_metrics = u16(d, hhea[0] + 34).to_i32
      @hhea_ascender = i16(d, hhea[0] + 4).to_i32
      @hhea_descender = i16(d, hhea[0] + 6).to_i32
      @hmtx = slice(tables, "hmtx")

      if tables.has_key?("vhea") && tables.has_key?("vmtx")
        vhea = table(tables, "vhea")
        check_len(vhea, 36, "vhea")
        @num_v_metrics = u16(d, vhea[0] + 34).to_i32
        @vmtx = slice(tables, "vmtx")
        @vertical_info = @num_v_metrics > 0 && @vmtx.size > 0
      else
        @num_v_metrics = 0
        @vertical_info = false
      end

      if os2 = tables["OS/2"]?
        if os2[1] >= 72 && os2[0] + 72 <= d.size
          @os2_version = u16(d, os2[0])
          @typo_ascender = i16(d, os2[0] + 68).to_i32
          @typo_descender = i16(d, os2[0] + 70).to_i32
          if os2[1] >= 78 && os2[0] + 78 <= d.size
            @os2_fs_selection = u16(d, os2[0] + 62)
            @us_win_ascent = u16(d, os2[0] + 74).to_i32
            @us_win_descent = u16(d, os2[0] + 76).to_i32
          end
        else
          @os2_version = 0xFFFF_u16
          @typo_ascender = @typo_descender = 0
        end
      else
        @os2_version = 0xFFFF_u16
        @typo_ascender = @typo_descender = 0
      end

      @loca = slice(tables, "loca")
      @glyf = slice(tables, "glyf")

      cvt_slice = slice(tables, "cvt ")
      @cvt = Array(Int32).new(cvt_slice.size // 2) { |k| i16(cvt_slice, 2*k).to_i32 }

      @fpgm = slice(tables, "fpgm")
      @prep = slice(tables, "prep")

      parse_cmap(tables)
      parse_kern(tables)
      compute_vertical_face_metrics
    end

    # Codepoint -> glyph index through the selected Unicode submap.
    # Returns 0 (notdef) when the font has no usable Unicode cmap —
    # callers treat it exactly like FreeType's charmap-less faces.
    def glyph_index(codepoint : Int32) : Int32
      if c4 = @cmap4
        c4.lookup(codepoint)
      elsif c12 = @cmap12
        c12.lookup(codepoint)
      else
        0
      end
    end

    # Horizontal kerning between two glyph ids in font units
    # (tt_face_get_kerning: the sum over every format 0 subtable).
    def kerning(left_gid : Int32, right_gid : Int32) : Int32
      k = 0
      @kern_tables.each { |t| k += t.lookup(left_gid, right_gid) }
      k
    end

    # --- cmap / kern / face metrics --------------------------------------

    # Pick the subtable FreeType's find_unicode_charmap picks for a fresh
    # face: a 32-bit Unicode map ((3,10) / (0,4) / (0,6)) beats a 16-bit
    # one, and among equals the LAST one in the table wins (FT loops
    # backwards). Formats 4 and 12 are decoded; anything else keeps the
    # map empty (FT would route it through its own extra formats).
    private def parse_cmap(tables) : Nil
      entry = tables["cmap"]?
      return unless entry
      off, len = entry
      return if len < 4 || off < 0 || off + len > @data.size

      d = @data
      n = u16(d, off + 2)
      best32 = best16 = nil # {subtable offset}
      i = 0
      while i < n
        rec = off + 4 + 8*i
        break if rec + 8 > off + len
        platform = u16(d, rec)
        encoding = u16(d, rec + 2)
        sub_off = off.to_i32 + u32(d, rec + 4).to_i32
        # Unicode encodings FT recognises; (0,5) is variant selectors.
        uni = platform == 0 ? encoding != 5 : platform == 3 && {1, 10}.includes?(encoding)
        if uni && sub_off + 2 <= off + len
          uni32 = platform == 0 ? {4, 6}.includes?(encoding) : encoding == 10
          best16 = sub_off # forward scan with last-wins == FT's reverse scan
          best32 = sub_off if uni32
        end
        i += 1
      end

      sub_off = best32 || best16
      return unless sub_off
      return if sub_off < 0 || sub_off + 2 > d.size

      sub_end = {off + len, d.size}.min
      return if sub_off >= sub_end
      sub = d[sub_off, sub_end - sub_off]

      case u16(sub, 0)
      when 4
        return if sub.size < 14
        seg_count = (u16(sub, 6) // 2).to_i32
        return if seg_count == 0 || 14 + 6*seg_count + 2 > sub.size
        ends = Array(UInt16).new(seg_count) { |k| u16(sub, 14 + 2*k) }
        starts = Array(UInt16).new(seg_count) { |k| u16(sub, 14 + 2*seg_count + 2 + 2*k) }
        deltas = Array(Int16).new(seg_count) { |k| i16(sub, 14 + 4*seg_count + 2 + 2*k) }
        base = 14 + 6*seg_count + 2
        ros = Array(UInt16).new(seg_count) { |k| u16(sub, base + 2*k) }
        @cmap4 = Cmap4.new(ends, starts, deltas, ros, base, sub)
      when 12
        return if sub.size < 16
        n_groups = u32(sub, 12).to_i32
        return if 16 + 12*n_groups > sub.size
        starts = Array(Int64).new(n_groups) { |k| u32(sub, 16 + 12*k).to_i64 }
        ends = Array(Int64).new(n_groups) { |k| u32(sub, 16 + 12*k + 4).to_i64 }
        gids = Array(Int64).new(n_groups) { |k| u32(sub, 16 + 12*k + 8).to_i64 }
        @cmap12 = Cmap12.new(starts, ends, gids)
      end
    end

    # Legacy `kern' table (ttkern.c): version-0 layout, up to 32 subtables,
    # only horizontal format 0 subtables kept; broken lengths clamped the
    # same way FT clamps them.
    private def parse_kern(tables) : Nil
      entry = tables["kern"]?
      return unless entry
      off, len = entry
      return if len < 4 || off < 0 || off + len > @data.size

      d = @data
      limit = off + len
      p = off + 4 # skip the table version
      num_tables = u16(d, off + 2)
      num_tables = 32 if num_tables > 32

      num_tables.times do
        break if p + 6 > limit
        length = u16(d, p + 2).to_i32
        coverage = u16(d, p + 4)
        break if length <= 6 + 8
        p_next = {p + length, limit}.min

        format = coverage >> 8
        if format == 0 && (coverage & 3) == 1 && p + 8 <= p_next
          num_pairs = u16(d, p + 6).to_i32
          pairs_off = p + 14
          if p_next - pairs_off < 6*num_pairs
            num_pairs = (p_next - pairs_off) // 6
          end
          pairs = Array({Int32, Int32, Int32}).new(num_pairs) do |k|
            q = pairs_off + 6*k
            {u16(d, q).to_i32, u16(d, q + 2).to_i32, i16(d, q + 4).to_i32}
          end
          sorted = true
          (1...num_pairs).each do |k|
            if pairs[k][0] < pairs[k - 1][0] ||
               (pairs[k][0] == pairs[k - 1][0] && pairs[k][1] <= pairs[k - 1][1])
              sorted = false
              break
            end
          end
          @kern_tables << Kern0.new(pairs, sorted)
        end
        p = p_next
      end
    end

    # FT_Face->ascender/descender selection (sfnt_load_face, sfobjs.c):
    # OS/2 USE_TYPO_METRICS wins, then `hhea', with typo and usWin*
    # fallbacks when hhea carries zeroes.
    private def compute_vertical_face_metrics : Nil
      if @os2_version != 0xFFFF_u16 && (@os2_fs_selection & 0x80_u16) != 0
        @ascender = @typo_ascender
        @descender = @typo_descender
        return
      end
      @ascender = @hhea_ascender
      @descender = @hhea_descender
      return unless @ascender == 0 && @descender == 0
      return if @os2_version == 0xFFFF_u16
      if @typo_ascender != 0 || @typo_descender != 0
        @ascender = @typo_ascender
        @descender = @typo_descender
      else
        @ascender = @us_win_ascent
        @descender = -@us_win_descent
      end
    end

    # Glyph data range within `glyf' (loca[gid] .. loca[gid+1]); an empty
    # range is the empty glyph.
    def glyph_range(gid : Int32) : {Int32, Int32}
      raise ParseError.new("glyph index out of range") if gid < 0 || gid >= @num_glyphs
      if @index_to_loc_format == 0
        o0 = u16(@loca, 2*gid) * 2
        o1 = u16(@loca, 2*(gid + 1)) * 2
      else
        o0 = u32(@loca, 4*gid)
        o1 = u32(@loca, 4*(gid + 1))
      end
      raise ParseError.new("loca out of bounds") if o0 > o1 || o1 > @glyf.size
      {o0.to_i32, o1.to_i32}
    end

    def glyph_bytes(gid : Int32) : Bytes
      o0, o1 = glyph_range(gid)
      @glyf[o0, o1 - o0]
    end

    # Horizontal metrics in font units (tt_face_get_metrics).
    def h_metrics(gid : Int32) : {Int32, Int32}
      k = @num_h_metrics
      return {0, 0} if k == 0
      t = @hmtx
      if gid < k
        return {0, 0} if 4*gid + 4 > t.size
        {u16(t, 4*gid).to_i32, i16(t, 4*gid + 2).to_i32}
      else
        return {0, 0} if 4*(k - 1) + 2 > t.size
        aw = u16(t, 4*(k - 1)).to_i32
        pos = 4*k + 2*(gid - k)
        lsb = pos + 2 <= t.size ? i16(t, pos).to_i32 : 0
        {aw, lsb}
      end
    end

    def advance_width(gid : Int32) : Int32
      h_metrics(gid)[0]
    end

    def left_side_bearing(gid : Int32) : Int32
      h_metrics(gid)[1]
    end

    # Vertical metrics in font units for the phantom points
    # (TT_Get_VMetrics, ttgload.c): uses `vmtx' when present, otherwise the
    # OS/2 (or hhea) typographic emulation.
    def v_metrics(gid : Int32, y_max : Int32) : {Int32, Int32}
      if @vertical_info
        k = @num_v_metrics
        t = @vmtx
        if k > 0 && gid < k
          return {0, 0} if 4*gid + 4 > t.size
          return {i16(t, 4*gid + 2).to_i32, u16(t, 4*gid).to_i32}
        elsif k > 0
          return {0, 0} if 4*(k - 1) + 2 > t.size
          ah = u16(t, 4*(k - 1)).to_i32
          pos = 4*k + 2*(gid - k)
          tsb = pos + 2 <= t.size ? i16(t, pos).to_i32 : 0
          return {tsb, ah}
        end
        {0, 0}
      elsif @os2_version != 0xFFFF_u16
        tsb = (@typo_ascender - y_max).to_i16!.to_i32
        ah = (@typo_ascender - @typo_descender).abs.to_u16!.to_i32
        {tsb, ah}
      else
        tsb = (@hhea_ascender - y_max).to_i16!.to_i32
        ah = (@hhea_ascender - @hhea_descender).abs.to_u16!.to_i32
        {tsb, ah}
      end
    end

    # Decoded simple glyph, or nil when the glyph is composite/empty.
    def simple_glyph(gid : Int32) : SimpleGlyph?
      d = glyph_bytes(gid)
      return nil if d.size < 10
      n_contours = i16(d, 0).to_i32
      return nil unless n_contours > 0

      x_min = i16(d, 2).to_i32
      y_min = i16(d, 4).to_i32
      x_max = i16(d, 6).to_i32
      y_max = i16(d, 8).to_i32

      p = 10
      limit = d.size
      raise ParseError.new("bad contours array") if p + 2*n_contours + 2 > limit

      n_points = 0
      contour_ends = Array(Int32).new(n_contours) do |i|
        e = u16(d, p + 2*i).to_i32
        raise ParseError.new("non-monotonic contour ends") if e < n_points
        n_points = e + 1
        e
      end
      p += 2*n_contours

      n_ins = u16(d, p).to_i32
      p += 2
      raise ParseError.new("too many instructions") if p + n_ins > limit
      instructions = d[p, n_ins]
      p += n_ins

      # point flags (with repeats)
      tags = Array(UInt8).new(n_points, 0_u8)
      i = 0
      while i < n_points
        raise ParseError.new("flags overrun") if p >= limit
        c = d[p]
        p += 1
        tags[i] = c
        i += 1
        if c & REPEAT_FLAG != 0
          raise ParseError.new("repeat count overrun") if p >= limit
          count = d[p]
          p += 1
          raise ParseError.new("repeat overrun") if i + count > n_points
          count.times do
            tags[i] = c
            i += 1
          end
        end
      end

      xs = Array(Int64).new(n_points, 0_i64)
      ys = Array(Int64).new(n_points, 0_i64)
      x = 0_i64
      i.times do |k|
        f = tags[k]
        if f & X_SHORT_VECTOR != 0
          raise ParseError.new("x coords overrun") if p >= limit
          delta = d[p].to_i64
          p += 1
          delta = -delta if f & X_POSITIVE == 0
        elsif f & SAME_X == 0
          raise ParseError.new("x coords overrun") if p + 2 > limit
          delta = i16(d, p).to_i64
          p += 2
        else
          delta = 0_i64
        end
        x &+= delta
        xs[k] = x
      end
      y = 0_i64
      i.times do |k|
        f = tags[k]
        if f & Y_SHORT_VECTOR != 0
          raise ParseError.new("y coords overrun") if p >= limit
          delta = d[p].to_i64
          p += 1
          delta = -delta if f & Y_POSITIVE == 0
        elsif f & SAME_Y == 0
          raise ParseError.new("y coords overrun") if p + 2 > limit
          delta = i16(d, p).to_i64
          p += 2
        else
          delta = 0_i64
        end
        y &+= delta
        ys[k] = y
        # TT_Load_Simple_Glyph masks tags to the on-curve bit while
        # reading the y coordinates.
        tags[k] = f & ON_CURVE_POINT
      end

      SimpleGlyph.new(x_min, y_min, x_max, y_max, contour_ends, tags, xs, ys, instructions)
    end

    # Decoded composite glyph, or nil when the glyph is simple/empty.
    def composite_glyph(gid : Int32) : CompositeGlyph?
      d = glyph_bytes(gid)
      return nil if d.size < 10
      n_contours = i16(d, 0).to_i32
      return nil unless n_contours < 0

      x_min = i16(d, 2).to_i32
      y_min = i16(d, 4).to_i32
      x_max = i16(d, 6).to_i32
      y_max = i16(d, 8).to_i32

      p = 10
      limit = d.size
      components = [] of Component

      loop do
        raise ParseError.new("component header overrun") if p + 4 > limit
        flags = u16(d, p)
        index = u16(d, p + 2).to_i32
        p += 4
        raise ParseError.new("component index out of range") if index >= @num_glyphs

        count = 2
        count += 2 if flags & ARGS_ARE_WORDS != 0
        if flags & WE_HAVE_A_SCALE != 0
          count += 2
        elsif flags & WE_HAVE_AN_XY_SCALE != 0
          count += 4
        elsif flags & WE_HAVE_A_2X2 != 0
          count += 8
        end
        raise ParseError.new("component data overrun") if p + count > limit

        if flags & ARGS_ARE_XY_VALUES != 0
          if flags & ARGS_ARE_WORDS != 0
            arg1 = i16(d, p).to_i32
            arg2 = i16(d, p + 2).to_i32
          else
            arg1 = d[p].to_i8!.to_i32
            arg2 = d[p + 1].to_i8!.to_i32
          end
        else
          if flags & ARGS_ARE_WORDS != 0
            arg1 = u16(d, p).to_i32
            arg2 = u16(d, p + 2).to_i32
          else
            arg1 = d[p].to_i32
            arg2 = d[p + 1].to_i32
          end
        end
        p += 2
        p += 2 if flags & ARGS_ARE_WORDS != 0

        xx = yy = 1_i64 << 16
        xy = yx = 0_i64
        if flags & WE_HAVE_A_SCALE != 0
          xx = i16(d, p).to_i64 * 4
          p += 2
          yy = xx
        elsif flags & WE_HAVE_AN_XY_SCALE != 0
          xx = i16(d, p).to_i64 * 4
          yy = i16(d, p + 2).to_i64 * 4
          p += 4
        elsif flags & WE_HAVE_A_2X2 != 0
          xx = i16(d, p).to_i64 * 4
          yx = i16(d, p + 2).to_i64 * 4
          xy = i16(d, p + 4).to_i64 * 4
          yy = i16(d, p + 6).to_i64 * 4
          p += 8
        end

        components << Component.new(flags, index, arg1, arg2, Matrix.new(xx, xy, yx, yy))

        break if flags & MORE_COMPONENTS == 0
      end

      # Composite instructions directly follow the components
      # (ins_pos in TT_Load_Composite_Glyph); only present when the last
      # component sets WE_HAVE_INSTR.
      instructions = Bytes.new(0)
      if !components.empty? && (components.last.flags & WE_HAVE_INSTR) != 0
        raise ParseError.new("missing composite instruction count") if p + 2 > limit
        n_ins = u16(d, p).to_i32
        raise ParseError.new("too many composite instructions") if 2 + n_ins > limit - p
        instructions = d[p + 2, n_ins]
      end

      CompositeGlyph.new(x_min, y_min, x_max, y_max, components, instructions)
    end

    # Glyph bbox straight from the glyf header (needed for phantom points
    # before knowing whether the glyph is simple or composite).
    def glyph_bbox(gid : Int32) : {Int32, Int32, Int32, Int32}
      d = glyph_bytes(gid)
      return {0, 0, 0, 0} if d.size < 10
      {i16(d, 2).to_i32, i16(d, 4).to_i32, i16(d, 6).to_i32, i16(d, 8).to_i32}
    end

    # --- raw big-endian readers ------------------------------------------

    private def table(tables, tag) : {Int32, Int32}
      entry = tables[tag]? || raise ParseError.new("missing '#{tag}' table")
      off, len = entry
      raise ParseError.new("'#{tag}' out of bounds") if off < 0 || len < 0 || off + len > @data.size
      {off, len}
    end

    private def slice(tables, tag) : Bytes
      return Bytes.new(0) unless entry = tables[tag]?
      off, len = entry
      return Bytes.new(0) if off < 0 || len < 0 || off + len > @data.size
      @data[off, len]
    end

    private def check_len(entry, min, tag)
      raise ParseError.new("'#{tag}' too small") if entry[1] < min
    end

    private def u8(d : Bytes, off : Int32) : UInt8
      d[off]
    end

    private def u16(d : Bytes, off : Int32) : UInt16
      (d[off].to_u16 << 8) | d[off + 1]
    end

    private def i16(d : Bytes, off : Int32) : Int16
      u16(d, off).to_i16!
    end

    private def u32(d : Bytes, off : Int32) : UInt32
      (d[off].to_u32 << 24) | (d[off + 1].to_u32 << 16) |
        (d[off + 2].to_u32 << 8) | d[off + 3]
    end

    private def i32(d : Bytes, off : Int32) : Int32
      u32(d, off).to_i32!
    end
  end
end

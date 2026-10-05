# SFNT (TrueType) table parser for the self-contained hinting pipeline.
# Mirrors what FreeType's sfnt/truetype drivers extract for glyph
# loading and bytecode interpretation:
#
#   - table directory, `head' (upem, indexToLocFormat), `maxp' (glyph count
#     + interpreter maxima), `hhea'/`hmtx', `vhea'/`vmtx', `OS/2' (typo
#     metrics for the vertical phantom emulation of TT_Get_VMetrics),
#     `loca'/`glyf' (simple + composite glyph decoding), `cvt ', `fpgm',
#     `prep', `cmap' (formats 4/12, FT's default-charmap selection) and
#     `kern' (legacy format 0) for codepoint lookup and kerning.
#
# Only what the pipeline needs is parsed; embedded bitmaps and hdmx are
# intentionally out of scope, and the variation tables (fvar/avar/gvar…)
# live in tt/ttgxvar.cr (reached through `Font#raw_table'). WOFF1 wrappers are
# unwrapped into a plain SFNT before parsing (see `TT.unwrap_woff');
# WOFF2 too when built with -Dwith_woff2 (see tt/woff2.cr).

require "compress/zlib"
require "io/memory"

# WOFF2 support is opt-in and only compiled when the `with_woff2' flag is
# given; the brotli backend is then chosen at compile time — the
# pure-Crystal decoder shard by default, libbrotlidec through FFI with
# the additional -Dnative_brotli flag (see tt/woff2.cr).
{% if flag?(:with_woff2) %}
require "./woff2"
{% end %}

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

  # Unwrap a WOFF1 wrapper into a plain SFNT buffer (the port of
  # FreeType's `woff_open_font', sfnt/wofffnt.c): each table is either
  # stored raw (compLength == origLength) or zlib-compressed; the
  # result is a reconstructed SFNT with the original flavor, a fresh
  # table directory and the tables re-padded to 4-byte alignment.
  # WOFF2 ('wOF2' magic) is unwrapped through the pure-Crystal brotli
  # decoder when built with -Dwith_woff2 (see tt/woff2.cr); without the
  # flag it is an error.
  # Bare collections ('ttcf') are returned as-is — they are handled
  # through `ttcf_face_offset'/`Font#@base' instead (slicing would
  # corrupt their file-relative table offsets). Any other input is
  # returned as-is.
  def self.unwrap_woff(data : Bytes, face_index : Int32 = 0) : Bytes
    if data.size >= 4 &&
       data[0] == 0x77 && data[1] == 0x4F &&
       data[2] == 0x46 && data[3] == 0x32 # 'wOF2'
      {% if flag?(:with_woff2) %}
        return TT.unwrap_woff2(data, face_index)
      {% else %}
        raise ParseError.new("WOFF2 fonts require a build with " \
                             "-Dwith_woff2 (brotli)")
      {% end %}
    end

    if data.size >= 44 &&
       data[0] == 0x77 && data[1] == 0x4F &&
       data[2] == 0x46 && data[3] == 0x46 # 'wOFF'
      length = ru32(data, 8)
      raise ParseError.new("WOFF length field out of bounds") if length != data.size
      num_tables = ru16(data, 12)
      raise ParseError.new("WOFF reserved field must be 0") unless ru16(data, 14) == 0
      raise ParseError.new("WOFF table directory out of bounds") if 44 + 20*num_tables > data.size

      entries = Array({Bytes, Int32, Int32, Int32, UInt32}).new(num_tables)
      sfnt_size = 12 + 16*num_tables
      num_tables.times do |i|
        off = 44 + 20*i
        tag = data[off, 4]
        table_off = ru32(data, off + 4)
        comp_len = ru32(data, off + 8)
        orig_len = ru32(data, off + 12)
        checksum = ru32(data, off + 16)
        raise ParseError.new("WOFF table out of bounds") if comp_len > orig_len ||
          table_off + comp_len > data.size
        entries << {tag, table_off.to_i32, comp_len.to_i32, orig_len.to_i32, checksum}
        sfnt_size += (orig_len + 3) &~ 3
      end

      sfnt = Bytes.new(sfnt_size, 0)
      flavor = ru32(data, 4)
      w32(sfnt, 0, flavor)
      w16(sfnt, 4, num_tables)
      entry_selector = num_tables.bit_length - 1 # floor(log2)
      search_range = 16 << entry_selector
      w16(sfnt, 6, search_range)
      w16(sfnt, 8, entry_selector)
      w16(sfnt, 10, 16*num_tables - search_range)

      dir_off = 12
      data_off = 12 + 16*num_tables
      entries.each do |tag, table_off, comp_len, orig_len, checksum|
        tag.copy_to(sfnt[dir_off, 4])
        w32(sfnt, dir_off + 4, checksum)
        w32(sfnt, dir_off + 8, data_off)
        w32(sfnt, dir_off + 12, orig_len)

        src = data[table_off, comp_len]
        if comp_len == orig_len
          src.copy_to(sfnt[data_off, orig_len])
        else
          io = IO::Memory.new(src)
          reader = Compress::Zlib::Reader.new(io)
          reader.read_fully(sfnt[data_off, orig_len])
        end
        data_off += (orig_len + 3) &~ 3
        dir_off += 16
      end
      return sfnt
    end

    # TrueType/OpenType collections are NOT handled here: their table
    # offsets are file-relative, so the face cannot be sliced out —
    # see `ttcf_face_offset' and the @base handling in `Font'.
    data
  end

  # A bare TrueType/OpenType collection ('ttcf' magic): return the
  # byte offset of face `face_index''s SFNT inside the buffer, or nil
  # for anything that is not a collection. Table offsets inside a
  # member face are relative to the START OF THE FILE (shared table
  # data), so callers must keep the whole buffer and add this base —
  # slicing would corrupt every table offset.
  def self.ttcf_face_offset(data : Bytes, face_index : Int32 = 0) : Int32?
    return nil unless data.size >= 12 &&
                      data[0] == 0x74 && data[1] == 0x74 &&
                      data[2] == 0x63 && data[3] == 0x66 # 'ttcf'
    num_fonts = ru32(data, 8).to_i32
    raise ParseError.new("invalid TTC header") if num_fonts <= 0 ||
      12 + 4*num_fonts > data.size
    raise ParseError.new("TTC face index out of range") if
      face_index < 0 || face_index >= num_fonts
    offset = ru32(data, 12 + 4*face_index).to_i32
    raise ParseError.new("invalid TTC face offset") if
      offset == 0 || offset < 0 || offset + 12 > data.size
    offset
  end

  private def self.ru16(d : Bytes, off : Int32) : UInt16
    (d[off].to_u16 << 8) | d[off + 1]
  end

  private def self.ru32(d : Bytes, off : Int32) : UInt32
    (d[off].to_u32 << 24) | (d[off + 1].to_u32 << 16) |
      (d[off + 2].to_u32 << 8) | d[off + 3]
  end

  private def self.w16(d : Bytes, off : Int32, v : Int32) : Nil
    d[off] = (v >> 8).to_u8!
    d[off + 1] = v.to_u8!
  end

  private def self.w32(d : Bytes, off : Int32, v : UInt32 | Int32) : Nil
    d[off] = (v >> 24).to_u8!
    d[off + 1] = (v >> 16).to_u8!
    d[off + 2] = (v >> 8).to_u8!
    d[off + 3] = v.to_u8!
  end

  class Font
    getter num_glyphs : Int32
    getter upem : Int32
    getter index_to_loc_format : Int32 # 0 = short, 1 = long
    getter num_h_metrics : Int32
    getter num_v_metrics : Int32
    getter vertical_info : Bool
    getter os2_version : UInt16 # 0xFFFF when there is no OS/2 table
    property typo_ascender : Int32
    property typo_descender : Int32
    property typo_line_gap : Int32 = 0
    getter os2_fs_selection : UInt16 = 0_u16 # USE_TYPO_METRICS = bit 7 (0x80)
    property us_win_ascent : Int32 = 0
    property us_win_descent : Int32 = 0
    # os2.yStrikeoutSize/yStrikeoutPosition (targets of the MVAR `strs'/
    # `stro' tags) and os2.sxHeight (`xhgt', version 2+).
    property y_strikeout_size : Int32 = 0
    property y_strikeout_position : Int32 = 0
    property sx_height : Int32 = 0
    getter mac_style : UInt16 = 0_u16 # head.macStyle: bit 1 = italic
    getter is_fixed_pitch : Bool = false # post.isFixedPitch
    # post.underlinePosition/underlineThickness (targets of the MVAR
    # `undo'/`unds' tags).
    property post_underline_position : Int32 = 0
    property post_underline_thickness : Int32 = 0
    getter hhea_ascender : Int32
    getter hhea_descender : Int32
    getter hhea_line_gap : Int32 = 0
    getter max_points : Int32
    getter max_contours : Int32
    getter max_twilight : Int32
    getter max_storage : Int32
    getter max_functions : Int32
    getter max_instruction_defs : Int32
    getter max_stack : Int32
    getter max_size_of_instructions : Int32
    getter cvt : Array(Int32) # raw font units
    getter fpgm : Bytes
    getter prep : Bytes
    property ascender : Int32 = 0   # FT_Face->ascender (see the selection below)
    property descender : Int32 = 0 # FT_Face->descender, negative
    property height : Int32 = 0    # FT_Face->height
    # FT_Face->underline_*: derived from the `post' values, recomputed by
    # tt_apply_mvar when UNDO/UNDS deltas patch them.
    property underline_position : Int32 = 0
    property underline_thickness : Int32 = 0
    # Raw 'CFF ' table for CFF-flavoured OTF (empty for TrueType outlines).
    getter cff_table : Bytes = Bytes.new(0)

    @data : Bytes
    @tables : Hash(String, Tuple(Int32, Int32))
    @glyf : Bytes = Bytes.new(0)
    @loca : Bytes = Bytes.new(0)
    @hmtx : Bytes = Bytes.new(0)
    @vmtx : Bytes = Bytes.new(0)
    @cmap4 : Cmap4?
    @cmap12 : Cmap12?
    @kern_tables : Array(Kern0) = [] of Kern0

    # Byte offset of this face's SFNT inside `@data' — non-zero for a
    # member of a TTC/OTC collection (its table offsets are
    # file-relative; see `TT.ttcf_face_offset').
    @base : Int32 = 0

    def initialize(data : Bytes, face_index : Int32 = 0)
      @base = (TT.ttcf_face_offset(data, face_index) || 0)
      data = TT.unwrap_woff(data, face_index)
      @data = data
      d = @data
      raise ParseError.new("not an SFNT font (too small)") if d.size < @base + 12

      num_tables = u16(d, @base + 4)
      @tables = Hash(String, Tuple(Int32, Int32)).new
      tables = @tables
      i = 0
      while i < num_tables
        off = @base + 12 + 16*i
        raise ParseError.new("table directory out of bounds") if off + 16 > d.size
        tag = String.new(d[off, 4])
        # table offsets are always file-relative (in a collection they
        # point into the shared data beyond @base) — no @base here
        tables[tag] = {i32(d, off + 8), i32(d, off + 12)} # offset, length
        i += 1
      end

      head = table(tables, "head")
      check_len(head, 54, "head")
      upem = u16(d, head[0] + 18)
      raise ParseError.new("invalid unitsPerEm") if upem == 0
      @upem = upem.to_i32
      @index_to_loc_format = i16(d, head[0] + 50).to_i32
      @mac_style = u16(d, head[0] + 44)

      # post.isFixedPitch (offset 12 in the table header); the underline
      # fields (offsets 8/10) — zero like FT's cleared struct when absent.
      if (post = tables["post"]?) && post[1] >= 16 && post[0] + 16 <= d.size
        @is_fixed_pitch = u32(d, post[0] + 12) != 0
        @post_underline_position = i16(d, post[0] + 8).to_i32
        @post_underline_thickness = i16(d, post[0] + 10).to_i32
      end

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
        @max_size_of_instructions = u16(d, maxp[0] + 26).to_i32
      else
        # version 0.5 (CFF-flavoured) or truncated: interpreter maxima = 0
        @max_points = @max_contours = @max_twilight = 0
        @max_storage = @max_functions = @max_instruction_defs = @max_stack = 0
        @max_size_of_instructions = 0
      end

      hhea = table(tables, "hhea")
      check_len(hhea, 36, "hhea")
      @num_h_metrics = u16(d, hhea[0] + 34).to_i32
      @hhea_ascender = i16(d, hhea[0] + 4).to_i32
      @hhea_descender = i16(d, hhea[0] + 6).to_i32
      @hhea_line_gap = i16(d, hhea[0] + 8).to_i32
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
          @typo_line_gap = i16(d, os2[0] + 72).to_i32
          # yStrikeoutSize/yStrikeoutPosition live well within the
          # already-checked 72 bytes (offsets 26/28).
          @y_strikeout_size = i16(d, os2[0] + 26).to_i32
          @y_strikeout_position = i16(d, os2[0] + 28).to_i32
          if os2[1] >= 78 && os2[0] + 78 <= d.size
            @os2_fs_selection = u16(d, os2[0] + 62)
            @us_win_ascent = u16(d, os2[0] + 74).to_i32
            @us_win_descent = u16(d, os2[0] + 76).to_i32
          end
          # sxHeight exists from OS/2 version 2 on (offset 86).
          if os2[1] >= 88 && os2[0] + 88 <= d.size && @os2_version >= 2
            @sx_height = i16(d, os2[0] + 86).to_i32
          end
        else
          @os2_version = 0xFFFF_u16
          @typo_ascender = @typo_descender = 0
        end
      else
        @os2_version = 0xFFFF_u16
        @typo_ascender = @typo_descender = 0
      end

      # CFF-flavoured OTF carries no glyf/loca: hand the raw 'CFF '/'CFF2'
      # table to the CFF pipeline (src/cff) and keep the SFNT side
      # (cmap/hmtx/head) working for it. Bitmap-only fonts (CBDT/sbix/CBLC)
      # stay out of scope — reject them up front as before.
      if cff_entry = tables["CFF "]? || tables["CFF2"]?
        tag = tables.has_key?("CFF ") ? "CFF " : "CFF2"
        @cff_table = slice(tables, tag)
      elsif tables.has_key?("glyf") && tables.has_key?("loca")
        @loca = slice(tables, "loca")
        @glyf = slice(tables, "glyf")
      else
        raise ParseError.new("no vector outlines " \
          "(missing 'glyf'/'loca' and 'CFF '; bitmap-only font?)")
      end

      cvt_slice = slice(tables, "cvt ")
      @cvt = Array(Int32).new(cvt_slice.size // 2) { |k| i16(cvt_slice, 2*k).to_i32 }

      @fpgm = slice(tables, "fpgm")
      @prep = slice(tables, "prep")

      parse_cmap(tables)
      parse_kern(tables)
      compute_vertical_face_metrics
    end

    # Raw table bytes by tag (nil when absent/out of bounds) — the entry
    # point for the optional variation tables (see tt/ttgxvar.cr).
    def raw_table(tag : String) : Bytes?
      entry = @tables[tag]?
      return nil unless entry
      off, len = entry
      return nil if off < 0 || len < 0 || off + len > @data.size
      @data[off, len]
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

    # FT_Face->ascender/descender/height/underline selection
    # (sfnt_load_face, sfobjs.c): OS/2 USE_TYPO_METRICS wins, then
    # `hhea', with typo and usWin* fallbacks when hhea carries zeroes.
    private def compute_vertical_face_metrics : Nil
      if @os2_version != 0xFFFF_u16 && (@os2_fs_selection & 0x80_u16) != 0
        @ascender = @typo_ascender
        @descender = @typo_descender
        @height = @ascender - @descender + @typo_line_gap
      else
        @ascender = @hhea_ascender
        @descender = @hhea_descender
        @height = @ascender - @descender + @hhea_line_gap
        unless @ascender == 0 && @descender == 0
          set_underline_metrics
          return
        end
        unless @os2_version == 0xFFFF_u16
          if @typo_ascender != 0 || @typo_descender != 0
            @ascender = @typo_ascender
            @descender = @typo_descender
            @height = @ascender - @descender + @typo_line_gap
          else
            @ascender = @us_win_ascent
            @descender = -@us_win_descent
            @height = @ascender - @descender
          end
        end
      end
      set_underline_metrics
    end

    # sfnt_load_face's post-script adjustment: FT derives the underline
    # metrics (top edge -> centre of stroke) from the `post' values;
    # tt_apply_mvar recomputes exactly this after UNDO/UNDS deltas.
    private def set_underline_metrics : Nil
      @underline_position = (@post_underline_position -
                             @post_underline_thickness.tdiv(2)).to_i16!.to_i32
      @underline_thickness = @post_underline_thickness.to_i16!.to_i32
    end

    # Glyph data range within `glyf' (loca[gid] .. loca[gid+1]); an empty
    # range is the empty glyph.
    def glyph_range(gid : Int32) : {Int32, Int32}
      raise ParseError.new("glyph index out of range") if gid < 0 || gid >= @num_glyphs
      if @index_to_loc_format == 0
        # widen before doubling: the raw offset can be up to 65535, and the
        # doubled value up to 131070 — must not wrap in UInt16
        o0 = u16(@loca, 2*gid).to_i32 * 2
        o1 = u16(@loca, 2*(gid + 1)).to_i32 * 2
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
      xs = Array(Int64).new(0, 0_i64)
      ys = Array(Int64).new(0, 0_i64)
      tags = Array(UInt8).new(0, 0_u8)
      contour_ends = Array(Int32).new(0, 0)
      n, instructions, x_min, y_min, x_max, y_max =
        simple_glyph_into(gid, xs, ys, tags, contour_ends)
      return nil if n == 0
      SimpleGlyph.new(x_min, y_min, x_max, y_max, contour_ends, tags, xs, ys, instructions)
    end

    # Fill variant for the hot path: decodes into caller-owned (reused)
    # buffers, returning the point count (0 = not a simple glyph). The
    # instructions are returned as a slice of the font data.
    def simple_glyph_into(gid : Int32, xs : Array(Int64), ys : Array(Int64),
                          tags : Array(UInt8), contour_ends : Array(Int32),
                          ) : {Int32, Bytes, Int32, Int32, Int32, Int32}
      xs.clear; ys.clear; tags.clear; contour_ends.clear
      d = glyph_bytes(gid)
      if d.size < 10
        return {0, Bytes.new(0), 0, 0, 0, 0}
      end
      n_contours = i16(d, 0).to_i32
      if n_contours <= 0
        return {0, Bytes.new(0), 0, 0, 0, 0}
      end

      x_min = i16(d, 2).to_i32
      y_min = i16(d, 4).to_i32
      x_max = i16(d, 6).to_i32
      y_max = i16(d, 8).to_i32

      p = 10
      limit = d.size
      raise ParseError.new("bad contours array") if p + 2*n_contours + 2 > limit

      n_points = 0
      n_contours.times do |i|
        e = u16(d, p + 2*i).to_i32
        raise ParseError.new("non-monotonic contour ends") if e < n_points
        n_points = e + 1
        contour_ends << e
      end
      p += 2*n_contours

      n_ins = u16(d, p).to_i32
      p += 2
      raise ParseError.new("too many instructions") if p + n_ins > limit
      instructions = d[p, n_ins]
      p += n_ins

      # point flags (with repeats)
      i = 0
      while i < n_points
        raise ParseError.new("flags overrun") if p >= limit
        c = d[p]
        p += 1
        tags << c
        i += 1
        if c & REPEAT_FLAG != 0
          raise ParseError.new("flags overrun") if p >= limit
          count = d[p]
          p += 1
          raise ParseError.new("repeat overrun") if i + count > n_points
          count.times do
            tags << c
            i += 1
          end
        end
      end

      x = 0_i64
      i.times do |k|
        f = tags.unsafe_fetch(k)
        if f & X_SHORT_VECTOR != 0
          raise ParseError.new("flags overrun") if p >= limit
          delta = d.unsafe_fetch(p).to_i64
          p += 1
          delta = -delta if f & X_POSITIVE == 0
        elsif f & SAME_X == 0
          raise ParseError.new("x coords overrun") if p + 2 > limit
          delta = ((d.unsafe_fetch(p).to_u16 << 8) | d.unsafe_fetch(p + 1)).to_i16!.to_i64
          p += 2
        else
          delta = 0_i64
        end
        x &+= delta
        xs << x
      end
      y = 0_i64
      i.times do |k|
        f = tags.unsafe_fetch(k)
        if f & Y_SHORT_VECTOR != 0
          raise ParseError.new("flags overrun") if p >= limit
          delta = d.unsafe_fetch(p).to_i64
          p += 1
          delta = -delta if f & Y_POSITIVE == 0
        elsif f & SAME_Y == 0
          raise ParseError.new("y coords overrun") if p + 2 > limit
          delta = ((d.unsafe_fetch(p).to_u16 << 8) | d.unsafe_fetch(p + 1)).to_i16!.to_i64
          p += 2
        else
          delta = 0_i64
        end
        y &+= delta
        ys << y
        # TT_Load_Simple_Glyph masks tags to the on-curve bit while
        # reading the y coordinates.
        tags[k] = f & ON_CURVE_POINT
      end

      {n_points, instructions, x_min, y_min, x_max, y_max}
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

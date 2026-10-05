# WOFF2 unwrapping with a selectable brotli backend.
#
# The whole file is only compiled when the `with_woff2' compile-time flag
# is given (`crystal build -Dwith_woff2 ...'), keeping the default build
# free of the brotli decoder. Trying to load a WOFF2 font without the flag
# raises a ParseError pointing at the flag (see `TT.unwrap_woff'). The
# backend is chosen at compile time:
#
#   * default: the pure-Crystal decoder shard brotli.cr
#   * -Dnative_brotli (together with -Dwith_woff2): libbrotlidec through
#     FFI, for an all-C reference build
#
# This is a port of FreeType's sfnt/sfwoff2.c (`woff2_open_font' plus the
# glyf/loca/hmtx reconstruction). WOFF2 collections (flavor 'ttcf') are
# parsed like FreeType does and the requested face's tables extracted;
# CFF2 charstring transforms are rejected as unknown transforms, matching
# what our pipeline supports. Spec: https://www.w3.org/TR/WOFF2/

{% if flag?(:native_brotli) %}
@[Link("brotlidec")]
lib LibBrotli
  fun decompress = BrotliDecoderDecompress(encoded_size : LibC::SizeT,
                                           encoded_buffer : UInt8*,
                                           decoded_size : LibC::SizeT*,
                                           decoded_buffer : UInt8*) : Int32
end
{% else %}
require "brotli"
{% end %}

module TT
  # WOFF2 known table tags, in the order given by the spec's table
  # directory format (woff2tags.c). The flag byte's low 6 bits index it.
  WOFF2_KNOWN_TAGS = ["cmap", "head", "hhea", "hmtx", "maxp", "name",
                      "OS/2", "post", "cvt ", "fpgm", "glyf", "loca",
                      "prep", "CFF ", "VORG", "EBDT", "EBLC", "gasp",
                      "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea",
                      "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC",
                      "JSTF", "MATH", "CBDT", "CBLC", "COLR", "CPAL",
                      "SVG ", "sbix", "acnt", "avar", "bdat", "bloc",
                      "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
                      "gvar", "hsty", "just", "lcar", "mort", "morx",
                      "opbd", "prop", "trak", "Zapf", "Silf", "Glat",
                      "Gloc", "Feat", "Sill"].map do |s|
    (s.byte_at(0).to_u32 << 24) | (s.byte_at(1).to_u32 << 16) |
      (s.byte_at(2).to_u32 << 8) | s.byte_at(3)
  end

  WOFF2_TAG_GLYF = 0x676C7966_u32 # 'glyf'
  WOFF2_TAG_LOCA = 0x6C6F6361_u32 # 'loca'
  WOFF2_TAG_HMTX = 0x686D7478_u32 # 'hmtx'
  WOFF2_TAG_HHEA = 0x68686561_u32 # 'hhea'
  WOFF2_TAG_HEAD = 0x68656164_u32 # 'head'
  WOFF2_TAG_MAXP = 0x6D617870_u32 # 'maxp'
  WOFF2_TAG_TTCF = 0x74636366_u32 # 'ttcf'

  # Flag bit marking a table as transformed (sfwoff2.h).
  WOFF2_FLAGS_TRANSFORM = 1_u32 << 8

  # `OVERLAP_SIMPLE' simple-glyph flag (glyf spec bit 6).
  WOFF2_OVERLAP_SIMPLE = 0x40_u8

  # An arbitrary, heuristic size limit (67MByte) for expanded WOFF2 data.
  WOFF2_MAX_SFNT_SIZE = 1_u32 << 26

  # Simple cursor over a byte range with bounds checks; every read past
  # the limit raises the same ParseError FreeType reports as
  # Invalid_Table.
  private class W2Cursor
    getter buf : Bytes
    property pos : Int32
    getter limit : Int32

    def initialize(@buf : Bytes, pos : Int32 = 0, limit : Int32 = buf.size)
      @pos = pos
      @limit = limit
    end

    private def need(n : Int32) : Nil
      raise ParseError.new("WOFF2 stream overrun") if @pos < 0 || @pos + n > @limit
    end

    def u8 : UInt8
      need(1)
      b = @buf.unsafe_fetch(@pos)
      @pos += 1
      b
    end

    def u16 : UInt16
      need(2)
      v = (@buf.unsafe_fetch(@pos).to_u16 << 8) | @buf.unsafe_fetch(@pos + 1)
      @pos += 2
      v
    end

    def i16 : Int16
      u16.to_i16!
    end

    def u32 : UInt32
      need(4)
      v = (@buf.unsafe_fetch(@pos).to_u32 << 24) | (@buf.unsafe_fetch(@pos + 1).to_u32 << 16) |
          (@buf.unsafe_fetch(@pos + 2).to_u32 << 8) | @buf.unsafe_fetch(@pos + 3)
      @pos += 4
      v
    end

    def skip(n : Int32) : Nil
      need(n)
      @pos += n
    end

    def bytes(n : Int32) : Bytes
      need(n)
      s = @buf[@pos, n]
      @pos += n
      s
    end

    # Read255UShort (WOFF2 spec 5.1): 0..252 literal, 253 = word follows,
    # 254/255 = one more byte with an offset.
    def u255 : UInt16
      code = u8
      case code
      when 253 then u16
      when 255 then u8.to_u16 + 253
      when 254 then u8.to_u16 + 506
      else        code.to_u16
      end
    end

    # ReadBase128 (WOFF2 spec 5.2): 7 bits per byte, high bit = continue.
    def base128 : UInt32
      result = 0_u32
      5.times do |i|
        code = u8
        raise ParseError.new("WOFF2 base128 leading zero") if i == 0 && code == 0x80
        raise ParseError.new("WOFF2 base128 overflow") unless result & 0xFE000000 == 0
        result = (result << 7) | (code & 0x7F)
        return result if code & 0x80 == 0
      end
      raise ParseError.new("WOFF2 base128 too long")
    end
  end

  # One directory entry of the WOFF2 table directory.
  private class W2Table
    property tag : UInt32
    property flags : UInt32 # low bits = transform version, bit 8 = transformed
    property src_offset : Int64 # offset in the uncompressed table stream
    property src_length : Int64 # TransformLength
    property dst_length : Int64 # origLength (reconstructed length)
    property transform_length : Int64
    property dst_offset : Int64 = 0

    def initialize(@tag, @flags, @src_offset, @transform_length, @dst_length)
      @src_length = @transform_length
    end

    def transformed? : Bool
      (@flags & WOFF2_FLAGS_TRANSFORM) != 0
    end
  end

  # One of the 7 substreams of a transformed `glyf' table.
  private class W2Sub
    getter start : Int32
    getter size : Int32
    property offset : Int32

    def initialize(@start : Int32, @size : Int32)
      @offset = @start
    end
  end

  ################################################################################

  private def self.w2_byte(buf : Bytes, pos : Int32) : UInt8
    raise ParseError.new("WOFF2 stream overrun") if pos < 0 || pos >= buf.size
    buf.unsafe_fetch(pos)
  end

  private def self.w2_u16(buf : Bytes, pos : Int32) : UInt16
    raise ParseError.new("WOFF2 stream overrun") if pos < 0 || pos + 2 > buf.size
    ru16(buf, pos)
  end

  private def self.w2_i16(buf : Bytes, pos : Int32) : Int16
    w2_u16(buf, pos).to_i16!
  end

  private def self.w2_u32(buf : Bytes, pos : Int32) : UInt32
    raise ParseError.new("WOFF2 stream overrun") if pos < 0 || pos + 4 > buf.size
    ru32(buf, pos)
  end

  private def self.w2_w16(d : Bytes, off : Int32, v : Int32) : Nil
    d[off] = (v >> 8).to_u8!
    d[off + 1] = v.to_u8!
  end

  private def self.w2_w32(d : Bytes, off : Int32, v : UInt32 | Int32) : Nil
    d[off] = (v >> 24).to_u8!
    d[off + 1] = (v >> 16).to_u8!
    d[off + 2] = (v >> 8).to_u8!
    d[off + 3] = v.to_u8!
  end

  # SFNT table checksum (compute_ULong_sum): sum of big-endian u32 words,
  # the tail shifted into the high bytes.
  private def self.w2_checksum(buf : Bytes) : UInt32
    sum = 0_u32
    i = 0
    while i + 4 <= buf.size
      sum &+= (buf.unsafe_fetch(i).to_u32 << 24) | (buf.unsafe_fetch(i + 1).to_u32 << 16) |
              (buf.unsafe_fetch(i + 2).to_u32 << 8) | buf.unsafe_fetch(i + 3)
      i += 4
    end
    shift = 24
    while i < buf.size
      sum &+= buf.unsafe_fetch(i).to_u32 << shift
      i += 1
      shift -= 8
    end
    sum
  end

  # Overflow-checked addition of glyph coordinates (safe_int_addition).
  private def self.w2_safe_add(a : Int32, b : Int32) : Int32
    r = a.to_i64 + b
    raise ParseError.new("WOFF2 coordinate overflow") if r > Int32::MAX || r < Int32::MIN
    r.to_i32
  end

  ################################################################################

  # Unwrap a WOFF2 font into a plain SFNT buffer. `face_index' selects a
  # face when the WOFF2 wraps a collection ('ttcf' flavor). Port of
  # `woff2_open_font' (sfwoff2.c).
  def self.unwrap_woff2(data : Bytes, face_index : Int32 = 0) : Bytes
    r = W2Cursor.new(data)
    signature = r.u32
    flavor = r.u32
    length = r.u32
    num_tables = r.u16
    r.skip(2) # reserved
    r.skip(4) # totalSfntSize (hint, we size the output ourselves)
    total_compressed_size = r.u32
    r.skip(4) # majorVersion + minorVersion
    meta_offset = r.u32
    meta_length = r.u32
    meta_orig_length = r.u32
    priv_offset = r.u32
    priv_length = r.u32

    raise ParseError.new("not a WOFF2 font") unless signature == 0x774F4632 # 'wOF2'
    raise ParseError.new("WOFF2 flavor must not be wOF2") if flavor == 0x774F4632

    # Miscellaneous header checks (ported 1:1).
    if length != data.size ||
       num_tables == 0 || num_tables > 0xFFF ||
       48 + num_tables.to_u64 * 20 >= length ||
       (meta_offset == 0 && (meta_length != 0 || meta_orig_length != 0)) ||
       (meta_length != 0 && meta_orig_length == 0) ||
       meta_offset >= length || length - meta_offset < meta_length ||
       (priv_offset == 0 && priv_length != 0) ||
       priv_offset >= length || length - priv_offset < priv_length
      raise ParseError.new("invalid WOFF2 header")
    end

    # Table directory.
    tables = Array(W2Table).new(num_tables)
    src_offset = 0_i64
    num_tables.times do
      flag_byte = r.u8
      if (flag_byte & 0x3F) == 0x3F
        tag = r.u32
      else
        tag = WOFF2_KNOWN_TAGS[flag_byte & 0x3F]
      end

      xform_version = ((flag_byte >> 6) & 0x03).to_u32
      flags = xform_version
      if tag == WOFF2_TAG_GLYF || tag == WOFF2_TAG_LOCA
        flags |= WOFF2_FLAGS_TRANSFORM if xform_version == 0
      elsif xform_version != 0
        flags |= WOFF2_FLAGS_TRANSFORM
      end

      dst_length = r.base128.to_i64
      transform_length = dst_length
      if (flags & WOFF2_FLAGS_TRANSFORM) != 0
        transform_length = r.base128.to_i64
        if tag == WOFF2_TAG_LOCA && transform_length != 0
          raise ParseError.new("WOFF2: invalid loca transformLength")
        end
      end

      raise ParseError.new("invalid WOFF2 table directory") if src_offset + transform_length < src_offset
      tables << W2Table.new(tag, flags, src_offset, transform_length, dst_length)
      src_offset += transform_length
    end

    # Uncompressed size = end of the last table in the table stream.
    last = tables.last
    uncompressed_size = last.src_offset + last.src_length
    raise ParseError.new("invalid WOFF2 table directory") if uncompressed_size < last.src_offset

    # Collection directory (WOFF2-wrapped TTC).
    if flavor == WOFF2_TAG_TTCF
      header_version = r.u32
      raise ParseError.new("invalid WOFF2 collection version") unless
        header_version == 0x00010000 || header_version == 0x00020000

      num_fonts = r.u255
      raise ParseError.new("invalid WOFF2 collection") if num_fonts == 0

      face_index = 0 if face_index >= num_fonts
      font_flavor = 0_u32
      font_tables = nil

      num_fonts.times do |nn|
        font_num_tables = r.u255
        font_flavor = r.u32
        indices = Array(UInt16).new(font_num_tables) { r.u255 }
        indices.each do |ix|
          raise ParseError.new("invalid WOFF2 table index") if ix >= num_tables
        end

        glyf_index = 0
        loca_index = 0
        indices.each do |ix|
          loca_index = ix if tables[ix].tag == WOFF2_TAG_LOCA
          glyf_index = ix if tables[ix].tag == WOFF2_TAG_GLYF
        end
        if glyf_index > 0 || loca_index > 0
          if glyf_index > loca_index || loca_index - glyf_index != 1
            raise ParseError.new("WOFF2: glyf and loca must be consecutive")
          end
        end

        if nn == face_index
          raise ParseError.new("invalid WOFF2 CollectionFontEntry") if
            font_num_tables == 0 || font_num_tables > 0xFFF
          font_tables = indices.map { |ix| tables[ix] }
        end
      end

      if ft = font_tables
        tables = ft
        flavor = font_flavor
        num_tables = tables.size.to_u16
      end
    end

    compressed_offset = r.pos
    file_offset = ((compressed_offset.to_u64 + total_compressed_size + 3) &~ 3).to_u64

    raise ParseError.new("invalid WOFF2 header") if file_offset > length
    if meta_offset != 0
      raise ParseError.new("invalid WOFF2 header") if file_offset != meta_offset
      file_offset = ((meta_offset.to_u64 + meta_length + 3) &~ 3)
    end
    if priv_offset != 0
      raise ParseError.new("invalid WOFF2 header") if file_offset != priv_offset
      file_offset = ((priv_offset.to_u64 + priv_length + 3) &~ 3)
    end
    if file_offset != ((length.to_u64 + 3) &~ 3)
      raise ParseError.new("invalid WOFF2 header")
    end

    raise ParseError.new("invalid WOFF2 table directory") if uncompressed_size < 1
    raise ParseError.new("WOFF2 expands beyond the size limit") if
      uncompressed_size > WOFF2_MAX_SFNT_SIZE

    # Decompress the brotli stream into the table stream, through the
    # compile-time selected backend (w2_brotli_decode below).
    raise ParseError.new("WOFF2 compressed data out of bounds") if
      compressed_offset.to_u64 + total_compressed_size > data.size
    uncompressed = w2_brotli_decode(data, compressed_offset,
                                    total_compressed_size, uncompressed_size)

    w2_reconstruct_font(uncompressed, tables, flavor)
  end

  ################################################################################

  # Decode the WOFF2 brotli stream `data[offset, size]' into exactly
  # `uncompressed_size' bytes; either a ParseError or a wrong length
  # reports the same stream mismatch FreeType does. The backend is
  # selected at compile time (see the file header).
  {% if flag?(:native_brotli) %}
  private def self.w2_brotli_decode(data : Bytes, offset : Int32,
                                    size : UInt32, uncompressed_size : Int64) : Bytes
    uncompressed = Bytes.new(uncompressed_size)
    decoded_size = LibC::SizeT.new(uncompressed_size)
    result = LibBrotli.decompress(LibC::SizeT.new(size),
                                  data.to_unsafe + offset,
                                  pointerof(decoded_size),
                                  uncompressed.to_unsafe)
    unless result == 1 && decoded_size == uncompressed_size # BROTLI_DECODER_RESULT_SUCCESS
      raise ParseError.new("WOFF2 brotli stream length mismatch")
    end
    uncompressed
  end
  {% else %}
  private def self.w2_brotli_decode(data : Bytes, offset : Int32,
                                    size : UInt32, uncompressed_size : Int64) : Bytes
    uncompressed = begin
      Brotli::Decoder.new.decode(data[offset, size])
    rescue Brotli::DecodeError
      raise ParseError.new("WOFF2 brotli stream length mismatch")
    end
    raise ParseError.new("WOFF2 brotli stream length mismatch") if
      uncompressed.size != uncompressed_size
    uncompressed
  end
  {% end %}

  # Rebuild a plain SFNT from the decompressed WOFF2 table stream; port
  # of `reconstruct_font' (sfwoff2.c). Tables come out sorted by tag with
  # fresh checksums and a fixed-up head checkSumAdjustment.
  private def self.w2_reconstruct_font(buf : Bytes, tables : Array(W2Table), flavor : UInt32) : Bytes
    glyf_table = tables.find { |t| t.tag == WOFF2_TAG_GLYF }
    loca_table = tables.find { |t| t.tag == WOFF2_TAG_LOCA }
    if (glyf_table.nil?) ^ (loca_table.nil?)
      raise ParseError.new("WOFF2: one of glyf/loca missing")
    end
    if g = glyf_table
      if (g.flags & WOFF2_FLAGS_TRANSFORM) != (loca_table.not_nil!.flags & WOFF2_FLAGS_TRANSFORM)
        raise ParseError.new("WOFF2: glyf/loca transformation mismatch")
      end
    end

    # Sort by tag and reject duplicate tags.
    tables.sort_by!(&.tag)
    (1...tables.size).each do |i|
      raise ParseError.new("WOFF2: duplicate table tag") if tables[i].tag == tables[i - 1].tag
    end

    num_hmetrics = 0
    num_glyphs = 0
    x_mins : Array(Int16)? = nil
    is_glyf_xform = false
    loca_out = Bytes.new(0)
    loca_checksum = 0_u32

    # {tag, checksum, body} in directory (sorted) order.
    entries = Array({UInt32, UInt32, Bytes}).new(tables.size)
    tables.each do |t|
      checksum = 0_u32
      body : Bytes

      unless t.transformed?
        raise ParseError.new("WOFF2 table out of bounds") if
          t.src_offset + t.src_length > buf.size
        body = buf[t.src_offset.to_i32, t.src_length.to_i32]
        if t.tag == WOFF2_TAG_HEAD
          raise ParseError.new("WOFF2: head too small") if t.src_length < 12
          body = body.dup
          w2_w32(body, 8, 0) # checkSumAdjustment = 0
        elsif t.tag == WOFF2_TAG_HHEA
          num_hmetrics = w2_u16(buf, t.src_offset.to_i32 + 34).to_i32
        end
        checksum = w2_checksum(body)
      else
        case t.tag
        when WOFF2_TAG_GLYF
          is_glyf_xform = true
          glyf_body, loca_out, checksum, loca_checksum, num_glyphs, x_mins =
            w2_reconstruct_glyf(buf, t, loca_table.not_nil!)
          body = glyf_body
        when WOFF2_TAG_LOCA
          body = loca_out
          checksum = loca_checksum
        when WOFF2_TAG_HMTX
          unless is_glyf_xform
            num_glyphs, x_mins = w2_get_x_mins(buf, tables, glyf_table.not_nil!, loca_table.not_nil!)
          end
          body, checksum = w2_reconstruct_hmtx(buf, t, num_glyphs, num_hmetrics, x_mins)
        else
          raise ParseError.new("WOFF2: unknown table transform")
        end
      end
      entries << {t.tag, checksum, body}
    end

    # Assemble the SFNT: header, sorted directory, table bodies padded
    # to 4-byte multiples.
    num_tables = entries.size
    entry_selector = num_tables.bit_length - 1
    search_range = 16 << entry_selector
    sfnt_size = 12 + 16*num_tables + entries.sum { |_, _, b| (b.size + 3) &~ 3 }

    sfnt = Bytes.new(sfnt_size, 0)
    w2_w32(sfnt, 0, flavor)
    w2_w16(sfnt, 4, num_tables)
    w2_w16(sfnt, 6, search_range)
    w2_w16(sfnt, 8, entry_selector)
    w2_w16(sfnt, 10, 16*num_tables - search_range)

    font_checksum = w2_checksum(sfnt[0, 12])
    head_offset = -1

    dir_off = 12
    data_off = 12 + 16*num_tables
    entries.each do |tag, checksum, body|
      head_offset = data_off if tag == WOFF2_TAG_HEAD
      body.copy_to(sfnt[data_off, body.size])
      w2_w32(sfnt, dir_off, tag)
      w2_w32(sfnt, dir_off + 4, checksum)
      w2_w32(sfnt, dir_off + 8, data_off)
      w2_w32(sfnt, dir_off + 12, body.size)
      font_checksum &+= checksum &+ w2_checksum(sfnt[dir_off, 16])
      dir_off += 16
      data_off += (body.size + 3) &~ 3
    end

    raise ParseError.new("WOFF2: head table missing") if head_offset < 0
    w2_w32(sfnt, head_offset + 8, 0xB1B0AFBA_u32 &- font_checksum)

    sfnt[0, data_off]
  end

  ################################################################################

  # Measure a composite glyph in the composite substream and report
  # whether it carries instructions (compositeGlyph_size, sfwoff2.c).
  private def self.w2_composite_size(buf : Bytes, sub : W2Sub) : {Int32, Bool}
    start = sub.offset
    pos = start
    have_instructions = false
    flags = TT::MORE_COMPONENTS # 0x20

    while flags & TT::MORE_COMPONENTS != 0
      raise ParseError.new("WOFF2 composite stream overrun") if pos + 2 > buf.size
      flags = ru16(buf, pos)
      pos += 2
      have_instructions ||= (flags & TT::WE_HAVE_INSTR) != 0

      arg_size = 2 # glyph index
      arg_size += (flags & TT::ARGS_ARE_WORDS) != 0 ? 4 : 2
      if flags & TT::WE_HAVE_A_SCALE != 0
        arg_size += 2
      elsif flags & TT::WE_HAVE_AN_XY_SCALE != 0
        arg_size += 4
      elsif flags & TT::WE_HAVE_A_2X2 != 0
        arg_size += 8
      end
      raise ParseError.new("WOFF2 composite stream overrun") if pos + arg_size > buf.size
      pos += arg_size
    end

    {pos - start, have_instructions}
  end

  # with_sign (sfwoff2.c): odd flag bit = positive.
  private def self.w2_with_sign(flag : Int32, base : Int32) : Int32
    (flag & 1) != 0 ? base : -base
  end

  # Decode the (flag, x, y) coordinate triplets of a simple glyph
  # (triplet_decode, sfwoff2.c / WOFF2 spec 5.2). Returns the decoded
  # coordinate arrays, on-curve flags and the number of input bytes used.
  # `n_points' comes from the nPoints stream; `flags_in' is the per-point
  # flag byte slice, `input' the remaining glyph substream bytes.
  private def self.w2_triplet_decode(flags_in : Bytes, input : Bytes,
                                     n_points : Int32)
    xs = Array(Int32).new(n_points, 0)
    ys = Array(Int32).new(n_points, 0)
    on_curve = Array(Bool).new(n_points, false)

    in_size = input.size
    raise ParseError.new("WOFF2 triplet overrun") if n_points > in_size

    triplet_index = 0
    x = 0
    y = 0

    n_points.times do |i|
      raise ParseError.new("WOFF2 triplet overrun") if i >= flags_in.size
      flag = flags_in.unsafe_fetch(i).to_i32
      on = (flag >> 7) == 0
      flag &= 0x7F

      data_bytes = case flag
                   when .< 84  then 1
                   when .< 120 then 2
                   when .< 124 then 3
                   else             4
                   end
      raise ParseError.new("WOFF2 triplet overrun") if
        triplet_index + data_bytes > in_size

      dx : Int32
      dy : Int32
      if flag < 10
        dx = 0
        dy = w2_with_sign(flag, ((flag & 14) << 7) + input.unsafe_fetch(triplet_index))
      elsif flag < 20
        dx = w2_with_sign(flag, (((flag - 10) & 14) << 7) + input.unsafe_fetch(triplet_index))
        dy = 0
      elsif flag < 84
        b0 = flag - 20
        b1 = input.unsafe_fetch(triplet_index)
        dx = w2_with_sign(flag, 1 + (b0 & 0x30) + (b1 >> 4))
        dy = w2_with_sign(flag >> 1, 1 + ((b0 & 0x0C) << 2) + (b1 & 0x0F))
      elsif flag < 120
        b0 = flag - 84
        dx = w2_with_sign(flag, 1 + ((b0 // 12) << 8) + input.unsafe_fetch(triplet_index))
        dy = w2_with_sign(flag >> 1, 1 + (((b0.remainder(12)) >> 2) << 8) +
                                   input.unsafe_fetch(triplet_index + 1))
      elsif flag < 124
        b2 = input.unsafe_fetch(triplet_index + 1).to_i32
        dx = w2_with_sign(flag, (input.unsafe_fetch(triplet_index).to_i32 << 4) + (b2 >> 4))
        dy = w2_with_sign(flag >> 1, ((b2 & 0x0F) << 8) + input.unsafe_fetch(triplet_index + 2))
      else
        dx = w2_with_sign(flag, (input.unsafe_fetch(triplet_index).to_i32 << 8) +
                                input.unsafe_fetch(triplet_index + 1))
        dy = w2_with_sign(flag >> 1, (input.unsafe_fetch(triplet_index + 2).to_i32 << 8) +
                                     input.unsafe_fetch(triplet_index + 3))
      end

      triplet_index += data_bytes
      x = w2_safe_add(x, dx)
      y = w2_safe_add(y, dy)

      xs[i] = x
      ys[i] = y
      on_curve[i] = on
    end

    {xs, ys, on_curve, triplet_index}
  end

  # Compute a simple glyph's bbox from the decoded points and write it
  # into `dst' at offset 2 (compute_bbox, sfwoff2.c).
  private def self.w2_compute_bbox(xs : Array(Int32), ys : Array(Int32),
                                   dst : Bytes) : Int16
    n_points = xs.size
    x_min = y_min = x_max = y_max = 0
    if n_points > 0
      x_min = x_max = xs.unsafe_fetch(0)
      y_min = y_max = ys.unsafe_fetch(0)
      1.upto(n_points - 1) do |i|
        x = xs.unsafe_fetch(i)
        y = ys.unsafe_fetch(i)
        x_min = x if x < x_min
        y_min = y if y < y_min
        x_max = x if x > x_max
        y_max = y if y > y_max
      end
    end

    w2_w16(dst, 2, x_min)
    w2_w16(dst, 4, y_min)
    w2_w16(dst, 6, x_max)
    w2_w16(dst, 8, y_max)
    x_min.to_i16!
  end

  # Serialize the decoded points of a simple glyph into TrueType
  # flag/coordinate encoding (store_points, sfwoff2.c); returns the final
  # glyph size. `dst' must hold 10 + 2*n_contours + 2 + instruction_len +
  # 5*n_points bytes.
  private def self.w2_store_points(xs : Array(Int32), ys : Array(Int32),
                                   on_curve : Array(Bool), n_contours : Int32,
                                   instruction_len : Int32, have_overlap : Bool,
                                   dst : Bytes) : Int32
    n_points = xs.size
    flag_offset = 10 + 2*n_contours + 2 + instruction_len
    last_flag = 0xFF_u8
    repeat_count = 0_u8
    last_x = 0
    last_y = 0
    x_bytes = 0
    y_bytes = 0

    n_points.times do |i|
      flag = on_curve.unsafe_fetch(i) ? TT::ON_CURVE_POINT : 0_u8
      dx = xs.unsafe_fetch(i) - last_x
      dy = ys.unsafe_fetch(i) - last_y

      flag |= TT::WOFF2_OVERLAP_SIMPLE if i == 0 && have_overlap

      if dx == 0
        flag |= TT::SAME_X
      elsif dx > -256 && dx < 256
        flag |= TT::X_SHORT_VECTOR | (dx > 0 ? TT::SAME_X : 0_u8)
        x_bytes += 1
      else
        x_bytes += 2
      end

      if dy == 0
        flag |= TT::SAME_Y
      elsif dy > -256 && dy < 256
        flag |= TT::Y_SHORT_VECTOR | (dy > 0 ? TT::SAME_Y : 0_u8)
        y_bytes += 1
      else
        y_bytes += 2
      end

      if flag == last_flag && repeat_count != 255
        dst[flag_offset - 1] |= TT::REPEAT_FLAG
        repeat_count += 1_u8
      else
        if repeat_count != 0
          raise ParseError.new("WOFF2 glyph buffer overrun") if flag_offset >= dst.size
          dst[flag_offset] = repeat_count
          flag_offset += 1
        end
        raise ParseError.new("WOFF2 glyph buffer overrun") if flag_offset >= dst.size
        dst[flag_offset] = flag
        flag_offset += 1
        repeat_count = 0_u8
      end

      last_x = xs.unsafe_fetch(i)
      last_y = ys.unsafe_fetch(i)
      last_flag = flag
    end

    if repeat_count != 0
      raise ParseError.new("WOFF2 glyph buffer overrun") if flag_offset >= dst.size
      dst[flag_offset] = repeat_count
      flag_offset += 1
    end

    xy_bytes = x_bytes + y_bytes
    raise ParseError.new("WOFF2 glyph buffer overrun") if
      flag_offset + xy_bytes > dst.size

    x_offset = flag_offset
    y_offset = flag_offset + x_bytes
    last_x = 0
    last_y = 0

    n_points.times do |i|
      dx = xs.unsafe_fetch(i) - last_x
      dy = ys.unsafe_fetch(i) - last_y

      if dx == 0
        # nothing
      elsif dx > -256 && dx < 256
        dst[x_offset] = dx.abs.to_u8
        x_offset += 1
      else
        w2_w16(dst, x_offset, dx.to_i16!)
        x_offset += 2
      end
      last_x += dx

      if dy == 0
        # nothing
      elsif dy > -256 && dy < 256
        dst[y_offset] = dy.abs.to_u8
        y_offset += 1
      else
        w2_w16(dst, y_offset, dy.to_i16!)
        y_offset += 2
      end
      last_y += dy
    end

    y_offset
  end

  # Reconstruct a transformed `glyf' table and the matching `loca'
  # (reconstruct_glyf, sfwoff2.c). Returns {glyf, loca, glyf_checksum,
  # loca_checksum, num_glyphs, x_mins} — the x_mins feed a transformed
  # `hmtx'.
  private def self.w2_reconstruct_glyf(buf : Bytes, glyf : W2Table, loca : W2Table)
    base = glyf.src_offset.to_i32
    limit = base + glyf.src_length.to_i32
    r = W2Cursor.new(buf, base, limit)

    r.skip(2) # reserved
    option_flags = r.u16
    num_glyphs = r.u16
    index_format = r.u16

    # loca length must match numGlyphs (WOFF2 6. conformance rules).
    expected_loca_length = (index_format == 0 ? 2 : 4) * (num_glyphs + 1)
    if loca.dst_length != expected_loca_length
      raise ParseError.new("WOFF2: loca length mismatch")
    end

    num_substreams = 7
    offset = 2 + 2 + 2 + 2 + num_substreams*4
    if offset > glyf.src_length
      raise ParseError.new("WOFF2: glyf transform too small")
    end

    subs = Array(W2Sub).new(num_substreams)
    num_substreams.times do
      size = r.u32
      raise ParseError.new("WOFF2 substream overflow") if
        size > glyf.src_length - offset
      subs << W2Sub.new(base + offset, size.to_i32)
      offset += size
    end

    overlap_bitmap_offset = 0
    if option_flags & 0x1 != 0
      overlap_bitmap_length = (num_glyphs + 7) >> 3
      raise ParseError.new("WOFF2 overlap bitmap overflow") if
        overlap_bitmap_length > glyf.src_length - offset
      overlap_bitmap_offset = base + offset
      offset += overlap_bitmap_length
    end

    bbox_bitmap_offset = subs[5].offset
    bbox_bitmap_length = ((num_glyphs + 31) >> 5) << 2
    subs[5].offset += bbox_bitmap_length

    glyf_io = IO::Memory.new
    loca_values = Array(Int64).new(num_glyphs + 1, 0)
    x_mins = Array(Int16).new(num_glyphs, 0_i16)
    glyf_checksum = 0_u32

    num_glyphs.times do |i|
      bbox_byte = w2_byte(buf, bbox_bitmap_offset + (i >> 3))
      have_bbox = (bbox_byte & (0x80 >> (i & 7))) != 0

      n_contours = w2_u16(buf, subs[0].offset)
      subs[0].offset += 2

      glyph_size = 0
      x_min = 0_i16

      if n_contours == 0xFFFF
        # Composite glyph: bbox from the bbox stream, components copied
        # verbatim, optional instructions.
        raise ParseError.new("WOFF2 composite without bbox") unless have_bbox

        composite_size, have_instructions = w2_composite_size(buf, subs[4])

        instruction_size = 0
        if have_instructions
          cr = W2Cursor.new(buf, subs[3].offset, subs[3].start + subs[3].size)
          instruction_size = cr.u255.to_i32
          subs[3].offset = cr.pos
        end

        glyph = Bytes.new(12 + composite_size + instruction_size)
        w2_w16(glyph, glyph_size, n_contours)
        glyph_size += 2

        x_min = w2_i16(buf, subs[5].offset)
        buf[subs[5].offset, 8].copy_to(glyph[glyph_size, 8])
        subs[5].offset += 8
        glyph_size += 8

        buf[subs[4].offset, composite_size].copy_to(glyph[glyph_size, composite_size])
        subs[4].offset += composite_size
        glyph_size += composite_size

        if have_instructions
          w2_w16(glyph, glyph_size, instruction_size)
          glyph_size += 2
          buf[subs[6].offset, instruction_size].copy_to(glyph[glyph_size, instruction_size])
          subs[6].offset += instruction_size
          glyph_size += instruction_size
        end
      elsif n_contours > 0
        # Simple glyph: points come from the triplet stream.
        have_overlap = false
        if overlap_bitmap_offset != 0
          overlap_byte = w2_byte(buf, overlap_bitmap_offset + (i >> 3))
          have_overlap = (overlap_byte & (0x80 >> (i & 7))) != 0
        end

        n_points_arr = Array(Int32).new(n_contours)
        cr = W2Cursor.new(buf, subs[1].offset, subs[1].start + subs[1].size)
        total_n_points = 0
        n_contours.times do
          npc = cr.u255.to_i32
          n_points_arr << npc
          raise ParseError.new("WOFF2 nPoints overflow") if
            total_n_points + npc < total_n_points
          total_n_points += npc
        end
        subs[1].offset = cr.pos

        flag_size = total_n_points
        raise ParseError.new("WOFF2 flag stream overflow") if
          flag_size > subs[2].size

        consumed3 = subs[3].offset - subs[3].start
        raise ParseError.new("WOFF2 glyph stream overflow") if
          subs[3].size < consumed3
        triplet_size = subs[3].size - consumed3

        raise ParseError.new("WOFF2 stream overrun") if
          subs[2].offset + flag_size > buf.size ||
          subs[3].offset + triplet_size > buf.size
        xs, ys, on_curve, used = w2_triplet_decode(
          buf[subs[2].offset, flag_size],
          buf[subs[3].offset, triplet_size],
          total_n_points)

        subs[2].offset += flag_size
        subs[3].offset += used

        cr = W2Cursor.new(buf, subs[3].offset, subs[3].start + subs[3].size)
        instruction_size = cr.u255.to_i32
        subs[3].offset = cr.pos

        raise ParseError.new("WOFF2: too many points") if total_n_points >= (1 << 27)

        glyph = Bytes.new(12 + 2*n_contours + 5*total_n_points + instruction_size)
        w2_w16(glyph, glyph_size, n_contours)
        glyph_size += 2

        if have_bbox
          x_min = w2_i16(buf, subs[5].offset)
          buf[subs[5].offset, 8].copy_to(glyph[glyph_size, 8])
          subs[5].offset += 8
        else
          x_min = w2_compute_bbox(xs, ys, glyph)
        end

        glyph_size = 10 # CONTOUR_OFFSET_END_POINT
        end_point = -1
        n_contours.times do |k|
          end_point += n_points_arr.unsafe_fetch(k)
          raise ParseError.new("WOFF2: too many points in contour") if end_point >= 65536
          w2_w16(glyph, glyph_size, end_point)
          glyph_size += 2
        end

        w2_w16(glyph, glyph_size, instruction_size)
        glyph_size += 2
        buf[subs[6].offset, instruction_size].copy_to(glyph[glyph_size, instruction_size])
        subs[6].offset += instruction_size
        glyph_size += instruction_size

        glyph_size = w2_store_points(xs, ys, on_curve, n_contours,
                                     instruction_size, have_overlap, glyph)
      else
        # Empty glyph; must not have a bbox.
        raise ParseError.new("WOFF2: empty glyph has a bbox") if have_bbox
        glyph = Bytes.new(0)
      end

      loca_values[i] = glyf_io.pos

      if glyph_size > 0
        glyf_io.write(glyph[0, glyph_size])
        glyf_checksum &+= w2_checksum(glyph[0, glyph_size])
      end
      pad = (4 - (glyf_io.pos & 3)) & 3
      glyf_io.write(Bytes.new(pad, 0)) if pad > 0

      x_mins[i] = x_min
    end

    glyf_out = glyf_io.to_slice
    loca_values[num_glyphs] = glyf_out.size

    offset_size = index_format == 0 ? 2 : 4
    loca_out = Bytes.new((num_glyphs + 1)*offset_size)
    (num_glyphs + 1).times do |i|
      v = loca_values.unsafe_fetch(i)
      if index_format == 0
        w2_w16(loca_out, 2*i, (v >> 1).to_i32)
      else
        w2_w32(loca_out, 4*i, v.to_u32!)
      end
    end
    loca_checksum = w2_checksum(loca_out)

    {glyf_out, loca_out, glyf_checksum, loca_checksum, num_glyphs.to_i32, x_mins}
  end

  # Read `numberOfHMetrics' style info for a transformed `hmtx' when the
  # `glyf' table is NOT transformed (get_x_mins, sfwoff2.c). Note: FreeType
  # skips 8 bytes of `maxp' before reading `numGlyphs' (field offset 4);
  # we reproduce that byte-exact behaviour to stay bug-compatible with
  # the oracle.
  private def self.w2_get_x_mins(buf : Bytes, tables : Array(W2Table),
                                 glyf : W2Table, loca : W2Table) : {Int32, Array(Int16)}
    maxp = tables.find { |t| t.tag == WOFF2_TAG_MAXP } ||
           raise(ParseError.new("WOFF2: maxp table missing"))
    head = tables.find { |t| t.tag == WOFF2_TAG_HEAD } ||
           raise(ParseError.new("WOFF2: head table missing"))

    num_glyphs = w2_u16(buf, maxp.src_offset.to_i32 + 8).to_i32 # see note above
    index_format = w2_u16(buf, head.src_offset.to_i32 + 50).to_i32
    offset_size = index_format == 0 ? 2 : 4

    x_mins = Array(Int16).new(num_glyphs, 0_i16)
    loca_offset = loca.src_offset.to_i32
    num_glyphs.times do |i|
      if index_format != 0
        glyf_offset = w2_u32(buf, loca_offset).to_i32
      else
        glyf_offset = w2_u16(buf, loca_offset).to_i32*2
      end
      loca_offset += offset_size
      x_mins[i] = w2_i16(buf, glyf.src_offset.to_i32 + glyf_offset + 2)
    end

    {num_glyphs, x_mins}
  end

  # Reconstruct a transformed `hmtx' (reconstruct_hmtx, sfwoff2.c).
  private def self.w2_reconstruct_hmtx(buf : Bytes, t : W2Table,
                                       num_glyphs : Int32, num_hmetrics : Int32,
                                       x_mins : Array(Int16)?) : {Bytes, UInt32}
    r = W2Cursor.new(buf, t.src_offset.to_i32, t.src_offset.to_i32 + t.src_length.to_i32)

    hmtx_flags = r.u8
    has_proportional_lsbs = (hmtx_flags & 1) == 0
    has_monospace_lsbs = (hmtx_flags & 2) == 0

    raise ParseError.new("WOFF2: reserved hmtx flags set") if hmtx_flags & 0xFC != 0
    raise ParseError.new("WOFF2: untransformed hmtx marked transformed") if
      has_proportional_lsbs && has_monospace_lsbs
    raise ParseError.new("WOFF2: invalid numberOfHMetrics") if
      num_hmetrics > num_glyphs || num_hmetrics < 1

    advance_widths = Array(Int16).new(num_hmetrics, 0_i16)
    num_hmetrics.times do |i|
      advance_widths[i] = r.i16
    end

    lsbs = Array(Int16).new(num_glyphs, 0_i16)
    num_hmetrics.times do |i|
      lsbs[i] = has_proportional_lsbs ? r.i16 : x_mins.not_nil!.unsafe_fetch(i)
    end
    (num_hmetrics...num_glyphs).each do |i|
      lsbs[i] = has_monospace_lsbs ? r.i16 : x_mins.not_nil!.unsafe_fetch(i)
    end

    hmtx = Bytes.new(2*num_hmetrics + 2*num_glyphs)
    off = 0
    num_glyphs.times do |i|
      if i < num_hmetrics
        w2_w16(hmtx, off, advance_widths.unsafe_fetch(i))
        off += 2
      end
      w2_w16(hmtx, off, lsbs.unsafe_fetch(i))
      off += 2
    end

    {hmtx, w2_checksum(hmtx)}
  end
end

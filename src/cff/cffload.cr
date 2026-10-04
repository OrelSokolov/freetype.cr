# CFF (Compact Font Format, CFF1 in an SFNT wrapper) table parser — a
# port of the FreeType master subset the unhinted glyph pipeline needs:
#
#   - `cffload.c': the header, INDEX structures (Name/Top DICT/String/
#     GlobalSubr/CharStrings/local Subrs), the charset (SID lists, needed
#     for seac), FDSelect + FDArray (CID subfonts) and the font-matrix
#     reconciliation from `cffobjs.c',
#   - `cffparse.c': DICT operand decoding — integers, 16.16 fixed and
#     binary-coded decimal reals (`cff_parse_real' verbatim, including
#     the scaling-exponent reconciliation), `cff_parse_font_matrix'.
#
# Bare CFF (own encoding/charset charmaps) and multiple-master fonts
# are intentionally not parsed; CFF2 is (32-bit INDEX counts, the
# FDArray-only layout, the VariationStore and the `blend'/`vsindex'
# operators in charstrings and Private DICTs). The blue/hinting
# private-dict entries are parsed for the Adobe hinting engine
# (cffhints.cr).

require "../tt/ttgxvar"

module CFF
  class ParseError < Exception
  end

  # Fixed-point replicas of the LP64 FreeType helpers (same formulas as
  # TT::Fixed in tt/loader.cr, kept local so the CFF module stands alone).
  module Fixed
    def self.mulfix(a : Int64, b : Int64) : Int64
      ab = a &* b
      (ab &+ 0x8000_i64 &- (ab < 0 ? 1_i64 : 0_i64)) >> 16
    end

    def self.divfix(a : Int64, b : Int64) : Int64
      s = 1_i8
      ua = a
      if ua < 0
        s = -s
        ua = -ua
      end
      ub = b
      if ub < 0
        s = -s
        ub = -ub
      end
      q = ub > 0 ? ((ua.to_u64! << 16) &+ (ub.to_u64! >> 1)) // ub : 0x7FFF_FFFF_u64
      q_i = q.to_i64!
      s < 0 ? -q_i : q_i
    end

    def self.muldiv(a : Int64, b : Int64, c : Int64) : Int64
      s = 1_i8
      ua = a
      if ua < 0
        s = -s
        ua = -ua
      end
      ub = b
      if ub < 0
        s = -s
        ub = -ub
      end
      uc = c
      if uc < 0
        s = -s
        uc = -uc
      end
      d = uc > 0 ? ((ua.to_u64! &* ub.to_u64!) &+ (uc.to_u64! >> 1)) // uc : 0x7FFF_FFFF_u64
      d_i = d.to_i64!
      s < 0 ? -d_i : d_i
    end
  end

  POWER_TENS = StaticArray(Int64, 10).new { |i| (10_i64)**i }

  def self.u8(d : Bytes, p : Int32) : UInt8
    raise ParseError.new("CFF: read past end") if p >= d.size
    d[p]
  end

  def self.u16(d : Bytes, p : Int32) : UInt16
    raise ParseError.new("CFF: read past end") if p + 2 > d.size
    (d[p].to_u16 << 8) | d[p + 1]
  end

  def self.u32(d : Bytes, p : Int32) : UInt32
    raise ParseError.new("CFF: read past end") if p + 4 > d.size
    (d[p].to_u32 << 24) | (d[p + 1].to_u32 << 16) |
      (d[p + 2].to_u32 << 8) | d[p + 3]
  end

  # --- DICT operand decoding (cffparse.c) --------------------------------

  # cff_parse_integer: `p' points at the first byte of the number,
  # `limit' is the exclusive end of the dict data.
  def self.parse_integer(d : Bytes, p : Int32, limit : Int32) : Int64
    v = CFF.u8(d, p)
    if v == 28
      raise ParseError.new("CFF: truncated integer") if p + 3 > limit
      ((CFF.u8(d, p + 1).to_u16 << 8) | CFF.u8(d, p + 2)).to_i16!.to_i64
    elsif v == 29
      raise ParseError.new("CFF: truncated integer") if p + 5 > limit
      ((CFF.u8(d, p + 1).to_u32 << 24) | (CFF.u8(d, p + 2).to_u32 << 16) |
        (CFF.u8(d, p + 3).to_u32 << 8) | CFF.u8(d, p + 4)).to_i32!.to_i64
    elsif v < 247
      v.to_i64 - 139
    elsif v < 251
      raise ParseError.new("CFF: truncated integer") if p + 2 > limit
      (v.to_i64 - 247) * 256 + CFF.u8(d, p + 1) + 108
    else
      raise ParseError.new("CFF: truncated integer") if p + 2 > limit
      -(v.to_i64 - 251) * 256 - CFF.u8(d, p + 1) - 108
    end
  end

  # cff_parse_real: nibble-encoded decimal. Returns {value 16.16,
  # scaling}. `want_scaling' selects the cff_parse_fixed_dynamic branch
  # (used by the FontMatrix handler).
  def self.parse_real(d : Bytes, start : Int32, limit : Int32,
                      power_ten : Int64, want_scaling : Bool) : {Int64, Int64}
    p = start
    phase = 4
    sign = false
    exponent_sign = false
    have_overflow = false
    exponent_add = 0_i64
    integer_length = 0_i64
    fraction_length = 0_i64
    number = 0_i64
    exponent = 0_i64
    nib = 0

    bad = ->{ return {0_i64, 0_i64} }
    overflow = ->{ return {sign ? -0x7FFF_FFFF_i64 : 0x7FFF_FFFF_i64, 0_i64} }
    underflow = ->{ return {0_i64, 0_i64} }

    # Integer part.
    loop do
      if phase != 0
        p += 1
        bad.call if p >= limit
      end
      nib = (d[p] >> phase) & 0xF
      phase = 4 - phase
      if nib == 0xE
        sign = true
      elsif nib > 9
        break
      else
        if number >= 0xCCCCCC
          exponent_add += 1
        elsif nib != 0 || number != 0
          integer_length += 1
          number = number * 10 + nib
        end
      end
    end

    # Fraction part.
    if nib == 0xA
      loop do
        if phase != 0
          p += 1
          bad.call if p >= limit
        end
        nib = (d[p] >> phase) & 0xF
        phase = 4 - phase
        break if nib >= 10
        if nib == 0 && number == 0
          exponent_add -= 1
        elsif number < 0xCCCCCC && fraction_length < 9
          fraction_length += 1
          number = number * 10 + nib
        end
      end
    end

    # Exponent part.
    if nib == 12
      exponent_sign = true
      nib = 11
    end
    if nib == 11
      loop do
        if phase != 0
          p += 1
          bad.call if p >= limit
        end
        nib = (d[p] >> phase) & 0xF
        phase = 4 - phase
        break if nib >= 10
        if exponent > 1000
          have_overflow = true
        else
          exponent = exponent * 10 + nib
        end
      end
      exponent = -exponent if exponent_sign
    end

    return {0_i64, 0_i64} if number == 0

    if have_overflow
      if exponent_sign
        underflow.call
      else
        overflow.call
      end
    end

    exponent += power_ten + exponent_add

    if want_scaling
      fraction_length += integer_length
      exponent += integer_length

      result = 0_i64
      scaling = 0_i64
      if fraction_length <= 5
        if number > 0x7FFF
          result = Fixed.divfix(number, 10)
          scaling = exponent - fraction_length + 1
        else
          if exponent > 0
            new_fraction_length = exponent < 5 ? exponent : 5
            shift = new_fraction_length - fraction_length
            if shift > 0
              exponent -= new_fraction_length
              number *= POWER_TENS[shift]
              if number > 0x7FFF
                number = number.tdiv(10)
                exponent += 1
              end
            else
              exponent -= fraction_length
            end
          else
            exponent -= fraction_length
          end
          result = number << 16
          scaling = exponent
        end
      else
        if number.tdiv(POWER_TENS[fraction_length - 5]) > 0x7FFF
          result = Fixed.divfix(number, POWER_TENS[fraction_length - 4])
          scaling = exponent - 4
        else
          result = Fixed.divfix(number, POWER_TENS[fraction_length - 5])
          scaling = exponent - 5
        end
      end
      {sign ? -result : result, scaling}
    else
      integer_length += exponent
      fraction_length -= exponent

      overflow.call if integer_length > 5
      underflow.call if integer_length < -5

      if integer_length < 0
        number = number.tdiv(POWER_TENS[-integer_length])
        fraction_length += integer_length
      end

      # This can only happen if the exponent was non-zero.
      if fraction_length == 10
        number = number.tdiv(10)
        fraction_length -= 1
      end

      if fraction_length > 0
        # C jumps to Exit with result still 0 here (quiet underflow).
        return {0_i64, 0_i64} if number.tdiv(POWER_TENS[fraction_length]) > 0x7FFF
        result = Fixed.divfix(number, POWER_TENS[fraction_length])
        {sign ? -result : result, 0_i64}
      else
        number *= POWER_TENS[-fraction_length]
        overflow.call if number > 0x7FFF
        result = number << 16
        {sign ? -result : result, 0_i64}
      end
    end
  end

  # cff_parse_num: integer-valued view of an operand.
  def self.parse_num(d : Bytes, p : Int32, limit : Int32) : Int64
    if d[p] == 30
      parse_real(d, p, limit, 0, false)[0] >> 16
    elsif d[p] == 255
      # Internal 16.16 blend values, converted to integer with rounding
      # on the top 24 bits (cff_parse_num).
      ((((CFF.u8(d, p + 1).to_u32 << 16) | (CFF.u8(d, p + 2).to_u32 << 8) |
        CFF.u8(d, p + 3)) + 0x80) >> 8).to_u16.to_i16.to_i64
    else
      parse_integer(d, p, limit)
    end
  end

  # cff_parse_fixed (do_fixed with scaling == 0).
  def self.parse_fixed(d : Bytes, p : Int32, limit : Int32) : Int64
    if d[p] == 30
      parse_real(d, p, limit, 0, false)[0]
    elsif d[p] == 255
      ((CFF.u8(d, p + 1).to_u32 << 24) | (CFF.u8(d, p + 2).to_u32 << 16) |
        (CFF.u8(d, p + 3).to_u32 << 8) | CFF.u8(d, p + 4)).to_i32.to_i64
    else
      val = parse_integer(d, p, limit)
      return val > 0 ? 0x7FFF_FFFF_i64 : -0x7FFF_FFFF_i64 if val > 0x7FFF || val < -0x7FFF
      val << 16
    end
  end

  # cff_kind_delta (cffparse.c): a cumulative delta-decoded integer
  # array, truncated to `max' entries before decoding.
  def self.parse_delta_num(d : Bytes, args : Array(Int32), limit : Int32,
                           max : Int32) : Array(Int64)
    out = [] of Int64
    val = 0_i64
    args.first(max).each do |p|
      val = val &+ parse_num(d, p, limit)
      out << val
    end
    out
  end

  # cff_kind_delta_fixed: the same with 16.16 operands (blue arrays).
  def self.parse_delta_fixed(d : Bytes, args : Array(Int32), limit : Int32,
                             max : Int32) : Array(Int64)
    out = [] of Int64
    val = 0_i64
    args.first(max).each do |p|
      val = val &+ parse_fixed(d, p, limit)
      out << val
    end
    out
  end

  # cff_blend_build_vector (cffload.c): the per-region scalars for the
  # normalized design vector, BV[0] = 1.0 for the default master.
  # Shared by the charstring interpreter's blend operator and the CFF2
  # Private DICT re-parse under variations. len_ndv == 0 (no variation
  # instance set) produces the default vector (1, 0, 0, ...).
  def self.build_blend_vector(store : TT::ItemVarStore, vsindex : Int32,
                              ndv : Array(Int64)?) : Array(Int64)
    len_ndv = ndv.try(&.size) || 0
    raise ParseError.new("CFF: blend axis count mismatch") \
      if len_ndv != 0 && len_ndv != store.axis_count
    raise ParseError.new("CFF: blend vsindex out of range") \
      if vsindex >= store.var_data.size

    var_data = store.var_data[vsindex]
    len = var_data.region_indices.size + 1 # + 1 for the default master
    bv = Array(Int64).new(len, 0_i64)
    bv[0] = 0x1_0000_i64

    (1...len).each do |master|
      idx = var_data.region_indices.unsafe_fetch(master - 1)
      raise ParseError.new("CFF: blend region index out of range") \
        if idx >= store.region_count

      if len_ndv == 0
        next # default vector (1, 0, 0, ...)
      end

      bv[master] = 0x1_0000_i64
      region = store.regions.unsafe_fetch(idx)
      len_ndv.times do |j|
        axis = region.unsafe_fetch(j)
        ndv_j = ndv.not_nil!.unsafe_fetch(j)
        if axis.peak_coord == ndv_j || axis.peak_coord == 0
          next # full contribution, or invalid axis
        elsif ndv_j <= axis.start_coord || ndv_j >= axis.end_coord
          bv[master] = 0_i64
          break
        elsif ndv_j < axis.peak_coord
          bv[master] = CFF::Fixed.muldiv(bv[master],
                                         ndv_j - axis.start_coord,
                                         axis.peak_coord - axis.start_coord)
        else
          bv[master] = CFF::Fixed.muldiv(bv[master],
                                         axis.end_coord - ndv_j,
                                         axis.end_coord - axis.peak_coord)
        end
      end
    end

    bv
  end

  # cff_parse_fixed_dynamic: {value 16.16, decimal scaling}.
  def self.parse_fixed_dynamic(d : Bytes, p : Int32, limit : Int32) : {Int64, Int64}
    return parse_real(d, p, limit, 0, true) if d[p] == 30

    number = parse_integer(d, p, limit)
    if number > 0x7FFF
      integer_length = 5_i64
      while integer_length < 10
        break if number < POWER_TENS[integer_length]
        integer_length += 1
      end
      if number.tdiv(POWER_TENS[integer_length - 5]) > 0x7FFF
        return {Fixed.divfix(number, POWER_TENS[integer_length - 4]),
                integer_length - 4}
      else
        return {Fixed.divfix(number, POWER_TENS[integer_length - 5]),
                integer_length - 5}
      end
    end
    {number << 16, 0_i64}
  end

  # --- DICT framework (cff_parser_run) -----------------------------------

  # A parsed DICT: each operator with the byte positions of its operand
  # run. Field extraction happens in the loaders below with the exact
  # cffparse.c numeric semantics (num/fixed/fixed_dynamic).
  class Dict
    getter ops : Array({Int32, Array(Int32)}) = [] of {Int32, Array(Int32)}

    def self.parse(d : Bytes, start : Int32, end_pos : Int32) : Dict
      dict = Dict.new
      p = start
      stack = [] of Int32
      while p < end_pos
        v = d[p]
        if v >= 27 && v != 31 && v != 255
          # A number: remember its position, then skip it.
          raise ParseError.new("CFF: DICT stack overflow") if stack.size >= 96
          stack << p
          if v == 30
            p += 1
            loop do
              raise ParseError.new("CFF: unterminated real") if p >= end_pos
              break if (d[p] >> 4) == 15 || (d[p] & 0xF) == 15
              p += 1
            end
          elsif v == 28
            p += 2
          elsif v == 29
            p += 4
          elsif v > 246
            p += 1
          end
        else
          code = v.to_i32
          if v == 12
            p += 1
            raise ParseError.new("CFF: truncated operator") if p >= end_pos
            code = 0x100 | d[p]
          end
          dict.ops << {code, stack}
          stack = [] of Int32
        end
        p += 1
      end
      dict
    end
  end

  # --- Top/Font DICT + Private DICT data ----------------------------------

  # One (sub)font: the Font DICT fields the glyph pipeline consumes,
  # plus its Private DICT. `cff_subfont_load' / `cff_load_private_dict'.
  class SubFont
    property charstrings_offset : Int64 = 0
    property charset_offset : Int64 = 0
    property private_size : Int64 = 0
    property private_offset : Int64 = 0
    property cid_registry : Int64 = 0xFFFF # 0xFFFF = not CID (missing)
    property cid_fd_array_offset : Int64 = 0
    property cid_fd_select_offset : Int64 = 0
    # CFF2 Top DICT: the VariationStore offset (operator 24) and the
    # operand stack limit (operator 25, CFF2_DEFAULT_STACK = 513).
    property vstore_offset : Int64 = 0
    property maxstack : Int32 = 48

    # FontMatrix in 16.16 plus the units_per_em implied by its scaling
    # (cff_parse_font_matrix); `cffobjs.c' normalises both afterwards.
    property has_font_matrix = false
    property matrix_xx : Int64 = 0x1_0000
    property matrix_yx : Int64 = 0
    property matrix_xy : Int64 = 0
    property matrix_yy : Int64 = 0x1_0000
    property offset_x : Int64 = 0
    property offset_y : Int64 = 0
    property units_per_em : Int64 = 0

    # Private DICT (cff_load_private_dict defaults).
    property local_subrs_offset : Int64 = 0
    property default_width : Int64 = 0
    property nominal_width : Int64 = 0
    property initial_random_seed : Int64 = 0
    property local_subrs : Index?
    # CFF2 Private DICT: the default ItemVariationData index (operator 22).
    property vsindex : Int32 = 0

    # Hinting entries (cfftoken.h CFF_FIELD_*). Blue arrays are stored
    # delta-decoded in 16.16; BlueScale is value*1000 in 16.16 (the
    # "1000 times" convention of cffload.c); the rest are integers.
    property blue_values : Array(Int64) = [] of Int64      # max 14
    property other_blues : Array(Int64) = [] of Int64      # max 10
    property family_blues : Array(Int64) = [] of Int64     # max 14
    property family_other_blues : Array(Int64) = [] of Int64 # max 10
    property blue_scale : Int64 = 2_596_928_i64 # (FT_Fixed)(0.039625*0x10000*1000)
    property blue_shift : Int64 = 7
    property blue_fuzz : Int64 = 1
    property std_hw : Int64 = 0 # StdHW (standard_width)
    property std_vw : Int64 = 0 # StdVW (standard_height)
    property stem_snap_h : Array(Int64) = [] of Int64 # max 13
    property stem_snap_v : Array(Int64) = [] of Int64 # max 13
    property language_group : Int64 = 0

    # The RNG state (xorshift, psobjs.c cff_random); seeded from the
    # private dict's InitialRandomSeed (deterministic, unlike the C
    # driver's address-derived default seed — see face.cr notes).
    property random : UInt32 = 0_u32

    def parse_font_dict!(d : Bytes, dict : Dict) : Nil
      dict.ops.each_with_index do |(code, args), _|
        case code
        when 0x107 # FontMatrix
          next unless args.size >= 6
          parse_font_matrix(d, args)
        when 15 # charset
          @charset_offset = CFF.parse_num(d, args[0], d.size) if args.size >= 1
        when 17 # CharStrings
          @charstrings_offset = CFF.parse_num(d, args[0], d.size) if args.size >= 1
        when 18 # Private [size offset]
          if args.size >= 2
            @private_size = CFF.parse_num(d, args[0], d.size)
            @private_offset = CFF.parse_num(d, args[1], d.size)
          end
        when 0x11E # ROS
          if args.size >= 3
            @cid_registry = CFF.parse_num(d, args[0], d.size)
            # cid_ordering / cid_supplement unused by the pipeline.
          end
        when 0x124 # FDArray
          @cid_fd_array_offset = CFF.parse_num(d, args[0], d.size) if args.size >= 1
        when 0x125 # FDSelect
          @cid_fd_select_offset = CFF.parse_num(d, args[0], d.size) if args.size >= 1
        when 24 # vstore (CFF2 only)
          @vstore_offset = CFF.parse_num(d, args[0], d.size) if args.size >= 1
        when 25 # maxstack (CFF2 only)
          if args.size >= 1
            v = CFF.parse_num(d, args[0], d.size)
            @maxstack = v.to_i32 if v > 0 && v <= 0xFFFF
          end
        end
      end
    end

    # cff_parse_font_matrix: reconcile the operands' decimal scalings so
    # no precision is lost; the residual power of ten lands in upm.
    private def parse_font_matrix(d : Bytes, args : Array(Int32)) : Nil
      values = args.map { |p| CFF.parse_fixed_dynamic(d, p, d.size) }
      max_scaling = Int64::MIN
      min_scaling = Int64::MAX
      values.each do |_, scaling|
        max_scaling = scaling if scaling > max_scaling
        min_scaling = scaling if scaling < min_scaling
      end

      if max_scaling < -9 || max_scaling > 0 || max_scaling - min_scaling < 0 ||
         max_scaling - min_scaling > 9
        # Strange scaling values: use the default matrix (cffobjs.c does
        # the same through the FT_Matrix_Check fallback below).
        return
      end

      scaled = StaticArray(Int64, 6).new(0_i64)
      values.each_with_index do |pair, i|
        value, scaling = pair
        next if value == 0
        divisor = POWER_TENS[max_scaling - scaling]
        half_divisor = divisor >> 1
        scaled[i] = value < 0 ? (value - half_divisor).tdiv(divisor)
                              : (value + half_divisor).tdiv(divisor)
      end

      @matrix_xx = scaled[0]
      @matrix_yx = scaled[1]
      @matrix_xy = scaled[2]
      @matrix_yy = scaled[3]
      @offset_x = scaled[4]
      @offset_y = scaled[5]
      @units_per_em = POWER_TENS[-max_scaling]
      @has_font_matrix = true

      unless matrix_check?
        # Degenerate values: default matrix, upm 1 (Unlikely path).
        @matrix_xx = 0x1_0000; @matrix_yx = 0
        @matrix_xy = 0; @matrix_yy = 0x1_0000
        @offset_x = 0; @offset_y = 0
        @units_per_em = 1
      end
    end

    # FT_Matrix_Check (ftcalc.c).
    private def matrix_check? : Bool
      xx = @matrix_xx; xy = @matrix_xy
      yx = @matrix_yx; yy = @matrix_yy
      val = xx.abs.to_u64! | xy.abs.to_u64! | yx.abs.to_u64! | yy.abs.to_u64!
      return false if val == 0 || val > 0x7FFF_FFFF_u64

      shift = (63 - val.leading_zeros_count) - 32 - 2
      if shift > 0
        xx >>= shift; xy >>= shift
        yx >>= shift; yy >>= shift
      end
      abs_det = (xx &* yy &- xy &* yx).abs.to_u64!
      frob_sq = (xx.to_u64! &* xx.to_u64!) &+ (xy.to_u64! &* xy.to_u64!) &+
                (yx.to_u64! &* yx.to_u64!) &+ (yy.to_u64! &* yy.to_u64!)
      abs_det <= frob_sq // 32
    end

    # cff_parser_run over the Private DICT: operators consume an operand
    # *value* stack. Plain operands remember their byte position (pos >= 0)
    # and are decoded lazily; CFF2 `blend' results live on the stack as
    # 16.16 fixed numbers (pos < 0), exactly like FreeType's reserved
    # 255-entries that cff_blend_doBlend writes back into the parser
    # stack. `blend_store'/`ndv' are set for a CFF2 face with a live
    # variation instance; without them the dict parses statically.
    def parse_private_dict!(d : Bytes, start : Int32,
                            blend_store : TT::ItemVarStore? = nil,
                            ndv : Array(Int64)? = nil) : Nil
      limit = start + @private_size.to_i32
      dict = Dict.parse(d, start, limit)

      vals = [] of {Int32, Int64}
      bv : Array(Int64)? = nil
      bv_vsindex = -1
      vsindex = @vsindex

      dict.ops.each do |code, arg_positions|
        arg_positions.each { |p| vals << {p, 0_i64} }
        case code
        when 23 # blend (CFF2 DICT operator 23; 16 is the charstring one):
          # fold the deltas into the base values
          if store = blend_store
            if bv.nil? || bv_vsindex != vsindex
              bv = CFF.build_blend_vector(store, vsindex, ndv)
              bv_vsindex = vsindex
            end
            blend_vals!(d, limit, vals, bv.not_nil!)
          end
        when 22 # vsindex (CFF2 only): the default ItemVariationData index
          if vals.size >= 1
            v = pv_num(d, limit, vals[0])
            if v >= 0
              vsindex = v.to_i32
              @vsindex = vsindex
            end
          end
        when 19 # Subrs (relative to the Private DICT start)
          @local_subrs_offset = pv_num(d, limit, vals[0]) if vals.size >= 1
        when 20 # defaultWidthX
          @default_width = pv_num(d, limit, vals[0]) if vals.size >= 1
        when 21 # nominalWidthX
          @nominal_width = pv_num(d, limit, vals[0]) if vals.size >= 1
        when 0x113 # initialRandomSeed
          @initial_random_seed = pv_num(d, limit, vals[0]) if vals.size >= 1
        when 6 # BlueValues (delta, 16.16, max 14)
          @blue_values = pv_delta(d, limit, vals, 14, fixed: true)
        when 7 # OtherBlues (max 10)
          @other_blues = pv_delta(d, limit, vals, 10, fixed: true)
        when 8 # FamilyBlues (max 14)
          @family_blues = pv_delta(d, limit, vals, 14, fixed: true)
        when 9 # FamilyOtherBlues (max 10)
          @family_other_blues = pv_delta(d, limit, vals, 10, fixed: true)
        when 0x109 # BlueScale (real, stored *1000)
          if vals.size >= 1
            @blue_scale = pv_fixed(d, limit, vals[0]) &* 1000
          end
        when 0x10A # BlueShift
          @blue_shift = pv_num(d, limit, vals[0]) if vals.size >= 1
        when 0x10B # BlueFuzz
          @blue_fuzz = pv_num(d, limit, vals[0]) if vals.size >= 1
        when 10 # StdHW
          @std_hw = pv_num(d, limit, vals[0]) if vals.size >= 1
        when 11 # StdVW
          @std_vw = pv_num(d, limit, vals[0]) if vals.size >= 1
        when 0x10C # StemSnapH (delta, integers, max 13)
          @stem_snap_h = pv_delta(d, limit, vals, 13, fixed: false)
        when 0x10D # StemSnapV
          @stem_snap_v = pv_delta(d, limit, vals, 13, fixed: false)
        when 0x111 # LanguageGroup
          @language_group = pv_num(d, limit, vals[0]) if vals.size >= 1
        end
        # cff_parser_run leaves the blended results on the operand stack
        # for the following field operator (the stack is only cleared for
        # non-blend fields).
        vals.clear unless code == 23
      end

      # cff_load_private_dict sanitization: an odd BlueValues count
      # drops the last entry; BlueShift/BlueFuzz out of [0,1000] reset.
      unless @blue_values.empty? || @blue_values.size.even?
        @blue_values.pop
      end
      if @blue_shift > 1000 || @blue_shift < 0
        @blue_shift = 7
      end
      if @blue_fuzz > 1000 || @blue_fuzz < 0
        @blue_fuzz = 1
      end

      # Sanitize the seed exactly like cff_load_private_dict.
      if @initial_random_seed < 0
        @initial_random_seed = -@initial_random_seed
      elsif @initial_random_seed == 0
        @initial_random_seed = 987654321
      end
    end

    # cff_parse_num over a value-stack entry: plain operands decode from
    # `d'; blended entries (pos < 0) round like the reserved-255 decode in
    # cffparse.c — drop the low byte of the 16.16 value, then round the
    # top 24 bits and truncate to a signed 16-bit integer.
    private def pv_num(d : Bytes, limit : Int32, v : {Int32, Int64}) : Int64
      pos, fixed = v
      return CFF.parse_num(d, pos, limit) if pos >= 0
      u = fixed.to_i32!.to_u32!
      (((u >> 8) &+ 0x80_u32) >> 8).to_u16.to_i16.to_i64
    end

    # cff_parse_fixed over a value-stack entry: blended entries are
    # already 16.16 (cff_blend_doBlend writes the full 32-bit sum back).
    private def pv_fixed(d : Bytes, limit : Int32, v : {Int32, Int64}) : Int64
      pos, fixed = v
      return CFF.parse_fixed(d, pos, limit) if pos >= 0
      fixed.to_i32!.to_i64
    end

    # cff_parse_delta over value-stack entries: cumulative sums,
    # truncated to `max' entries before decoding.
    private def pv_delta(d : Bytes, limit : Int32,
                         vals : Array({Int32, Int64}), max : Int32,
                         fixed : Bool) : Array(Int64)
      out = [] of Int64
      val = 0_i64
      vals.first(max).each do |v|
        val = val &+ (fixed ? pv_fixed(d, limit, v) : pv_num(d, limit, v))
        out << val
      end
      out
    end

    # cff_blend_doBlend over the Private DICT value stack: the last entry
    # is `numBlends'; before it sit numBlends base values each followed by
    # lenBV-1 deltas. Both collapse into `numBlends' 16.16 results, the
    # sums wrapping at 32 bits exactly like the FT_Fixed arithmetic.
    private def blend_vals!(d : Bytes, limit : Int32,
                            vals : Array({Int32, Int64}),
                            bv : Array(Int64)) : Nil
      raise ParseError.new("CFF: blend underflow") if vals.empty?

      num_blends = pv_num(d, limit, vals[vals.size - 1])
      raise ParseError.new("CFF: blend underflow") if num_blends < 0

      len_bv = bv.size
      count = vals.size - 1
      num_operands = num_blends &* len_bv
      raise ParseError.new("CFF: blend underflow") if num_operands > count

      base = (count - num_operands).to_i32
      delta = base + num_blends.to_i32
      num_blends.to_i32.times do |i|
        sum = pv_fixed(d, limit, vals[base + i])
        (1...len_bv).each do |j|
          sum = (sum &+ CFF::Fixed.mulfix(bv.unsafe_fetch(j),
                                          pv_fixed(d, limit, vals[delta])))
                .to_u32!.to_i32!.to_i64
          delta += 1
        end
        vals[base + i] = {-1, sum}
      end
      # leave only the `num_blends' results on the stack (the numBlends
      # operand goes too: FT sets parser->top = base + numBlends).
      (num_operands - num_blends + 1).times { vals.pop }
    end
  end

  # --- INDEX (cffload.c cff_index_*) ---------------------------------------

  # An INDEX structure over the table bytes: `count' elements, offsets
  # decoded up front (equivalent to cff_index_load_offsets).
  class Index
    getter count : Int32
    getter data_offset : Int32 # absolute (table-relative) position of the data
    getter data_size : Int32
    getter offsets : Array(Int64)
    getter end_pos : Int32 # first position after the whole INDEX

    def self.parse(d : Bytes, start : Int32, cff2 : Bool = false) : Index
      # CFF2 INDEXes carry a 32-bit count (cff_index_init's cff2 branch).
      count = cff2 ? CFF.u32(d, start).to_i32 : CFF.u16(d, start).to_i32
      count_size = cff2 ? 4 : 2
      if count == 0
        return Index.new(0, start + count_size, 0, [] of Int64,
                         start + count_size)
      end

      off_size = CFF.u8(d, start + count_size).to_i32
      raise ParseError.new("CFF: invalid INDEX offSize") if off_size < 1 || off_size > 4

      offsets_pos = start + count_size + 1
      offsets = Array(Int64).new(count + 1) do |i|
        p = offsets_pos + i * off_size
        v = 0_u64
        off_size.times do |k|
          v = (v << 8) | CFF.u8(d, p + k)
        end
        v.to_i64
      end

      last = offsets[count]
      raise ParseError.new("CFF: invalid INDEX size") if last == 0
      data_size = (last - 1).to_i32
      data_offset = offsets_pos + (count + 1) * off_size
      raise ParseError.new("CFF: INDEX out of bounds") if data_offset + data_size > d.size

      Index.new(count, data_offset, data_size, offsets,
                data_offset + data_size)
    end

    def initialize(@count, @data_offset, @data_size, @offsets, @end_pos)
    end

    # cff_index_access_element: {start position, length} of element i,
    # or nil for an empty/invalid entry. The C comparison is unsigned,
    # so a negative index is "out of range", never a look-behind.
    def element(d : Bytes, i : Int32) : {Int32, Int32}?
      return nil unless i >= 0 && i < @count
      off1 = @offsets[i]
      return nil if off1 == 0

      j = i
      off2 = 0_i64
      loop do
        j += 1
        off2 = @offsets[j]
        break unless off2 == 0 && j < @count
      end

      # Clamp to the end of the table (the C code clamps to the stream).
      max_off = d.size - @data_offset + 1
      off2 = max_off if off2 > max_off

      if off2 > off1
        {@data_offset + off1.to_i32 - 1, (off2 - off1).to_i32}
      end
    end
  end

  # --- FDSelect (cffload.c) -----------------------------------------------

  class FdSelect
    getter format : Int32
    getter data : Array(UInt8)   # format 0: fd per glyph
    getter ranges : Array({Int32, Int32}) # format 3: {first, fd}, sentinel last

    def self.parse(d : Bytes, num_glyphs : Int32, start : Int32) : FdSelect
      fmt = CFF.u8(d, start).to_i32
      case fmt
      when 0
        data = Array(UInt8).new(num_glyphs) { |i| CFF.u8(d, start + 1 + i) }
        FdSelect.new(0, data, [] of {Int32, Int32})
      when 3
        n_ranges = CFF.u16(d, start + 1).to_i32
        p = start + 3
        ranges = [] of {Int32, Int32}
        n_ranges.times do
          first = CFF.u16(d, p).to_i32
          fd = CFF.u8(d, p + 2).to_i32
          ranges << {first, fd}
          p += 3
        end
        # sentinel = CFF.u16(d, p) — stored as the last range's end below
        sentinel = CFF.u16(d, p).to_i32
        ranges << {sentinel, -1}
        FdSelect.new(3, [] of UInt8, ranges)
      else
        raise ParseError.new("CFF: invalid FDSelect format")
      end
    end

    def initialize(@format, @data, @ranges)
    end

    # cff_fd_select_get: ranges hold {first, fd} with the trailing
    # sentinel stored as the final pair's `first' (fd = -1 there).
    def fd(glyph_index : Int32) : Int32
      case @format
      when 0
        @data[glyph_index]?.try(&.to_i32) || 0
      when 3
        i = 0
        while i + 1 < @ranges.size
          first, f = @ranges[i]
          break if glyph_index < first
          limit = @ranges[i + 1][0]
          return f if glyph_index < limit
          i += 1
        end
        0
      else
        0
      end
    end
  end

  # --- Predefined charsets / Adobe Standard Encoding (cffload.c) ---------

  ISOADOBE_CHARSET = (0..228).map { |i| i.to_u16 }

  EXPERT_CHARSET = [
    0, 1, 229, 230, 231, 232, 233, 234,
    235, 236, 237, 238, 13, 14, 15, 99,
    239, 240, 241, 242, 243, 244, 245, 246,
    247, 248, 27, 28, 249, 250, 251, 252,
    253, 254, 255, 256, 257, 258, 259, 260,
    261, 262, 263, 264, 265, 266, 109, 110,
    267, 268, 269, 270, 271, 272, 273, 274,
    275, 276, 277, 278, 279, 280, 281, 282,
    283, 284, 285, 286, 287, 288, 289, 290,
    291, 292, 293, 294, 295, 296, 297, 298,
    299, 300, 301, 302, 303, 304, 305, 306,
    307, 308, 309, 310, 311, 312, 313, 314,
    315, 316, 317, 318, 158, 155, 163, 319,
    320, 321, 322, 323, 324, 325, 326, 150,
    164, 169, 327, 328, 329, 330, 331, 332,
    333, 334, 335, 336, 337, 338, 339, 340,
    341, 342, 343, 344, 345, 346, 347, 348,
    349, 350, 351, 352, 353, 354, 355, 356,
    357, 358, 359, 360, 361, 362, 363, 364,
    365, 366, 367, 368, 369, 370, 371, 372,
    373, 374, 375, 376, 377, 378,
  ].map(&.to_u16)

  EXPERTSUBSET_CHARSET = [
    0, 1, 231, 232, 235, 236, 237, 238,
    13, 14, 15, 99, 239, 240, 241, 242,
    243, 244, 245, 246, 247, 248, 27, 28,
    249, 250, 251, 253, 254, 255, 256, 257,
    258, 259, 260, 261, 262, 263, 264, 265,
    266, 109, 110, 267, 268, 269, 270, 272,
    300, 301, 302, 305, 314, 315, 158, 155,
    163, 320, 321, 322, 323, 324, 325, 326,
    150, 164, 169, 327, 328, 329, 330, 331,
    332, 333, 334, 335, 336, 337, 338, 339,
    340, 341, 342, 343, 344, 345, 346,
  ].map(&.to_u16)

  STANDARD_ENCODING = [
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 2, 3, 4, 5, 6, 7, 8,
    9, 10, 11, 12, 13, 14, 15, 16,
    17, 18, 19, 20, 21, 22, 23, 24,
    25, 26, 27, 28, 29, 30, 31, 32,
    33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48,
    49, 50, 51, 52, 53, 54, 55, 56,
    57, 58, 59, 60, 61, 62, 63, 64,
    65, 66, 67, 68, 69, 70, 71, 72,
    73, 74, 75, 76, 77, 78, 79, 80,
    81, 82, 83, 84, 85, 86, 87, 88,
    89, 90, 91, 92, 93, 94, 95, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 96, 97, 98, 99, 100, 101, 102,
    103, 104, 105, 106, 107, 108, 109, 110,
    0, 111, 112, 113, 114, 0, 115, 116,
    117, 118, 119, 120, 121, 122, 0, 123,
    0, 124, 125, 126, 127, 128, 129, 130,
    131, 0, 132, 133, 0, 134, 135, 136,
    137, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 138, 0, 139, 0, 0, 0,
    0, 140, 141, 142, 143, 0, 0, 0,
    0, 0, 144, 0, 0, 0, 145, 0,
    0, 146, 147, 148, 149, 0, 0, 0,
  ].map(&.to_u16)

  # Subroutine bias (cffcalc/cffdecode.c).
  def self.subr_bias(count : Int32) : Int32
    if count < 1240
      107
    elsif count < 33900
      1131
    else
      32768
    end
  end

  # xorshift RNG (psobjs.c cff_random).
  def self.cff_random(r : UInt32) : UInt32
    r ^= (r << 13) & 0xFFFF_FFFF_u32
    r ^= r >> 17
    r ^= (r << 5) & 0xFFFF_FFFF_u32
    r
  end

  # --- The CFF font (cff_font_load + the cffobjs.c matrix pass) ----------

  class Font
    getter data : Bytes
    getter global_subrs : Index
    getter charstrings : Index
    getter top_font : SubFont
    getter subfonts : Array(SubFont) = [] of SubFont
    getter fd_select : FdSelect?
    getter charset_sids : Array(UInt16) = [] of UInt16
    getter num_glyphs : Int32
    getter cid_keyed : Bool
    # CFF2 flavor (no Name/String INDEX, FDArray-mandatory, blend ops).
    getter? cff2 : Bool = false

    def initialize(table : Bytes, face_upem : Int32)
      d = table
      @data = table
      raise ParseError.new("CFF: table too small") if d.size < 4
      version_major = CFF.u8(d, 0)
      hdr_size = CFF.u8(d, 2)

      if version_major == 2
        # CFF2 header: majorVersion, minorVersion, hdrSize, topDictLength
        # (u16); no Name/String INDEX — the Top DICT data follow the
        # header directly, then the global subrs INDEX (cff_font_load).
        @cff2 = true
        raise ParseError.new("CFF: not a CFF2 font header") if hdr_size < 5
        raise ParseError.new("CFF: truncated CFF2 header") if d.size < 5
        top_dict_len = ((d[3].to_u16 << 8) | d[4]).to_i32
        raise ParseError.new("CFF: bad CFF2 top dict length") if hdr_size.to_i32 + top_dict_len > d.size

        pos = hdr_size.to_i32
        @top_font = SubFont.new
        @top_font.maxstack = 513 # CFF2_DEFAULT_STACK (cffparse.h)
        top_dict = Dict.parse(d, pos, pos + top_dict_len)
        @top_font.parse_font_dict!(d, top_dict)
        pos += top_dict_len
        @global_subrs = Index.parse(d, pos, true)
      else
        @cff2 = false
        abs_off = CFF.u8(d, 3)
        unless version_major == 1 && hdr_size >= 4 && abs_off <= 4
          raise ParseError.new("CFF: not a CFF1 font header")
        end

        pos = hdr_size.to_i32
        name_index = Index.parse(d, pos)
        font_dict_index = Index.parse(d, name_index.end_pos)
        string_index = Index.parse(d, font_dict_index.end_pos)
        @global_subrs = Index.parse(d, string_index.end_pos)

        # An SFNT-wrapped CFF holds exactly one font.
        if name_index.count > 1
          raise ParseError.new("CFF: multiple subfonts in SFNT wrapper")
        end

        @top_font = SubFont.new
        entry = font_dict_index.element(d, 0)
        raise ParseError.new("CFF: no Top DICT") unless entry
        top_dict = Dict.parse(d, entry[0], entry[0] + entry[1])
        @top_font.parse_font_dict!(d, top_dict)
      end

      raise ParseError.new("CFF: no charstrings offset") if @top_font.charstrings_offset == 0
      @charstrings = Index.parse(d, @top_font.charstrings_offset.to_i32, @cff2)
      @num_glyphs = @charstrings.count

      @cid_keyed = @cff2 || @top_font.cid_registry != 0xFFFF
      if @cid_keyed
        # CFF2 always resolves through the FDArray (its top DICT has no
        # Private); CID-keyed CFF1 does the same via ROS.
        fd_index = Index.parse(d, @top_font.cid_fd_array_offset.to_i32, @cff2)
        fd_index.count.times do |i|
          sub = SubFont.new
          sub.maxstack = @top_font.maxstack
          if e = fd_index.element(d, i)
            sub.parse_font_dict!(d, Dict.parse(d, e[0], e[0] + e[1]))
          end
          load_private_dict(d, sub)
          @subfonts << sub
        end
        # CFF2 omits FDSelect when there is exactly one FD (cffload.c).
        if @num_glyphs > 0 && (!@cff2 || fd_index.count > 1)
          @fd_select = FdSelect.parse(d, @num_glyphs,
            @top_font.cid_fd_select_offset.to_i32)
        end
      else
        load_private_dict(d, @top_font)
      end

      # CFF2 has no charset (glyph names do not exist; seac neither).
      @charset_sids = @cff2 ? Array(UInt16).new(0) : (load_charset(d, @top_font.charset_offset) if @num_glyphs > 0) || Array(UInt16).new(0)
      normalize_matrices(face_upem)
    end

    # The charstring bytes of a glyph: {start, length} or nil.
    def charstring(gid : Int32) : {Int32, Int32}?
      @charstrings.element(@data, gid)
    end

    # The subfont owning a glyph (cff_slot_load's FDSelect lookup with
    # the fd clamp).
    def subfont_for(gid : Int32) : SubFont
      return @top_font if @subfonts.empty?
      fd = @fd_select.try(&.fd(gid)) || 0
      fd = @subfonts.size - 1 if fd >= @subfonts.size
      @subfonts[fd]
    end

    # cff_lookup_glyph_by_stdcharcode: Adobe Standard Encoding code to
    # glyph index through the charset SIDs (seac components).
    def glyph_by_stdcharcode(code : Int32) : Int32
      return -1 if code < 0 || code > 255
      sid = STANDARD_ENCODING[code]
      @charset_sids.index(sid) || -1
    end

    private def load_private_dict(d : Bytes, sub : SubFont) : Nil
      if sub.private_offset != 0 && sub.private_size != 0
        sub.parse_private_dict!(d, sub.private_offset.to_i32)
        if sub.local_subrs_offset != 0
          sub.local_subrs = Index.parse(
            d, sub.private_offset.to_i32 + sub.local_subrs_offset.to_i32,
            @cff2)
        end
      end
      # RNG seed: FreeType seeds from an address-derived driver value
      # (non-deterministic by design); we use the private dict's
      # InitialRandomSeed, which is what FT falls back to when the
      # driver seed is zero.
      sub.random = sub.initial_random_seed.to_u32!
    end

    # CFF2: re-parse the Private DICTs under the current variation
    # instance so the `blend' operator inside them takes effect on the
    # hinting entries (BlueValues, Std*VW/H, StemSnap). FreeType re-parses
    # whenever the blend vector changes; coordinates only change through
    # the face's set_var_design, so reblending there is equivalent.
    # Local subrs/offsets are layout, not values — untouched.
    def reblend_private_dicts(store : TT::ItemVarStore?,
                              ndv : Array(Int64)?) : Nil
      return unless store
      subs = @subfonts.dup
      subs << @top_font
      subs.each do |sub|
        next if sub.private_offset == 0 || sub.private_size == 0
        sub.parse_private_dict!(@data, sub.private_offset.to_i32, store, ndv)
      end
    end

    # cff_charset_load: gid -> SID (identity ISOAdobe, Expert and
    # ExpertSubset predefined charsets included).
    private def load_charset(d : Bytes, offset : Int64) : Array(UInt16)
      num = @num_glyphs
      if offset > 2
        sids = Array(UInt16).new(num, 0_u16)
        pos = offset.to_i32
        fmt = CFF.u8(d, pos).to_i32
        case fmt
        when 0
          j = 1
          while j < num
            sids[j] = CFF.u16(d, pos + 1 + 2 * (j - 1))
            j += 1
          end
        when 1, 2
          j = 1
          p = pos + 1
          while j < num
            glyph_sid = CFF.u16(d, p).to_i32
            p += 2
            nleft = fmt == 2 ? CFF.u16(d, p).to_i32 : CFF.u8(d, p).to_i32
            p += fmt == 2 ? 2 : 1

            nleft = 0xFFFF - glyph_sid if glyph_sid > 0xFFFF - nleft

            i = 0
            while j < num && i <= nleft
              sids[j] = glyph_sid.to_u16!
              i += 1
              j += 1
              glyph_sid += 1
            end
          end
        else
          raise ParseError.new("CFF: invalid charset format")
        end
        sids
      else
        case offset
        when 0
          raise ParseError.new("CFF: implicit charset too large") if num > 229
          ISOADOBE_CHARSET[0, num]
        when 1
          raise ParseError.new("CFF: implicit charset too large") if num > 166
          EXPERT_CHARSET[0, num]
        when 2
          raise ParseError.new("CFF: implicit charset too large") if num > 87
          EXPERTSUBSET_CHARSET[0, num]
        else
          raise ParseError.new("CFF: invalid charset offset")
        end
      end
    end

    # The cffobjs.c pass: reconcile the FontMatrix with the SFNT upem,
    # concatenate CID subfont matrices, normalise yy to 1.0 and move the
    # offsets to whole font units.
    private def normalize_matrices(face_upem : Int32) : Nil
      top = @top_font
      top.units_per_em = face_upem.to_i64 unless top.has_font_matrix
      normalize(top)

      i = @subfonts.size
      while i > 0
        i -= 1
        sub = @subfonts[i]

        if sub.has_font_matrix
          if top.has_font_matrix
            scaling = if top.units_per_em > 1 && sub.units_per_em > 1
                        top.units_per_em < sub.units_per_em ? top.units_per_em : sub.units_per_em
                      else
                        1_i64
                      end

            # FT_Matrix_Multiply_Scaled(top, sub, scaling)
            val = 0x1_0000_i64 &* scaling
            xx = Fixed.muldiv(top.matrix_xx, sub.matrix_xx, val) &+
                 Fixed.muldiv(top.matrix_xy, sub.matrix_yx, val)
            xy = Fixed.muldiv(top.matrix_xx, sub.matrix_xy, val) &+
                 Fixed.muldiv(top.matrix_xy, sub.matrix_yy, val)
            yx = Fixed.muldiv(top.matrix_yx, sub.matrix_xx, val) &+
                 Fixed.muldiv(top.matrix_yy, sub.matrix_yx, val)
            yy = Fixed.muldiv(top.matrix_yx, sub.matrix_xy, val) &+
                 Fixed.muldiv(top.matrix_yy, sub.matrix_yy, val)
            sub.matrix_xx = xx
            sub.matrix_xy = xy
            sub.matrix_yx = yx
            sub.matrix_yy = yy

            # FT_Vector_Transform_Scaled(sub.offset, top.matrix, scaling)
            ox = Fixed.muldiv(sub.offset_x, top.matrix_xx, val) &+
                 Fixed.muldiv(sub.offset_y, top.matrix_xy, val)
            oy = Fixed.muldiv(sub.offset_x, top.matrix_yx, val) &+
                 Fixed.muldiv(sub.offset_y, top.matrix_yy, val)
            sub.offset_x = ox
            sub.offset_y = oy

            sub.units_per_em = Fixed.muldiv(sub.units_per_em,
                                            top.units_per_em, scaling)
          end
        else
          sub.matrix_xx = top.matrix_xx
          sub.matrix_yx = top.matrix_yx
          sub.matrix_xy = top.matrix_xy
          sub.matrix_yy = top.matrix_yy
          sub.offset_x = top.offset_x
          sub.offset_y = top.offset_y
          sub.units_per_em = top.units_per_em
        end

        normalize(sub)
      end
    end

    # The per-dict normalisation block of cff_face_init.
    private def normalize(sub : SubFont) : Nil
      temp = sub.matrix_yy != 0 ? sub.matrix_yy.abs : sub.matrix_yx.abs
      if temp != 0x1_0000
        sub.units_per_em = Fixed.divfix(sub.units_per_em, temp)
        sub.matrix_xx = Fixed.divfix(sub.matrix_xx, temp)
        sub.matrix_yx = Fixed.divfix(sub.matrix_yx, temp)
        sub.matrix_xy = Fixed.divfix(sub.matrix_xy, temp)
        sub.matrix_yy = Fixed.divfix(sub.matrix_yy, temp)
        sub.offset_x = Fixed.divfix(sub.offset_x, temp)
        sub.offset_y = Fixed.divfix(sub.offset_y, temp)
      end
      sub.offset_x >>= 16
      sub.offset_y >>= 16
    end
  end
end

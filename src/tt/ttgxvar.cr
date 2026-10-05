# GX font variations, part 1: `fvar' and `avar'.
#
# 1:1 port of the corresponding parts of FreeType 2.13.3
# src/truetype/ttgxvar.c (TT_Get_MM_Var, ft_var_load_avar,
# ft_var_to_normalized, ft_var_to_design) plus the `fvar' validity check
# from src/sfnt/sfobjs.c (sfnt_init_face). gvar/HVAR/MVAR/cvar and the
# `avar' v2 ItemVariationStore/axisMap deltas are later stages.
#
# FreeType synthesizes an extra named instance when a font omits the
# default instance (this needs `name' table lookups); the named-instance
# list has no effect on outlines or advances, so this port keeps only
# the table's own instances.

# Big-endian readers shared by the variation table parsers.
private module BE
  def self.u16(d : Bytes, off : Int) : UInt16
    (d[off].to_u16 << 8) | d[off + 1]
  end

  def self.i16(d : Bytes, off : Int) : Int16
    u16(d, off).to_i16!
  end

  def self.u32(d : Bytes, off : Int) : UInt32
    (d[off].to_u32 << 24) | (d[off + 1].to_u32 << 16) |
      (d[off + 2].to_u32 << 8) | d[off + 3]
  end

  def self.i32(d : Bytes, off : Int) : Int64
    u32(d, off).to_i32!.to_i64
  end
end

module TT
  # FT_Var_Axis (ftmm.h) + the axis flags FreeType stores separately.
  struct VarAxis
    getter tag : UInt32
    getter minimum : Int64 # 16.16 design coordinates
    getter default : Int64
    getter maximum : Int64
    getter flags : UInt16
    getter strid : UInt16 # nameID
    getter name : String  # the tag as ASCII, like FT's synthesized names

    def initialize(@tag : UInt32, minimum : Int64, default : Int64,
                   maximum : Int64, @flags : UInt16, @strid : UInt16)
      # An axis with inconsistent limits is disabled (TT_Get_MM_Var).
      if minimum > default || default > maximum
        minimum = default
        maximum = default
      end
      @minimum = minimum
      @default = default
      @maximum = maximum
      @name = String.new(Bytes[(tag >> 24).to_u8!, (tag >> 16).to_u8!,
                               (tag >> 8).to_u8!, tag.to_u8!])
    end
  end

  # FT_Var_Named_Style.
  struct NamedStyle
    getter strid : UInt16
    getter psid : UInt16 # 0xFFFF when the font carries no PS name
    getter coords : Array(Int64) # design coordinates (16.16)

    def initialize(@strid, @psid, @coords)
    end
  end

  # One `shortFracCorrespondence' pair of `avar' (F2DOT14 widened to
  # 16.16, like FT_fdot14ToFixed).
  struct AVarCorrespondence
    getter from_coord : Int64
    getter to_coord : Int64

    def initialize(@from_coord, @to_coord)
    end
  end

  # The segment data of `avar' — one per axis.
  struct AVarSegment
    getter pair_count : Int32
    getter correspondence : Array(AVarCorrespondence)

    def initialize(@pair_count, @correspondence)
    end
  end

  # TupleCount flags of the `gvar' table (GX_TupleCountFlags).
  GX_TC_TUPLES_SHARE_POINT_NUMBERS = 0x8000
  GX_TC_TUPLE_COUNT_MASK           = 0x0FFF

  # TupleIndex flags of the `gvar'/`cvar' tables (GX_TupleIndexFlags).
  GX_TI_EMBEDDED_TUPLE_COORD  = 0x8000
  GX_TI_INTERMEDIATE_TUPLE    = 0x4000
  GX_TI_PRIVATE_POINT_NUMBERS = 0x2000
  GX_TI_TUPLE_INDEX_MASK      = 0x0FFF

  # One axis' coordinates within a variation region (GX_AxisCoordsRec).
  struct RegionAxis
    getter start_coord : Int64 # 16.16
    getter peak_coord : Int64
    getter end_coord : Int64

    def initialize(@start_coord, @peak_coord, @end_coord)
    end
  end

  # One ItemVariationData subtable (GX_ItemVarDataRec); `delta_set' keeps
  # the raw bytes, decoded per lookup like FreeType does.
  class ItemVarData
    getter item_count : Int32
    getter word_delta_count : Int32
    getter long_words : Bool
    getter region_indices : Array(Int32)
    getter delta_set : Bytes

    def initialize(@item_count, @word_delta_count, @long_words,
                   @region_indices, @delta_set)
    end

    def per_region_size : Int32
      s = @word_delta_count + @region_indices.size
      @long_words ? s*2 : s
    end
  end

  # The Item Variation Store (GX_ItemVarStoreRec).
  class ItemVarStore
    getter axis_count : Int32
    getter region_count : Int32
    getter regions : Array(Array(RegionAxis)) # [region_count][axis_count]
    getter var_data : Array(ItemVarData)

    def initialize(@axis_count, @region_count, @regions, @var_data)
    end

    # tt_var_load_item_variation_store; `d' is the containing table and
    # `offset' the store's offset within it. ParseError on inconsistencies.
    def self.load(d : Bytes, offset : Int64, num_axis : Int32) : ItemVarStore
      o = offset
      raise ParseError.new("var store out of bounds") if o < 0 || o + 8 > d.size
      raise ParseError.new("bad var store format") if BE.u16(d, o) != 1

      region_offset = BE.u32(d, o + 2).to_i64
      data_count = BE.u16(d, o + 6).to_i32
      raise ParseError.new("var store missing varData") if data_count == 0

      data_offsets = Array(Int64).new(data_count) { |i| BE.u32(d, o + 8 + 4*i).to_i64 }
      raise ParseError.new("var store data offsets out of bounds") if
        o + 8 + 4*data_count > d.size

      # region list
      r = o + region_offset
      raise ParseError.new("var store region list out of bounds") if
        r < 0 || r + 4 > d.size
      axis_count = BE.u16(d, r).to_i32
      region_count = BE.u16(d, r + 2).to_i32
      # num_axis == 0 skips the check (the CFF2 vstore loads before the
      # fvar axis count is known).
      raise ParseError.new("var store axis count mismatch") if
        num_axis != 0 && axis_count != num_axis
      raise ParseError.new("too many variation regions") if region_count >= 32768

      need = region_count * axis_count * 6
      raise ParseError.new("var store region list truncated") if
        r + 4 + need > d.size
      regions = Array(Array(RegionAxis)).new(region_count) do |i|
        Array(RegionAxis).new(axis_count) do |j|
          q = r + 4 + 6*(i*axis_count + j)
          start = BE.i16(d, q).to_i32
          peak = BE.i16(d, q + 2).to_i32
          end_ = BE.i16(d, q + 4).to_i32

          # immediately tag invalid ranges with special peak = 0
          if (start < 0 && end_ > 0) || start > peak || peak > end_
            peak = 0
          end
          RegionAxis.new(start.to_i64*4, peak.to_i64*4, end_.to_i64*4)
        end
      end

      # varData items
      var_data = Array(ItemVarData).new(data_count) do |i|
        p = o + data_offsets[i]
        raise ParseError.new("varData out of bounds") if
          p < 0 || p + 6 > d.size

        item_count = BE.u16(d, p).to_i32
        word_delta_count = BE.u16(d, p + 2)
        region_idx_count = BE.u16(d, p + 4).to_i32
        long_words = (word_delta_count & 0x8000) != 0
        word_delta_count &= 0x7FFF

        raise ParseError.new("bad short/region count in varData") if
          word_delta_count > region_idx_count
        raise ParseError.new("inconsistent regionCount in varData") if
          region_idx_count > region_count

        raise ParseError.new("varData indices truncated") if
          p + 6 + 2*region_idx_count > d.size
        region_indices = Array(Int32).new(region_idx_count) do |k|
          ri = BE.u16(d, p + 6 + 2*k).to_i32
          raise ParseError.new("bad region index") if ri >= region_count
          ri
        end

        per_region = word_delta_count.to_i32 + region_idx_count
        per_region *= 2 if long_words
        total = per_region * item_count
        q = p + 6 + 2*region_idx_count
        raise ParseError.new("deltaSet read failed") if
          q < 0 || q + total > d.size

        ItemVarData.new(item_count, word_delta_count.to_i32, long_words,
                        region_indices, d[q, total])
      end

      new(axis_count, region_count, regions, var_data)
    end
  end

  # A DeltaSetIndexMap (GX_DeltaSetIdxMapRec); nil maps to a nil class.
  class DeltaSetIndexMap
    getter map_count : Int32
    getter outer_index : Array(UInt16)
    getter inner_index : Array(UInt16)

    def initialize(@map_count, @outer_index, @inner_index)
    end

    # tt_var_load_delta_set_index_mapping; `table_len' is the containing
    # table's length (the rough sanity bound).
    def self.load(d : Bytes, offset : Int64, store : ItemVarStore,
                  table_len : Int32) : DeltaSetIndexMap
      o = offset
      raise ParseError.new("index map out of bounds") if o < 0 || o + 4 > d.size

      format = d[o]
      entry_format = d[o + 1]

      if format == 0
        map_count = BE.u16(d, o + 2).to_i32
        p = o + 4
      elsif format == 1
        raise ParseError.new("index map truncated") if o + 8 > d.size
        map_count = BE.u32(d, o + 4).to_i32
        p = o + 8
      else
        raise ParseError.new("bad index map format")
      end

      raise ParseError.new("bad index map entry format") if entry_format & 0xC0 != 0

      entry_size = (((entry_format & 0x30) >> 4) + 1).to_i32 # bytes per entry
      inner_bit_count = ((entry_format & 0x0F) + 1).to_i32
      inner_index_mask = (1 << inner_bit_count) - 1

      raise ParseError.new("invalid number of index mappings") if
        map_count.to_i64 * entry_size > table_len

      raise ParseError.new("index map truncated") if
        p + map_count * entry_size > d.size

      outer_index = Array(UInt16).new(map_count, 0_u16)
      inner_index = Array(UInt16).new(map_count, 0xFFFF_u16)
      map_count.times do |i|
        map_data = 0_u32
        entry_size.times do |j|
          map_data = (map_data << 8) | d[p + entry_size*i + j]
        end

        # no variation data for this item
        next if map_data == 0xFFFF_FFFF_u32

        outer = map_data >> inner_bit_count
        raise ParseError.new("outerIndex out of range") if
          outer >= store.var_data.size
        inner = map_data & inner_index_mask
        raise ParseError.new("innerIndex out of range") if
          inner >= store.var_data[outer].item_count

        outer_index[i] = outer.to_u16
        inner_index[i] = inner.to_u16
      end

      new(map_count, outer_index, inner_index)
    end
  end

  # An `HVAR'/`VVAR' table (GX_HVVarTableRec).
  class HVVarTable
    getter item_store : ItemVarStore
    getter width_map : DeltaSetIndexMap?

    def initialize(@item_store, @width_map)
    end

    # ft_var_load_hvvar; nil when the table is missing or invalid (a
    # missing table is normal, an invalid one disables the adjustments).
    def self.load(d : Bytes?, num_axis : Int32) : HVVarTable?
      return nil if d.nil? || d.size < 12
      return nil if BE.u16(d, 0) != 1 # major version

      store_offset = BE.u32(d, 4).to_i64
      width_map_offset = BE.u32(d, 8).to_i64

      begin
        store = ItemVarStore.load(d, store_offset, num_axis)
      rescue ParseError
        return nil
      end

      width_map = nil
      if width_map_offset != 0
        begin
          width_map = DeltaSetIndexMap.load(d, width_map_offset, store, d.size)
        rescue ParseError
          return nil
        end
      end

      new(store, width_map)
    end
  end

  # One `MVAR' value record (ft_var_load_mvar): the metric tag, its
  # (outer, inner) indices into the store, and the font-unit value
  # captured before any variation was applied — repeated applications
  # restore from `unmodified' rather than accumulate.
  class MvarValue
    getter tag : UInt32
    getter outer_index : Int32
    getter inner_index : Int32
    property unmodified : Int32 = 0

    def initialize(@tag : UInt32, @outer_index : Int32, @inner_index : Int32)
    end
  end

  # The parsed `MVAR' table: the ItemVariationStore plus the tagged
  # value records pointing into it.
  class MvarTable
    getter item_store : ItemVarStore
    getter values : Array(MvarValue)

    def initialize(@item_store : ItemVarStore, @values : Array(MvarValue))
    end
  end

  # The `gvar' table (ft_var_load_gvar): per-glyph offsets into the
  # variation data array plus the shared tuples.
  class GVar
    getter gv_glyphcnt : Int32
    getter glyphoffsets : Array(Int32) # [gv_glyphcnt + 1], into `data'
    getter tuplecount : Int32
    getter tuplecoords : Array(Int64)  # [tuplecount * num_axis], 16.16
    getter data : Bytes

    def initialize(@gv_glyphcnt : Int32, @glyphoffsets : Array(Int32),
                   @tuplecount : Int32, @tuplecoords : Array(Int64),
                   @data : Bytes)
    end

    # nil when there is no `gvar' table; ParseError on an inconsistent
    # one (FreeType rejects variation setting for such fonts).
    def self.load(gvar : Bytes?, num_axis : Int32) : GVar?
      return nil if gvar.nil?
      d = gvar
      raise ParseError.new("gvar too small") if d.size < 20

      version = BE.i32(d, 0)
      axis_count = BE.u16(d, 4).to_i32
      global_coord_count = BE.u16(d, 6).to_i32
      offset_to_coord = BE.u32(d, 8).to_i64
      glyph_count = BE.u16(d, 12).to_i32
      flags = BE.u16(d, 14)
      offset_to_data = BE.u32(d, 16).to_i64

      raise ParseError.new("bad gvar version") if version != 0x0001_0000
      raise ParseError.new("gvar axis count mismatch") if axis_count != num_axis
      if global_coord_count.to_i64 * axis_count > d.size // 2
        raise ParseError.new("invalid number of gvar global coordinates")
      end

      long_offsets = (flags & 1) != 0
      offsets_len = (glyph_count + 1) * (long_offsets ? 4 : 2)
      raise ParseError.new("invalid number of gvar glyphs") if offsets_len > d.size

      limit = d.size.to_i64
      glyphoffsets = Array(Int32).new(glyph_count + 1, 0)
      max_offset = 0_i64
      p = 20
      (glyph_count + 1).times do |i|
        off = offset_to_data +
              (long_offsets ? BE.u32(d, p).to_i64 : BE.u16(d, p).to_i64*2)
        p += long_offsets ? 4 : 2

        if max_offset <= off
          max_offset = off
        else
          off = max_offset # not monotonic: clamp
        end
        off = limit if limit < off # out of range: clamp
        glyphoffsets[i] = off.to_i32!
      end

      tuplecoords = Array(Int64).new(global_coord_count * num_axis, 0_i64)
      if global_coord_count != 0
        q = offset_to_coord
        need = global_coord_count.to_i64 * num_axis * 2
        raise ParseError.new("gvar shared tuples missing") if
          q < 0 || q + need > d.size
        (global_coord_count * num_axis).times do |k|
          tuplecoords[k] = BE.i16(d, q + 2*k).to_i64*4
        end
      end

      new(glyph_count, glyphoffsets, global_coord_count, tuplecoords, d)
    end
  end

  # GX_BlendRec's `fvar'/`avar' part.
  class GXBlend
    getter num_axis : Int32
    getter axis : Array(VarAxis)
    getter namedstyle : Array(NamedStyle)
    # normalized_stylecoords[num_namedstyles * num_axis], flat like
    # GX_BlendRec::normalized_stylecoords.
    getter normalized_stylecoords : Array(Int64)
    getter? avar_loaded : Bool
    # nil when there is no (usable) `avar' table — GX_BlendRec keeps a
    # NULL avar_table pointer in that case.
    getter avar_segment : Array(AVarSegment)?
    # `avar' v2: the store/axisMap that further distort the normalized
    # coordinates (nil for v1 tables).
    getter avar_store : ItemVarStore?
    getter avar_map : DeltaSetIndexMap?
    # The `gvar' table (nil for fonts without glyph variations).
    getter gvar : GVar?
    # The advance-adjustment tables; non-nil only when successfully
    # loaded (TT_FACE_FLAG_VAR_HADVANCE/VADVANCE).
    getter hvar : HVVarTable?
    getter vvar : HVVarTable?
    # The `MVAR' table, loaded lazily at the first set_var_design
    # (ft_var_load_mvar), plus the design coordinates the deltas were
    # last applied at (ftmm.c skips metrics_adjust when an identical
    # re-set returns -1 from TT_Set_Var_Design).
    getter mvar : MvarTable?
    @mvar_design_coords : Array(Int64)? = nil
    # The raw `cvar' table (nil when absent).
    getter cvar : Bytes?

    def has_hvar? : Bool
      !@hvar.nil?
    end

    def has_vvar? : Bool
      !@vvar.nil?
    end

    def initialize(@num_axis : Int32, @axis : Array(VarAxis),
                   @namedstyle : Array(NamedStyle),
                   @normalized_stylecoords : Array(Int64),
                   @avar_loaded : Bool,
                   @avar_segment : Array(AVarSegment)?,
                   @avar_store : ItemVarStore?,
                   @avar_map : DeltaSetIndexMap?,
                   @gvar : GVar?,
                   @hvar : HVVarTable?,
                   @vvar : HVVarTable?,
                   @cvar : Bytes?)
    end

    # TT_Get_MM_Var's initialization path: parse `fvar' (and `avar') and
    # build the blend. Returns nil when the font has no valid `fvar'
    # (the sfnt_init_face checks), i.e. a static font — callers proceed
    # without variations exactly like FreeType.
    def self.from_font(font : TT::Font) : GXBlend?
      fvar = font.raw_table("fvar")
      return nil if fvar.nil? || fvar.size < 20

      version = BE.u32(fvar, 0)
      offset = BE.u16(fvar, 4).to_i32
      num_axes = BE.u16(fvar, 8).to_i32
      axis_size = BE.u16(fvar, 10).to_i32
      num_instances = BE.u16(fvar, 12).to_i32
      instance_size = BE.u16(fvar, 14).to_i32

      # sfnt_init_face's validity check: a failure means "no variations",
      # not a font error.
      return nil unless version == 0x0001_0000_u32 &&
                       axis_size == 20 &&
                       num_axes > 0 &&
                       num_axes <= 0x3FFE &&
                       (instance_size == 4 + 4*num_axes ||
                        instance_size == 6 + 4*num_axes) &&
                       num_instances <= 0x7EFF &&
                       offset.to_i64 + 20_i64*num_axes +
                         instance_size.to_i64*num_instances <= fvar.size

      # 20-byte axis records: tag, min/def/max (16.16), flags, nameID.
      axis = Array(VarAxis).new(num_axes) do |i|
        p = offset.to_i32 + 20*i
        VarAxis.new(BE.u32(fvar, p), BE.i32(fvar, p + 4), BE.i32(fvar, p + 8),
                    BE.i32(fvar, p + 12), BE.u16(fvar, p + 16),
                    BE.u16(fvar, p + 18))
      end

      # FreeType loads `avar' before normalizing the named-instance
      # coordinates (only when there are instances; loading it eagerly
      # for instance-less fonts changes nothing observable).
      avar_loaded, avar_segment, avar_store, avar_map =
        load_avar(font.raw_table("avar"), num_axes)

      # Named instances: subfamilyNameID, flags, coordinates, and an
      # optional PS name ID that widens the record by 2 bytes.
      use_ps_name = instance_size == 6 + 4*num_axes
      pos = offset.to_i32 + 20*num_axes
      named = Array(NamedStyle).new(num_instances)
      blend = new(num_axes.to_i32, axis, named,
                  Array(Int64).new(num_axes.to_i32 * num_instances, 0_i64),
                  avar_loaded, avar_segment, avar_store, avar_map,
                  GVar.load(font.raw_table("gvar"), num_axes),
                  HVVarTable.load(font.raw_table("HVAR"), num_axes),
                  HVVarTable.load(font.raw_table("VVAR"), num_axes),
                  font.raw_table("cvar"))
      num_instances.times do |i|
        q = pos + instance_size.to_i32*i
        strid = BE.u16(fvar, q)
        coords = Array(Int64).new(num_axes) { |j| BE.i32(fvar, q + 4 + 4*j) }
        psid = use_ps_name ? BE.u16(fvar, q + 4 + 4*num_axes) : 0xFFFF_u16
        named << NamedStyle.new(strid, psid, coords)
        norm = blend.to_normalized(coords)
        num_axes.times do |j|
          blend.normalized_stylecoords[i*num_axes + j] = norm.unsafe_fetch(j)
        end
      end
      blend
    end

    # ft_var_load_avar: parse the v1 segment pairs and, for v2 tables,
    # the ItemVariationStore/axisMap that renormalize coordinates.
    # Segments are nil on any failure, matching FreeType's
    # discard-the-lot behaviour (v2 subtable errors only drop the v2
    # data here, keeping the segment pairs usable).
    private def self.load_avar(avar : Bytes?, num_axis : Int32)
      no = {true, nil, nil, nil}
      return no if avar.nil? || avar.size < 8
      version = BE.i32(avar, 0)
      axis_count = BE.i32(avar, 4)
      return no if version != 0x0001_0000 && version != 0x0002_0000
      return no if axis_count != num_axis

      segments = Array(AVarSegment).new(axis_count)
      p = 8
      axis_count.times do
        return no if p + 2 > avar.size
        pair_count = BE.u16(avar, p).to_i32
        p += 2
        # The pair data must fit into the table (pairCount*4 check) and
        # into what remains of it.
        return no if pair_count*4 > avar.size || p + 4*pair_count > avar.size
        corr = Array(AVarCorrespondence).new(pair_count) do |j|
          q = p + 4*j
          AVarCorrespondence.new(BE.i16(avar, q).to_i64*4,
                                 BE.i16(avar, q + 2).to_i64*4)
        end
        p += 4*pair_count
        segments << AVarSegment.new(pair_count, corr)
      end

      store = nil
      axis_map = nil
      if version >= 0x0002_0000
        return {true, segments, nil, nil} if p + 8 > avar.size
        axis_map_offset = BE.u32(avar, p).to_i64
        store_offset = BE.u32(avar, p + 4).to_i64

        store = ItemVarStore.load(avar, store_offset, num_axis) rescue nil
        if store && axis_map_offset != 0
          axis_map = DeltaSetIndexMap.load(avar, axis_map_offset,
                                           store, avar.size) rescue nil
        end
      end

      {true, segments, store, axis_map}
    end

    # ft_var_to_normalized: design -> normalized coordinates. Axis
    # normalization maps [min,def,max] to [-1,0,1], then `avar'
    # re-maps the range piecewise-linearly, and a v2 `avar' store adds
    # per-axis deltas on top.
    def to_normalized(coords : Array(Int64)) : Array(Int64)
      normalized = GXBlend.normalize(@axis, @avar_segment, coords)

      if (store = @avar_store) # table->itemStore.varData
        new_normalized = Array(Int64).new(@num_axis, 0_i64)
        i = 0
        while i < @num_axis
          v = normalized.unsafe_fetch(i)
          inner_index = i
          outer_index = 0

          if (map = @avar_map) # table->axisMap.innerIndex
            idx = i >= map.map_count ? map.map_count - 1 : i
            outer_index = map.outer_index[idx].to_i32
            inner_index = map.inner_index[idx].to_i32
          end

          delta = get_item_delta(store, normalized, outer_index, inner_index)

          # delta in F2DOT14 -> 16.16, then clamp to [-1, 1]
          v += delta.to_i64*4
          v = 0x1_0000_i64 if v >= 0x1_0000_i64
          v = -0x1_0000_i64 if v <= -0x1_0000_i64

          new_normalized[i] = v
          i += 1
        end

        i = 0
        while i < @num_axis
          normalized[i] = new_normalized.unsafe_fetch(i)
          i += 1
        end
      end

      normalized
    end

    # ft_var_to_design: normalized -> design coordinates (the inverse
    # of #to_normalized; the avar v2 store plays no part there).
    def to_design(coords : Array(Int64)) : Array(Int64)
      GXBlend.denormalize(@axis, @avar_segment, coords)
    end

    def self.normalize(axis : Array(VarAxis), avar : Array(AVarSegment)?,
                       coords : Array(Int64)) : Array(Int64)
      num_axis = axis.size
      num_coords = {coords.size, num_axis}.min
      normalized = Array(Int64).new(num_axis, 0_i64)

      i = 0
      while i < num_coords
        a = axis.unsafe_fetch(i)
        coord = coords.unsafe_fetch(i)

        if coord > a.default
          normalized[i] = coord >= a.maximum ? 0x1_0000_i64 :
            Fixed.divfix(coord - a.default, a.maximum - a.default)
        elsif coord < a.default
          normalized[i] = coord <= a.minimum ? -0x1_0000_i64 :
            Fixed.divfix(coord - a.default, a.default - a.minimum)
        else
          normalized[i] = 0_i64
        end
        i += 1
      end
      # axes beyond num_coords stay zeroed

      if avar
        i = 0
        while i < num_axis
          av = avar.unsafe_fetch(i)
          corr = av.correspondence
          j = 1
          while j < av.pair_count
            if normalized[i] < corr.unsafe_fetch(j).from_coord
              prev = corr.unsafe_fetch(j - 1)
              cur = corr.unsafe_fetch(j)
              normalized[i] = Fixed.muldiv(
                normalized[i] - prev.from_coord,
                cur.to_coord - prev.to_coord,
                cur.from_coord - prev.from_coord) + prev.to_coord
              break
            end
            j += 1
          end
          i += 1
        end
      end

      normalized
    end

    def self.denormalize(axis : Array(VarAxis), avar : Array(AVarSegment)?,
                         coords : Array(Int64)) : Array(Int64)
      nc = {coords.size, axis.size}.min
      design = Array(Int64).new(coords.size, 0_i64)

      i = 0
      while i < nc
        design[i] = coords.unsafe_fetch(i)
        i += 1
      end

      # inverse `avar' mapping first
      if avar
        i = 0
        while i < nc
          av = avar.unsafe_fetch(i)
          corr = av.correspondence
          j = 1
          while j < av.pair_count
            if design[i] < corr.unsafe_fetch(j).to_coord
              prev = corr.unsafe_fetch(j - 1)
              cur = corr.unsafe_fetch(j)
              design[i] = Fixed.muldiv(
                design[i] - prev.to_coord,
                cur.from_coord - prev.from_coord,
                cur.to_coord - prev.to_coord) + prev.from_coord
              break
            end
            j += 1
          end
          i += 1
        end
      end

      # then [-1,0,1] -> [min,def,max]
      i = 0
      while i < nc
        a = axis.unsafe_fetch(i)
        if design[i] < 0
          design[i] = a.default + Fixed.mulfix(design[i],
                                               a.default - a.minimum)
        elsif design[i] > 0
          design[i] = a.default + Fixed.mulfix(design[i],
                                               a.maximum - a.default)
        else
          design[i] = a.default
        end
        i += 1
      end

      design
    end

    # --- glyph variation deltas (TT_Vary_Apply_Glyph_Deltas) -----------

    # Apply the `gvar' deltas of glyph `gid' for the normalized
    # coordinates `normalized'. `xs'/`ys' hold the outline points in font
    # units WITH the four phantom points appended (n_points = xs.size);
    # `contour_ends' are the outline's contour end indices (for composites
    # FreeType synthesizes one single-point contour per component).
    # Returns per-point deltas: `dx'/`dy' rounded to integer font units
    # (FT_fixedToInt) and `ux'/`uy' in 26.6 (FT_fixedToFdot6) for the
    # unrounded advance computation. Phantom deltas are zeroed when
    # HVAR/VVAR owns the advances.
    def apply_glyph_deltas(gid : Int32, xs : Array(Int64), ys : Array(Int64),
                           contour_ends : Array(Int32),
                           normalized : Array(Int64),
                           has_hvar : Bool = false,
                           has_vvar : Bool = false)
      n_points = xs.size
      pdx = Array(Int64).new(n_points, 0_i64) # 16.16 accumulators
      pdy = Array(Int64).new(n_points, 0_i64)

      if (gvar = @gvar) &&
         gid < gvar.gv_glyphcnt &&
         gvar.glyphoffsets[gid] != gvar.glyphoffsets[gid + 1]
        o0 = gvar.glyphoffsets[gid]
        data = gvar.data[o0, gvar.glyphoffsets[gid + 1] - o0]

        r = Reader.new(data)
        tuple_count = r.u16.to_i32
        offset_to_data = r.u16.to_i32

        if offset_to_data > data.size ||
           (tuple_count & GX_TC_TUPLE_COUNT_MASK)*4 > data.size
          raise ParseError.new("invalid glyph variation array header")
        end

        # shared points, if any: stored at the start of the data area
        shared_points : Array(Int32)? = nil
        if tuple_count & GX_TC_TUPLES_SHARE_POINT_NUMBERS != 0
          rd = Reader.new(data, offset_to_data)
          shared_points = read_packed_points(rd)
          offset_to_data = rd.pos
        end

        (tuple_count & GX_TC_TUPLE_COUNT_MASK).times do
          tuple_data_size = r.u16.to_i32
          tuple_index = r.u16.to_i32

          if tuple_index & GX_TI_EMBEDDED_TUPLE_COORD != 0
            tuple_coords = Array(Int64).new(@num_axis) { r.i16.to_i64*4 }
          elsif (tuple_index & GX_TI_TUPLE_INDEX_MASK) < gvar.tuplecount
            base = (tuple_index & GX_TI_TUPLE_INDEX_MASK)*@num_axis
            tuple_coords = gvar.tuplecoords[base, @num_axis]
          else
            raise ParseError.new("invalid tuple index")
          end

          im_start = im_end = nil
          if tuple_index & GX_TI_INTERMEDIATE_TUPLE != 0
            im_start = Array(Int64).new(@num_axis) { r.i16.to_i64*4 }
            im_end = Array(Int64).new(@num_axis) { r.i16.to_i64*4 }
          end

          apply = apply_tuple(tuple_coords, im_start, im_end,
                              tuple_index, normalized)

          if apply == 0 # tuple isn't active for this blend
            offset_to_data += tuple_data_size
            next
          end

          here = r.pos
          rd = Reader.new(data, offset_to_data)

          points = shared_points
          if tuple_index & GX_TI_PRIVATE_POINT_NUMBERS != 0
            points = read_packed_points(rd)
          end

          pc = points.try(&.size) || -1
          begin
            dx = read_packed_deltas(rd, pc == 0 ? n_points : pc)
            dy = read_packed_deltas(rd, pc == 0 ? n_points : pc)
          rescue ParseError
            dx = dy = nil # failure: ignore this tuple, like FreeType
          end

          if points && dx && dy
            if points.empty? # ALL_POINTS: deltas for every point
              n_points.times do |j|
                pdx[j] += Fixed.mulfix(dx.unsafe_fetch(j), apply)
                pdy[j] += Fixed.mulfix(dy.unsafe_fetch(j), apply)
              end
            else
              # interpolate the missing deltas, similar to `IUP'
              has_delta = Array(Bool).new(n_points, false)
              ox = Array(Int64).new(n_points) { |j| xs.unsafe_fetch(j) << 16 }
              oy = Array(Int64).new(n_points) { |j| ys.unsafe_fetch(j) << 16 }
              out_x = ox.dup
              out_y = oy.dup

              points.each_with_index do |idx, j|
                next if idx >= n_points
                has_delta[idx] = true
                out_x[idx] += Fixed.mulfix(dx.unsafe_fetch(j), apply)
                out_y[idx] += Fixed.mulfix(dy.unsafe_fetch(j), apply)
              end

              interpolate_deltas(contour_ends, ox, oy, out_x, out_y,
                                 has_delta)

              n_points.times do |j|
                pdx[j] += out_x.unsafe_fetch(j) - ox.unsafe_fetch(j)
                pdy[j] += out_y.unsafe_fetch(j) - oy.unsafe_fetch(j)
              end
            end
          end

          offset_to_data += tuple_data_size
          r.pos = here
        end
      end

      # do not move phantom points if HVAR/VVAR owns the advances
      if has_hvar
        (n_points - 4).upto(n_points - 3) { |j| pdx[j] = 0; pdy[j] = 0 }
      end
      if has_vvar
        (n_points - 2).upto(n_points - 1) { |j| pdx[j] = 0; pdy[j] = 0 }
      end

      dx = Array(Int32).new(n_points) { |j| ((pdx[j] + 0x8000) >> 16).to_i16!.to_i32 }
      dy = Array(Int32).new(n_points) { |j| ((pdy[j] + 0x8000) >> 16).to_i16!.to_i32 }
      ux = Array(Int64).new(n_points) { |j| (pdx[j] + 0x200) >> 10 }
      uy = Array(Int64).new(n_points) { |j| (pdy[j] + 0x200) >> 10 }
      {dx: dx, dy: dy, ux: ux, uy: uy}
    end

    # --- CVT variation deltas (tt_face_vary_cvt) ------------------------

    # The `cvar' deltas for the normalized coordinates `normalized',
    # returned per CVT entry in F26Dot6 (FT_fixedToFdot6 of the 16.16
    # accumulation) — the caller adds them to the raw `cvt' (which lives
    # in font units shifted to 26.6, like face->cvt). `cvt_size' is the
    # number of CVT entries; deltas for out-of-range indices are dropped,
    # exactly as in FreeType.
    def vary_cvt(cvt_size : Int32, normalized : Array(Int64)) : Array(Int64)
      acc = Array(Int64).new(cvt_size, 0_i64) # 16.16 accumulators

      if (cvar = @cvar) && cvt_size > 0 && cvar.size >= 8 &&
         BE.u32(cvar, 0) == 0x0001_0000_u32
        tuple_count = BE.u16(cvar, 4).to_i32
        offset_to_data = BE.u16(cvar, 6).to_i32

        if offset_to_data + (tuple_count & GX_TC_TUPLE_COUNT_MASK)*4 <= cvar.size
          shared_points : Array(Int32)? = nil
          if tuple_count & GX_TC_TUPLES_SHARE_POINT_NUMBERS != 0
            rd = Reader.new(cvar, offset_to_data)
            shared_points = read_packed_points(rd)
            offset_to_data = rd.pos
          end

          tuplecount = @gvar.try(&.tuplecount) || 0
          tuplecoords = @gvar.try(&.tuplecoords) || Slice(Int64).empty
          r = Reader.new(cvar, 8)

          (tuple_count & GX_TC_TUPLE_COUNT_MASK).times do
            tuple_data_size = r.u16.to_i32
            tuple_index = r.u16.to_i32

            if tuple_index & GX_TI_EMBEDDED_TUPLE_COORD != 0
              tcoords = Array(Int64).new(@num_axis) { r.i16.to_i64*4 }
            elsif (tuple_index & GX_TI_TUPLE_INDEX_MASK) < tuplecount
              base = (tuple_index & GX_TI_TUPLE_INDEX_MASK)*@num_axis
              tcoords = tuplecoords[base, @num_axis].to_a
            else
              raise ParseError.new("invalid tuple index")
            end

            im_start = im_end = nil
            if tuple_index & GX_TI_INTERMEDIATE_TUPLE != 0
              im_start = Array(Int64).new(@num_axis) { r.i16.to_i64*4 }
              im_end = Array(Int64).new(@num_axis) { r.i16.to_i64*4 }
            end

            apply = apply_tuple(tcoords, im_start, im_end,
                                tuple_index, normalized)

            if apply == 0 # tuple isn't active for this blend
              offset_to_data += tuple_data_size
              next
            end

            here = r.pos
            rd = Reader.new(cvar, offset_to_data)

            points = shared_points
            if tuple_index & GX_TI_PRIVATE_POINT_NUMBERS != 0
              points = read_packed_points(rd)
            end

            pc = points.try(&.size) || -1
            deltas = begin
              read_packed_deltas(rd, pc == 0 ? cvt_size : pc)
            rescue ParseError
              nil # failure: ignore this tuple, like FreeType
            end

            if points && deltas
              if points.empty? # ALL_POINTS: deltas for every CVT entry
                cvt_size.times do |j|
                  acc[j] += Fixed.mulfix(deltas.unsafe_fetch(j), apply)
                end
              else
                points.each_with_index do |pindex, j|
                  next if pindex >= cvt_size
                  acc[pindex] += Fixed.mulfix(deltas.unsafe_fetch(j), apply)
                end
              end
            end

            offset_to_data += tuple_data_size
            r.pos = here
          end
        end
      end

      Array(Int64).new(cvt_size) { |i| (acc.unsafe_fetch(i) + 0x200) >> 10 }
    end

    # ft_var_apply_tuple: the scaling factor of a tuple for the current
    # blend, 0 when the tuple doesn't apply.
    private def apply_tuple(tuple_coords : Array(Int64),
                            im_start : Array(Int64)?,
                            im_end : Array(Int64)?,
                            tuple_index : Int32,
                            normalized : Array(Int64)) : Int64
      apply = 0x1_0000_i64

      i = 0
      while i < @num_axis
        ncv = normalized.unsafe_fetch(i)
        tc = tuple_coords.unsafe_fetch(i)

        if tc == ncv
          i += 1
          next # `apply' does not change
        end

        if tc == 0
          i += 1
          next # tuple coordinate is zero, ignore
        end

        if tuple_index & GX_TI_INTERMEDIATE_TUPLE == 0
          if (tc > ncv && ncv > 0) || (tc < ncv && ncv < 0)
            apply = Fixed.muldiv(apply, ncv, tc)
          else
            apply = 0_i64
            break
          end
        else
          # intermediate tuple
          s = im_start.not_nil!.unsafe_fetch(i)
          e = im_end.not_nil!.unsafe_fetch(i)

          if ncv <= s || ncv >= e
            apply = 0_i64
            break
          end

          if ncv < tc
            apply = Fixed.muldiv(apply, ncv - s, tc - s)
          else
            apply = Fixed.muldiv(apply, e - ncv, e - tc)
          end
        end
        i += 1
      end

      apply
    end

    # tt_interpolate_deltas: interpolate points without delta values,
    # similar to the `IUP' hinting instruction.
    private def interpolate_deltas(contour_ends : Array(Int32),
                                   in_x : Array(Int64), in_y : Array(Int64),
                                   out_x : Array(Int64), out_y : Array(Int64),
                                   has_delta : Array(Bool)) : Nil
      point = 0
      contour_ends.each do |end_point|
        first_point = point

        # search the first point that has a delta
        while point <= end_point && !has_delta[point]
          point += 1
        end

        if point <= end_point
          first_delta = point
          cur_delta = point
          point += 1

          while point <= end_point
            if has_delta[point]
              delta_interpolate(cur_delta + 1, point - 1, cur_delta, point,
                                in_x, in_y, out_x, out_y)
              cur_delta = point
            end
            point += 1
          end

          # shift contour if we only have a single delta
          if cur_delta == first_delta
            delta_shift(first_point, end_point, cur_delta,
                        in_x, in_y, out_x, out_y)
          else
            # otherwise handle the remaining points at the end and the
            # beginning of the contour
            delta_interpolate(cur_delta + 1, end_point, cur_delta,
                              first_delta, in_x, in_y, out_x, out_y)

            if first_delta > 0
              delta_interpolate(first_point, first_delta - 1, cur_delta,
                                first_delta, in_x, in_y, out_x, out_y)
            end
          end
        end
      end
    end

    # tt_delta_shift: shift all points between `p1' and `p2' by the
    # difference of reference point `ref' (af_iup_shift).
    private def delta_shift(p1 : Int32, p2 : Int32, ref : Int32,
                            in_x : Array(Int64), in_y : Array(Int64),
                            out_x : Array(Int64), out_y : Array(Int64)) : Nil
      dx = out_x[ref] - in_x[ref]
      dy = out_y[ref] - in_y[ref]
      return if dx == 0 && dy == 0

      (p1...ref).each do |p|
        out_x[p] += dx
        out_y[p] += dy
      end
      ((ref + 1)..p2).each do |p|
        out_x[p] += dx
        out_y[p] += dy
      end
    end

    # tt_delta_interpolate: interpolate points p1..p2 between reference
    # points ref1/ref2 (af_iup_interp / Ins_IUP). Note that the ref1/ref2
    # swap from the x pass intentionally carries over to the y pass, as
    # in FreeType's pointer-shuffling original.
    private def delta_interpolate(p1 : Int32, p2 : Int32,
                                  ref1 : Int32, ref2 : Int32,
                                  in_x : Array(Int64), in_y : Array(Int64),
                                  out_x : Array(Int64),
                                  out_y : Array(Int64)) : Nil
      return if p1 > p2

      r1 = ref1
      r2 = ref2
      2.times do |i|
        ic = i == 0 ? in_x : in_y
        oc = i == 0 ? out_x : out_y

        r1, r2 = r2, r1 if ic[r1] > ic[r2]

        in1 = ic[r1]
        in2 = ic[r2]
        out1 = oc[r1]
        out2 = oc[r2]
        d1 = out1 - in1
        d2 = out2 - in2

        # reference points with equal coordinate but different delta
        # imply an inferred delta of zero; otherwise interpolate
        if in1 != in2 || out1 == out2
          scale = in1 != in2 ? Fixed.divfix(out2 - out1, in2 - in1) : 0_i64

          (p1..p2).each do |p|
            o = ic[p]

            if o <= in1
              o += d1
            elsif o >= in2
              o += d2
            else
              o = out1 + Fixed.mulfix(o - in1, scale)
            end
            oc[p] = o
          end
        end
      end
    end

    # --- packed point/delta data (ft_var_readpackedpoints/deltas) -------

    # Reads a run-length-encoded point set; an EMPTY result means "all
    # points" (FreeType's ALL_POINTS). ParseError on malformed data.
    private def read_packed_points(r : Reader) : Array(Int32)
      n = r.u8.to_i32
      return Array(Int32).new(0) if n == 0

      if n & 0x80 != 0 # GX_PT_POINTS_ARE_WORDS
        n = ((n & 0x7F) << 8) | r.u8
      end

      points = Array(Int32).new(n, 0)
      first = 0_u16
      i = 0
      while i < n
        runcnt = r.u8
        cnt = (runcnt & 0x7F).to_i32 + 1 # first point not in run count
        cnt = n - i if cnt > n - i

        if runcnt & 0x80 != 0
          cnt.times do
            first &+= r.u16
            points[i] = first.to_i32
            i += 1
          end
        else
          cnt.times do
            first &+= r.u8
            points[i] = first.to_i32
            i += 1
          end
        end
      end
      points
    end

    # Reads run-length-encoded deltas for `delta_cnt' points (16.16,
    # FT_intToFixed of the sign-extended bytes/shorts).
    private def read_packed_deltas(r : Reader, delta_cnt : Int32) : Array(Int64)
      deltas = Array(Int64).new(delta_cnt, 0_i64)
      i = 0
      while i < delta_cnt
        runcnt = r.u8
        cnt = (runcnt & 0x3F).to_i32 + 1 # first delta not in run count
        cnt = delta_cnt - i if cnt > delta_cnt - i

        if runcnt & 0x80 != 0 # GX_DT_DELTAS_ARE_ZERO
          cnt.times { deltas[i] = 0_i64; i += 1 }
        elsif runcnt & 0x40 != 0 # GX_DT_DELTAS_ARE_WORDS
          cnt.times { deltas[i] = r.i16.to_i64 << 16; i += 1 }
        else
          cnt.times { deltas[i] = r.i8.to_i64 << 16; i += 1 }
        end
      end
      deltas
    end

    # Big-endian cursor over a table slice (a tiny stand-in for
    # FreeType's stream frames).
    class Reader
      getter pos : Int32

      def initialize(@d : Bytes, @pos : Int32 = 0)
      end

      def pos=(p : Int32)
        @pos = p
      end

      def u8 : UInt8
        raise ParseError.new("overrun") if @pos >= @d.size
        v = @d[@pos]
        @pos += 1
        v
      end

      def i8 : Int8
        u8.to_i8!
      end

      def u16 : UInt16
        raise ParseError.new("overrun") if @pos + 2 > @d.size
        v = (@d[@pos].to_u16 << 8) | @d[@pos + 1]
        @pos += 2
        v
      end

      def i16 : Int16
        u16.to_i16!
      end
    end

    # tt_var_get_item_delta: the scaled delta for one item of a store,
    # computed for the normalized coordinates `normalized' (FreeType
    # reads the current blend's normalizedcoords).
    def get_item_delta(store : ItemVarStore, normalized : Array(Int64),
                       outer_index : Int32, inner_index : Int32) : Int32
      # no variation data for this item (OpenType 1.8.4+ special value)
      return 0 if outer_index == 0xFFFF && inner_index == 0xFFFF

      return 0 if outer_index >= store.var_data.size # out of range

      var_data = store.var_data[outer_index]
      return 0 if inner_index >= var_data.item_count # out of range

      region_idx_count = var_data.region_indices.size
      return 0 if region_idx_count == 0

      # decode the delta set: (word_delta_count + region_idx_count)
      # entries per region, words first (Int32/Int16), then the rest
      # (Int16/Int8 depending on `long_words')
      bytes = var_data.delta_set
      per_region = var_data.per_region_size
      p = per_region * inner_index

      delta_set = Array(Int32).new(region_idx_count, 0)
      m = 0
      if var_data.long_words
        while m < var_data.word_delta_count
          delta_set[m] = ((bytes[p].to_i32 << 24) | (bytes[p + 1].to_i32 << 16) |
                          (bytes[p + 2].to_i32 << 8) | bytes[p + 3].to_i32)
          p += 4
          m += 1
        end
        while m < region_idx_count
          delta_set[m] = (((bytes[p].to_i16 << 8) | bytes[p + 1]).to_i16).to_i32
          p += 2
          m += 1
        end
      else
        while m < var_data.word_delta_count
          delta_set[m] = (((bytes[p].to_i16 << 8) | bytes[p + 1]).to_i16).to_i32
          p += 2
          m += 1
        end
        while m < region_idx_count
          delta_set[m] = bytes[p].to_i8!.to_i32
          p += 1
          m += 1
        end
      end

      # per-region scalars from the normalized coordinates
      scalars = Array(Int64).new(region_idx_count, 0_i64)
      region_idx_count.times do |master|
        scalar = 0x1_0000_i64
        region = store.regions[var_data.region_indices[master]]

        store.axis_count.times do |j|
          ncv = normalized.unsafe_fetch(j)
          axis = region.unsafe_fetch(j)

          if axis.peak_coord == ncv || axis.peak_coord == 0
            next
          elsif ncv <= axis.start_coord || ncv >= axis.end_coord
            scalar = 0_i64
            break
          elsif ncv < axis.peak_coord
            scalar = Fixed.muldiv(scalar,
                                  ncv - axis.start_coord,
                                  axis.peak_coord - axis.start_coord)
          else # ncv > peak_coord
            scalar = Fixed.muldiv(scalar,
                                  axis.end_coord - ncv,
                                  axis.end_coord - axis.peak_coord)
          end
        end

        scalars[master] = scalar
      end

      # FT_MulAddFix: 64-bit accumulation, round-to-nearest at >> 16
      temp = 0_i64
      region_idx_count.times do |m|
        temp += scalars[m] &* delta_set[m].to_i64
      end
      ((temp &+ 0x8000) >> 16).to_i32!
    end

    # tt_hvadvance_adjust: the HVAR (or VVAR) advance adjustment of a
    # glyph, to be added to the unadjusted advance.
    def advance_delta(gid : Int32, normalized : Array(Int64),
                      vertical : Bool = false) : Int32
      table = vertical ? @vvar : @hvar
      return 0 unless table

      if (map = table.width_map)
        idx = gid >= map.map_count ? map.map_count - 1 : gid
        outer_index = map.outer_index[idx].to_i32
        inner_index = map.inner_index[idx].to_i32
      else
        outer_index = 0
        inner_index = gid
      end

      get_item_delta(table.item_store, normalized, outer_index, inner_index)
    end

    # --- raw big-endian readers ------------------------------------------

    # ft_var_load_mvar: parse the `MVAR' table and snapshot the
    # unmodified metric values. A missing or invalid table disables the
    # adjustments (invalid records drop the whole table, as in FreeType).
    def load_mvar(font : TT::Font) : Nil
      return if @mvar
      d = font.raw_table("MVAR")
      return if d.nil? || d.size < 12
      return if BE.u16(d, 0) != 1 # majorVersion

      value_count = BE.u16(d, 8).to_i32
      store_off = BE.u16(d, 10).to_i64
      begin
        store = ItemVarStore.load(d, store_off, @num_axis)
      rescue ParseError
        return
      end

      values = [] of MvarValue
      pos = 12
      value_count.times do
        break if pos + 8 > d.size
        tag = BE.u32(d, pos)
        outer = BE.u16(d, pos + 4).to_i32
        inner = BE.u16(d, pos + 6).to_i32
        pos += 8
        # OpenType 1.8.4+: no variation data for this item.
        next if outer == 0xFFFF && inner == 0xFFFF
        if outer >= store.var_data.size ||
           inner >= store.var_data[outer].item_count
          return # Invalid_Table: the whole table is dropped
        end
        values << MvarValue.new(tag, outer, inner)
      end

      values.each do |v|
        v.unmodified = mvar_read(font, v.tag) || 0
      end
      @mvar = MvarTable.new(store, values)
    end

    # tt_apply_mvar: re-apply the `MVAR' deltas for the current normalized
    # coordinates. The faces call this from set_var_design — FreeType runs
    # the driver's metrics_adjust through ftmm.c whenever the design
    # coordinates actually change, which this mirrors so the derived
    # ascender/descender/height never get the same delta applied twice.
    def apply_mvar(font : TT::Font, design_coords : Array(Int64),
                   normalized : Array(Int64)) : Nil
      mvar = @mvar
      return unless mvar
      if (last = @mvar_design_coords) && last == design_coords
        return # identical re-set: TT_Set_Var_Design's -1, no adjust
      end
      @mvar_design_coords = design_coords.dup

      hasc = 0
      hdsc = 0
      hlgp = 0
      mvar.values.each do |v|
        next if mvar_read(font, v.tag).nil? # unknown/unmodelled tag
        delta = get_item_delta(mvar.item_store, normalized,
                               v.outer_index, v.inner_index)
        next if delta == 0 # FT: `if ( p && delta )'

        # since both signed and unsigned fields are handled as FT_Short,
        # the sum wraps at 16 bits like FreeType's assignment
        patched = (v.unmodified.to_i16! + delta.to_i16!).to_i16!.to_i32
        mvar_write(font, v.tag, patched)

        case v.tag
        when 0x68617363_u32 then hasc = delta # 'hasc'
        when 0x68647363_u32 then hdsc = delta # 'hdsc'
        when 0x686C6770_u32 then hlgp = delta # 'hlgp'
        end
      end

      # Derived values (tt_apply_mvar tail): the typo deltas move the
      # FT_Face line metrics no matter how they were originally computed,
      # and the underline is recomputed from the possibly UNDO/UNDS-
      # patched `post' values. FT_Short arithmetic throughout.
      line_gap = (font.height.to_i16! - font.ascender.to_i16! +
                  font.descender.to_i16!).to_i16!.to_i32
      font.ascender = (font.ascender.to_i16! + hasc.to_i16!).to_i16!.to_i32
      font.descender = (font.descender.to_i16! + hdsc.to_i16!).to_i16!.to_i32
      font.height = (font.ascender.to_i16! - font.descender.to_i16! +
                     line_gap.to_i16! + hlgp.to_i16!).to_i16!.to_i32
      font.underline_position = (font.post_underline_position -
                                 font.post_underline_thickness.tdiv(2))
                                .to_i16!.to_i32
      font.underline_thickness = font.post_underline_thickness.to_i16!.to_i32
    end

    # ft_var_get_value_pointer over the fields this port models; nil =
    # tag unknown or not modelled here (vertical, caret, gasp,
    # sub/superscript...), which FreeType-equivalently ignores.
    private def mvar_read(font : TT::Font, tag : UInt32) : Int32?
      case tag
      when 0x68617363_u32 then font.typo_ascender          # 'hasc'
      when 0x68647363_u32 then font.typo_descender         # 'hdsc'
      when 0x686C6770_u32 then font.typo_line_gap          # 'hlgp'
      when 0x68636C61_u32 then font.us_win_ascent.to_i16!.to_i32  # 'hcla'
      when 0x68636C64_u32 then font.us_win_descent.to_i16!.to_i32 # 'hcld'
      when 0x78686774_u32 then font.sx_height              # 'xhgt'
      when 0x7374726F_u32 then font.y_strikeout_position   # 'stro'
      when 0x73747273_u32 then font.y_strikeout_size       # 'strs'
      when 0x756E646F_u32 then font.post_underline_position # 'undo'
      when 0x756E6473_u32 then font.post_underline_thickness # 'unds'
      end
    end

    private def mvar_write(font : TT::Font, tag : UInt32, value : Int32) : Nil
      case tag
      when 0x68617363_u32 then font.typo_ascender = value
      when 0x68647363_u32 then font.typo_descender = value
      when 0x686C6770_u32 then font.typo_line_gap = value
      when 0x68636C61_u32 then font.us_win_ascent = value
      when 0x68636C64_u32 then font.us_win_descent = value
      when 0x78686774_u32 then font.sx_height = value
      when 0x7374726F_u32 then font.y_strikeout_position = value
      when 0x73747273_u32 then font.y_strikeout_size = value
      when 0x756E646F_u32 then font.post_underline_position = value
      when 0x756E6473_u32 then font.post_underline_thickness = value
      end
    end

  end
end

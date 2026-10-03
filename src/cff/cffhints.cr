# Port of the Adobe hinting machinery from FreeType's psaux, as used by
# the hinted Adobe engine (the darkening-free configuration of this
# port — FT 2.7+ defaults to no-stem-darkening=TRUE):
#
#   - `pshints.c': CF2_Hint flags/stem-hint expansion (cf2_hint_init),
#     the hint map (cf2_hintmap_build / _insertHint / _adjustHints /
#     _map with its two-pass optimum positioning);
#   - `psblues.c': blue zones (cf2_blues_init, cf2_blues_capture) with
#     family matching, overshoot suppression and the BlueScale cutoff;
#   - `psintrp.c': the HintMask object (read/setAll/isValid/isNew).
#
# 32-bit wrapping arithmetic is carried over from ADD_INT32/SUB_INT32;
# FT_MulFix/FT_DivFix run on the wider fixed helpers of cffload.cr,
# matching LP64 `long' FreeType.

require "./cffload"

module CFF
  GHOST_BOTTOM = 0x1_u16
  GHOST_TOP    = 0x2_u16
  PAIR_BOTTOM  = 0x4_u16
  PAIR_TOP     = 0x8_u16
  LOCKED       = 0x10_u16
  SYNTHETIC    = 0x20_u16

  MAX_HINTS       = 96
  MAX_HINT_EDGES  = MAX_HINTS * 2
  MAX_BLUES       = 7
  MAX_OTHER_BLUES = 5

  FIXED_EPSILON = 1_i64
  MIN_COUNTER   = 0x8000_i64 # cf2_doubleToFixed( 0.5 )
  ICF_TOP       = 880_i64 << 16
  ICF_BOTTOM    = -120_i64 << 16

  # cf2_fixedRound / _Floor / _Fraction (psfixed.h, UInt32 arithmetic).
  def self.fixed_round(x : Int64) : Int64
    ((x.to_u32! &+ 0x8000_u32) & 0xFFFF_0000_u32).to_i32!.to_i64
  end

  def self.fixed_floor(x : Int64) : Int64
    (x.to_u32! & 0xFFFF_0000_u32).to_i32!.to_i64
  end

  def self.fixed_fraction(x : Int64) : Int64
    x &- CFF.fixed_floor(x)
  end

  def self.fixed_abs(x : Int64) : Int64
    x < 0 ? CFF.sub32(0, x) : x
  end

  # CF2_HintRec (psblues.h): one hint map edge. A class: the engine
  # mutates edges in place (capture locks, insert recomputes ds).
  class Hint
    property flags : UInt16 = 0_u16
    property index : Int32 = 0
    property cs_coord : Int64 = 0_i64
    property ds_coord : Int64 = 0_i64
    property scale : Int64 = 0_i64

    def valid? : Bool
      @flags != 0
    end

    def pair? : Bool
      (@flags & (PAIR_BOTTOM | PAIR_TOP)) != 0
    end

    def pair_top? : Bool
      (@flags & PAIR_TOP) != 0
    end

    def top? : Bool
      (@flags & (PAIR_TOP | GHOST_TOP)) != 0
    end

    def bottom? : Bool
      (@flags & (PAIR_BOTTOM | GHOST_BOTTOM)) != 0
    end

    def locked? : Bool
      (@flags & LOCKED) != 0
    end

    def synthetic? : Bool
      (@flags & SYNTHETIC) != 0
    end

    def lock! : Nil
      @flags |= LOCKED
    end
  end

  # CF2_StemHintRec (pshints.h): one hstem/vstem operand pair.
  class StemHint
    property used = false
    property min : Int64
    property max : Int64
    property min_ds : Int64 = 0_i64
    property max_ds : Int64 = 0_i64

    def initialize(@min, @max)
    end
  end

  # CF2_HintMaskRec (psintrp.c helpers): the active-hint bit mask.
  class HintMask
    property valid = false
    property is_new = false
    property bit_count = 0
    getter mask = Array(UInt8).new((MAX_HINTS + 7) // 8, 0_u8)

    def set_counts(bit_count : Int32) : Bool
      return false if bit_count > MAX_HINTS
      @bit_count = bit_count
      @valid = true
      @is_new = true
      true
    end

    # cf2_hintmask_read: consume the mask bytes following the operator.
    def read(buf, bit_count : Int32) : Nil
      return unless set_counts(bit_count)
      byte_count = (@bit_count + 7) // 8
      byte_count.times { |i| @mask[i] = buf.read_byte }
    end

    # cf2_hintmask_setAll.
    def set_all(bit_count : Int32) : Bool
      return false unless set_counts(bit_count)
      byte_count = (@bit_count + 7) // 8
      @mask.fill(0xFF_u8, 0, byte_count)
      @mask[byte_count - 1] &= (0xFF_u8 << (8 - @bit_count % 8)) & 0xFF if @bit_count % 8 != 0
      true
    end

    # A structural copy (the C copies the struct wholesale).
    def copy_from(other : HintMask) : Nil
      @valid = other.valid
      @is_new = other.is_new
      @bit_count = other.bit_count
      other.mask.each_with_index { |b, i| @mask[i] = b }
    end
  end

  # cf2_hint_init (pshints.c): expand a StemHint into one Hint edge;
  # `bottom' selects the bottom edge of the pair. Darkening adjustment
  # (tops += 2*darkenY) is absent: darkenY is always 0 here. Hint is a
  # struct, so the edge is built and returned (not mutated in place).
  def self.hint_init(stems : Array(StemHint), index : Int32,
                     hint_origin : Int64, scale : Int64,
                     bottom : Bool) : Hint
    hint = Hint.new
    stem = stems[index]
    width = CFF.sub32(stem.max, stem.min)


    if width == (-21_i64 << 16) # ghost bottom
      if bottom
        hint.cs_coord = stem.max
        hint.flags = GHOST_BOTTOM
      end
    elsif width == (-20_i64 << 16) # ghost top
      unless bottom
        hint.cs_coord = stem.min
        hint.flags = GHOST_TOP
      end
    elsif width < 0 # inverted pair
      if bottom
        hint.cs_coord = stem.max
        hint.flags = PAIR_BOTTOM
      else
        hint.cs_coord = stem.min
        hint.flags = PAIR_TOP
      end
    else # normal pair
      if bottom
        hint.cs_coord = stem.min
        hint.flags = PAIR_BOTTOM
      else
        hint.cs_coord = stem.max
        hint.flags = PAIR_TOP
      end
    end

    hint.cs_coord = CFF.add32(hint.cs_coord, hint_origin)
    hint.scale = scale
    hint.index = index

    if hint.flags != 0 && stem.used
      hint.ds_coord = hint.top? ? stem.max_ds : stem.min_ds
      hint.lock!
    else
      hint.ds_coord = Fixed.mulfix(hint.cs_coord, scale)
    end

    hint
  end

  # CF2_BlueRec + cf2_blues_init/cf2_blues_capture (psblues.c).
  class Blues
    # A class: cf2_blues_init mutates zone edges after construction
    # (family matching, ds_flat rounding).
    class Zone
      property cs_bottom : Int64
      property cs_top : Int64
      property cs_flat : Int64
      property ds_flat : Int64 = 0_i64
      property bottom_zone : Bool

      def initialize(@cs_bottom, @cs_top, @cs_flat, @bottom_zone)
      end
    end

    getter zones = Array(Zone).new(MAX_BLUES + MAX_OTHER_BLUES) { |i| Zone.new(0_i64, 0_i64, 0_i64, true) }
    property count = 0
    property scale : Int64
    property blue_scale : Int64
    property blue_shift : Int64
    property blue_fuzz : Int64
    property boost : Int64 = 0_i64
    property? suppress_overshoot = false
    property? do_em_box_hints = false
    getter em_box_bottom_edge = Hint.new
    getter em_box_top_edge = Hint.new

    def initialize(subfont : SubFont, scale : Int64)
      @scale = scale
      # cf2_getBlueMetrics: BlueScale is stored 1000x.
      @blue_scale = Fixed.divfix(subfont.blue_scale, 1000_i64 << 16)
      @blue_shift = subfont.blue_shift << 16
      @blue_fuzz = subfont.blue_fuzz << 16

      blue_values = subfont.blue_values
      other_blues = subfont.other_blues
      family_blues = subfont.family_blues
      family_other = subfont.family_other_blues

      # Synthetic em box hint heuristic (LanguageGroup 1 without real
      # alignment zones): ideographic fonts get ghost hints at the em
      # box instead of their (dummy) zones.
      if subfont.language_group == 1 &&
         (blue_values.empty? ||
           (blue_values.size == 4 &&
            blue_values[0] < ICF_BOTTOM && blue_values[1] < ICF_BOTTOM &&
            blue_values[2] > ICF_TOP && blue_values[3] > ICF_TOP))
        e = @em_box_bottom_edge
        e.cs_coord = CFF.sub32(ICF_BOTTOM, FIXED_EPSILON)
        e.ds_coord = CFF.sub32(CFF.fixed_round(Fixed.mulfix(e.cs_coord, scale)), MIN_COUNTER)
        e.scale = scale
        e.flags = GHOST_BOTTOM | LOCKED | SYNTHETIC

        t = @em_box_top_edge
        t.cs_coord = CFF.add32(ICF_TOP, FIXED_EPSILON)
        t.ds_coord = CFF.add32(CFF.fixed_round(Fixed.mulfix(t.cs_coord, scale)), MIN_COUNTER)
        t.scale = scale
        t.flags = GHOST_TOP | LOCKED | SYNTHETIC

        @do_em_box_hints = true
        return
      end

      max_zone_height = 0_i64

      # BlueValues: the first pair is a bottom zone, the rest are top.
      i = 0
      while i + 1 < blue_values.size
        cs_bottom = blue_values[i]
        cs_top = blue_values[i + 1]
        zone_height = CFF.sub32(cs_top, cs_bottom)
        i += 2
        next if zone_height < 0 # reject negative zone height
        max_zone_height = zone_height if zone_height > max_zone_height

        bottom_zone = i == 2 # first pair
        cs_flat = bottom_zone ? cs_top : cs_bottom
        @zones[@count] = Zone.new(cs_bottom, cs_top, cs_flat, bottom_zone)
        @count += 1
      end

      # OtherBlues: all bottom zones.
      i = 0
      while i + 1 < other_blues.size
        cs_bottom = other_blues[i]
        cs_top = other_blues[i + 1]
        zone_height = CFF.sub32(cs_top, cs_bottom)
        i += 2
        next if zone_height < 0
        max_zone_height = zone_height if zone_height > max_zone_height

        @zones[@count] = Zone.new(cs_bottom, cs_top, cs_top, true)
        @count += 1
      end

      # Family matching: snap each zone's flat edge to the nearest
      # family edge within one device pixel.
      cs_units_per_pixel = Fixed.divfix(1_i64 << 16, scale)
      @count.times do |k|
        zone = @zones[k]
        flat_edge = zone.cs_flat

        if zone.bottom_zone
          min_diff = Int64::MAX
          j = 0
          while j + 1 < family_other.size
            flat_family = family_other[j + 1]
            diff = CFF.fixed_abs(CFF.sub32(flat_edge, flat_family))
            if diff < min_diff && diff < cs_units_per_pixel
              zone.cs_flat = flat_family
              min_diff = diff
              break if diff == 0
            end
            j += 2
          end
          if family_blues.size >= 2
            flat_family = family_blues[1]
            diff = CFF.fixed_abs(CFF.sub32(flat_edge, flat_family))
            zone.cs_flat = flat_family if diff < min_diff && diff < cs_units_per_pixel
          end
        else
          min_diff = Int64::MAX
          j = 2
          while j < family_blues.size
            flat_family = family_blues[j]
            diff = CFF.fixed_abs(CFF.sub32(flat_edge, flat_family))
            if diff < min_diff && diff < cs_units_per_pixel
              zone.cs_flat = flat_family
              min_diff = diff
              break if diff == 0
            end
            j += 2
          end
        end
      end

      # Clamp BlueScale at the overshoot suppression point.
      if max_zone_height > 0
        limit = Fixed.divfix(1_i64 << 16, max_zone_height)
        @blue_scale = limit if @blue_scale > limit
      end

      # Suppress overshoot / boost at small sizes.
      if @scale < @blue_scale
        @suppress_overshoot = true
        @boost = (0.6*65536.0 + 0.5).to_i64 &-
                  Fixed.muldiv((0.6*65536.0 + 0.5).to_i64, @scale, @blue_scale)
        @boost = 0x7FFF_i64 if @boost > 0x7FFF
      end
      # (stem darkening would zero the boost; never darkened here)

      @count.times do |k|
        zone = @zones[k]
        base = Fixed.mulfix(zone.cs_flat, @scale)
        zone.ds_flat = zone.bottom_zone ? CFF.fixed_round(CFF.sub32(base, @boost))
                                        : CFF.fixed_round(CFF.add32(base, @boost))
      end
    end

    # cf2_blues_capture: try capturing a stem hint pair by a zone.
    def capture(bottom_hint : Hint, top_hint : Hint) : Bool
      cs_fuzz = @blue_fuzz
      ds_move = 0_i64
      captured = false

      @count.times do |i|
        zone = @zones[i]

        if zone.bottom_zone && bottom_hint.bottom?
          if CFF.sub32(zone.cs_bottom, cs_fuzz) <= bottom_hint.cs_coord &&
             bottom_hint.cs_coord <= CFF.add32(zone.cs_top, cs_fuzz)
            if @suppress_overshoot
              ds_new = zone.ds_flat
            elsif CFF.sub32(zone.cs_top, bottom_hint.cs_coord) >= @blue_shift
              ds_new = {CFF.fixed_round(bottom_hint.ds_coord),
                        CFF.sub32(zone.ds_flat, 1_i64 << 16)}.min
            else
              ds_new = CFF.fixed_round(bottom_hint.ds_coord)
            end
            ds_move = CFF.sub32(ds_new, bottom_hint.ds_coord)
            captured = true
            break
          end
        end

        if !zone.bottom_zone && top_hint.top?
          if CFF.sub32(zone.cs_bottom, cs_fuzz) <= top_hint.cs_coord &&
             top_hint.cs_coord <= CFF.add32(zone.cs_top, cs_fuzz)
            if @suppress_overshoot
              ds_new = zone.ds_flat
            elsif CFF.sub32(top_hint.cs_coord, zone.cs_bottom) >= @blue_shift
              ds_new = {CFF.fixed_round(top_hint.ds_coord),
                        CFF.add32(zone.ds_flat, 1_i64 << 16)}.max
            else
              ds_new = CFF.fixed_round(top_hint.ds_coord)
            end
            ds_move = CFF.sub32(ds_new, top_hint.ds_coord)
            captured = true
            break
          end
        end
      end

      if captured
        if bottom_hint.valid?
          bottom_hint.ds_coord = CFF.add32(bottom_hint.ds_coord, ds_move)
          bottom_hint.lock!
        end
        if top_hint.valid?
          top_hint.ds_coord = CFF.add32(top_hint.ds_coord, ds_move)
          top_hint.lock!
        end
      end

      captured
    end
  end

  # CF2_HintMapRec (pshints.h): a piecewise-linear CS->DS edge map.
  class HintMap
    property valid = false
    property hinted = true
    property scale : Int64
    property count = 0
    property last_index = 0
    getter edges = Array(Hint).new(MAX_HINT_EDGES) { Hint.new }
    property initial_map : HintMap?
    getter hint_moves = Array({Int32, Int64}).new # {j, moveUp}

    def initialize(@scale : Int64, @initial_map : HintMap? = nil)
    end

    def copy_from(other : HintMap) : Nil
      @valid = other.valid
      @hinted = other.hinted
      @scale = other.scale
      @count = other.count
      @last_index = other.last_index
      @initial_map = other.initial_map
      other.edges.each_with_index { |e, i| @edges[i] = e.dup }
    end

    # cf2_hintmap_map: piecewise-linear transform through the edges.
    def map(cs_coord : Int64) : Int64
      return Fixed.mulfix(cs_coord, @scale) if @count == 0 || !@hinted

      i = @last_index
      # search up
      while i < @count - 1 && cs_coord >= @edges[i + 1].cs_coord
        i += 1
      end
      # search down
      while i > 0 && cs_coord < @edges[i].cs_coord
        i -= 1
      end
      @last_index = i

      if i == 0 && cs_coord < @edges[0].cs_coord
        CFF.add32(Fixed.mulfix(CFF.sub32(cs_coord, @edges[0].cs_coord), @scale),
              @edges[0].ds_coord)
      else
        CFF.add32(Fixed.mulfix(CFF.sub32(cs_coord, @edges[i].cs_coord), @edges[i].scale),
              @edges[i].ds_coord)
      end
    end

    # cf2_hintmap_insertHint.
    private def insert_hint(bottom_hint : Hint, top_hint : Hint) : Nil
      is_pair = true
      first_hint = bottom_hint
      second_hint = top_hint

      if !bottom_hint.valid?
        first_hint = top_hint
        is_pair = false
      elsif !top_hint.valid?
        is_pair = false
      end


      return if is_pair && top_hint.cs_coord < bottom_hint.cs_coord

      index_insert = 0
      while index_insert < @count
        break if @edges[index_insert].cs_coord >= first_hint.cs_coord
        index_insert += 1
      end

      # Discard hints overlapping in character space.
      if index_insert < @count
        return if @edges[index_insert].cs_coord == first_hint.cs_coord
        if is_pair && @edges[index_insert].cs_coord <= second_hint.cs_coord
          return
        end
        return if @edges[index_insert].pair_top?
      end

      # Recompute device positions through the initial hint map.
      if (im = @initial_map) && im.valid && !first_hint.locked?
        if is_pair
          # C's `/ 2' truncates toward zero — tdiv, not floor.
          span = CFF.sub32(second_hint.cs_coord, first_hint.cs_coord).tdiv(2)
          midpoint = im.map(CFF.add32(first_hint.cs_coord, span))
          half_width = Fixed.mulfix(span, @scale)
          first_hint.ds_coord = CFF.sub32(midpoint, half_width)
          second_hint.ds_coord = CFF.add32(midpoint, half_width)
        else
          first_hint.ds_coord = im.map(first_hint.cs_coord)
        end
      end

      # Discard hints overlapping in device space.
      if index_insert > 0
        return if first_hint.ds_coord < @edges[index_insert - 1].ds_coord
      end
      if index_insert < @count
        if is_pair
          return if second_hint.ds_coord > @edges[index_insert].ds_coord
        else
          return if first_hint.ds_coord > @edges[index_insert].ds_coord
        end
      end

      # Make room and insert.
      i_dst = is_pair ? @count + 1 : @count
      return if i_dst >= MAX_HINT_EDGES

      i_src = @count - 1
      move_count = @count - index_insert
      while move_count > 0
        @edges[i_dst] = @edges[i_src]
        i_dst -= 1
        i_src -= 1
        move_count -= 1
      end

      @edges[index_insert] = first_hint.dup
      @count += 1
      if is_pair
        @edges[index_insert + 1] = second_hint.dup
        @count += 1
      end
    end

    # cf2_hintmap_adjustHints: move unlocked pairs to pixel boundaries.
    private def adjust_hints : Nil
      @hint_moves.clear

      i = 0
      while i < @count
        is_pair = @edges[i].pair?
        move = 0_i64

        j = is_pair ? i + 1 : i

        ds_i = @edges[i].ds_coord
        ds_j = @edges[j].ds_coord

        unless @edges[i].locked?
          frac_down = CFF.fixed_fraction(ds_i)
          frac_up = CFF.fixed_fraction(ds_j)

          down_move_down = 0_i64 &- frac_down
          up_move_down = 0_i64 &- frac_up
          down_move_up = frac_down == 0 ? 0_i64 : (1_i64 << 16) &- frac_down
          up_move_up = frac_up == 0 ? 0_i64 : (1_i64 << 16) &- frac_up

          move_up = {down_move_up, up_move_up}.min
          move_down = {down_move_down, up_move_down}.max

          down_min_counter = MIN_COUNTER
          up_min_counter = MIN_COUNTER
          save_edge = false

          if j >= @count - 1 ||
             @edges[j + 1].ds_coord >= CFF.add32(ds_j, CFF.add32(move_up, up_min_counter))
            if i == 0 ||
               @edges[i - 1].ds_coord <= CFF.add32(ds_i, CFF.sub32(move_down, down_min_counter))
              move = CFF.sub32(0, move_down) < move_up ? move_down : move_up
            else
              move = move_up
            end
          else
            if i == 0 ||
               @edges[i - 1].ds_coord <= CFF.add32(ds_i, CFF.sub32(move_down, down_min_counter))
              move = move_down
              save_edge = move_up < CFF.sub32(0, move_down)
            else
              move = 0_i64
              save_edge = true
            end
          end

          if save_edge && j < @count - 1 && !@edges[j + 1].locked?
            @hint_moves << {j, CFF.sub32(move_up, move)}
          end

          @edges[i].ds_coord = CFF.add32(ds_i, move)
          @edges[j].ds_coord = CFF.add32(ds_j, move) if is_pair
        end

        # Adjust the scales, avoiding divide by zero.
        if i > 0 && @edges[i].cs_coord != @edges[i - 1].cs_coord
          @edges[i - 1].scale = Fixed.divfix(
            CFF.sub32(@edges[i].ds_coord, @edges[i - 1].ds_coord),
            CFF.sub32(@edges[i].cs_coord, @edges[i - 1].cs_coord))
        end
        if is_pair
          if @edges[j].cs_coord != @edges[j - 1].cs_coord
            @edges[j - 1].scale = Fixed.divfix(
              CFF.sub32(@edges[j].ds_coord, @edges[j - 1].ds_coord),
              CFF.sub32(@edges[j].cs_coord, @edges[j - 1].cs_coord))
          end
          i += 1 # skip the upper edge
        end
        i += 1
      end

      # Second pass: retry the saved non-optimal moves, top-down.
      k = @hint_moves.size
      while k > 0
        k -= 1
        j, move_up = @hint_moves[k]

        if @edges[j + 1].ds_coord >=
           CFF.add32(@edges[j].ds_coord, CFF.add32(move_up, MIN_COUNTER))
          @edges[j].ds_coord = CFF.add32(@edges[j].ds_coord, move_up)
          if @edges[j].pair?
            @edges[j - 1].ds_coord = CFF.add32(@edges[j - 1].ds_coord, move_up)
          end
        end
      end
    end

    # cf2_hintmap_build.
    def build(h_stems : Array(StemHint), v_stems : Array(StemHint),
              mask : HintMask, hint_origin : Int64, initial : Bool,
              blues : Blues) : Nil
      # Build the initial map first if it is not valid yet.
      if !initial && (im = @initial_map) && !im.valid
        temp_mask = HintMask.new
        im.build(h_stems, v_stems, temp_mask, hint_origin, true, blues)
      end


      unless mask.valid
        # Without a hint mask, assume all hints are active.
        return unless mask.set_all(h_stems.size + v_stems.size)
      end

      @count = 0
      @last_index = 0

      # Work on a copy of the mask so bits can be turned off.
      temp_mask = HintMask.new
      temp_mask.copy_from(mask)
      bit_count = h_stems.size

      # Synthetic em box hints get the highest priority.
      if blues.do_em_box_hints?
        dummy = Hint.new
        insert_hint(blues.em_box_bottom_edge, dummy)
        insert_hint(dummy, blues.em_box_top_edge)
      end

      # Insert hints captured by a blue zone or already locked.
      i = 0
      while i < bit_count
        if temp_mask.mask[i // 8] & (0x80_u8 >> (i % 8)) != 0
          bottom = CFF.hint_init(h_stems, i, hint_origin, @scale, true)
          top = CFF.hint_init(h_stems, i, hint_origin, @scale, false)

          if bottom.locked? || top.locked? ||
             blues.capture(bottom, top)
            insert_hint(bottom, top)
            temp_mask.mask[i // 8] &= ~(0x80_u8 >> (i % 8))
          end
        end
        i += 1
      end

      if initial
        # Lock the baseline for glyphs without baseline hints: insert a
        # synthetic locked edge at 0 unless one is already there.
        if @count == 0 || @edges[0].cs_coord > 0 ||
           @edges[@count - 1].cs_coord < 0
          edge = Hint.new
          edge.flags = GHOST_BOTTOM | LOCKED | SYNTHETIC
          edge.scale = @scale
          invalid = Hint.new
          insert_hint(edge, invalid)
        end
      else
        # Insert the remaining hints.
        i = 0
        while i < bit_count
          if temp_mask.mask[i // 8] & (0x80_u8 >> (i % 8)) != 0
            bottom = CFF.hint_init(h_stems, i, hint_origin, @scale, true)
            top = CFF.hint_init(h_stems, i, hint_origin, @scale, false)
            insert_hint(bottom, top)
          end
          i += 1
        end
      end

      adjust_hints

      # Save the positions of all used hints (stable across zones).
      unless initial
        i = 0
        while i < @count
          unless @edges[i].synthetic?
            stem = h_stems[@edges[i].index]
            if @edges[i].top?
              stem.max_ds = @edges[i].ds_coord
            else
              stem.min_ds = @edges[i].ds_coord
            end
            stem.used = true
          end
          i += 1
        end
      end

      @valid = true
      mask.is_new = false
    end
  end
end

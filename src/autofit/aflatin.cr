# aflatin.cr — a port of FreeType's `src/autofit/aflatin.c' (2.13.3):
# the latin writing system — global metrics (standard stem widths, blue
# zones, digit advance check), scaling with x-height alignment, and the
# per-glyph analysis (segments, edges, blue edges) plus grid fitting
# (stem/serif hinting). The dummy writing system (`none_dflt' fallback)
# is folded in as LatinMetrics with `dummy' set: it only scales, exactly
# as `afdummy.c'.
require "./afhints"
require "./afblue_data"
require "./afglobal"

module Autofit
  # AF_LATIN_BLUE_* (aflatin.h)
  BLUE_ACTIVE     = (1_u8 << 0)
  BLUE_TOP        = (1_u8 << 1)
  BLUE_SUB_TOP    = (1_u8 << 2)
  BLUE_NEUTRAL    = (1_u8 << 3)
  BLUE_ADJUSTMENT = (1_u8 << 4)

  # AF_LATIN_HINTS_* (aflatin.h)
  LATIN_HINTS_HORZ_SNAP   = (1_u32 << 0)
  LATIN_HINTS_VERT_SNAP   = (1_u32 << 1)
  LATIN_HINTS_STEM_ADJUST = (1_u32 << 2)
  LATIN_HINTS_MONO        = (1_u32 << 3)

  # AF_SCALER_FLAG_* (aftypes.h)
  SCALER_FLAG_NO_HORIZONTAL = 1_u32
  SCALER_FLAG_NO_VERTICAL   = 2_u32
  SCALER_FLAG_NO_ADVANCE    = 4_u32

  LATIN_MAX_WIDTHS = 16

  # af_blue_stringset properties (afblue.h)
  BLUE_PROPERTY_LATIN_TOP      = 1_u8
  BLUE_PROPERTY_LATIN_SUB_TOP  = 2_u8
  BLUE_PROPERTY_LATIN_NEUTRAL  = 4_u8
  BLUE_PROPERTY_LATIN_X_HEIGHT = 8_u8
  BLUE_PROPERTY_LATIN_LONG     = 16_u8

  # standard_charstring of the ported scripts (afscript.h)
  STANDARD_CHARSTRINGS = {
    :adlm => "𞤌 𞤮",
    :arab => "ل ح ـ",
    :armn => "ս Ս",
    :avst => "𐬚",
    :bamu => "ꛁ ꛯ",
    :beng => "০ ৪",
    :buhd => "ᝋ ᝏ",
    :cakm => "𑄤 𑄉 𑄛",
    :cans => "ᑌ ᓚ",
    :cari => "𐊫 𐋉",
    :cher => "Ꭴ Ꮕ ꮕ",
    :copt => "Ⲟ ⲟ",
    :cprt => "𐠅 𐠣",
    :cyrl => "о О",
    :deva => "ठ व ट",
    :dsrt => "𐐄 𐐬",
    :ethi => "ዐ",
    :geor => "ი ე ა Ჿ",
    :geok => "Ⴖ Ⴑ ⴙ",
    :glag => "Ⱅ ⱅ",
    :goth => "𐌴 𐌾 𐍃",
    :grek => "ο Ο",
    :gujr => "ટ ૦",
    :guru => "ਠ ਰ ੦",
    :hebr => "ם",
    :kali => "ꤍ ꤀",
    :khmr => "០",
    :khms => "᧡ ᧪",
    :knda => "೦ ಬ",
    :lao => "໐",
    :latn => "o O 0",
    :latb => "ₒ ₀",
    :latp => "ᵒ ᴼ ⁰",
    :lisu => "ꓳ",
    :mlym => "ഠ റ",
    :medf => "𖹡 𖹛 𖹯",
    :mong => "ᡂ ᠪ",
    :mymr => "ဝ င ဂ",
    :nkoo => "ߋ ߀",
    :none => "",
    :olck => "ᱛ",
    :orkh => "𐰗",
    :osge => "𐓂 𐓪",
    :osma => "𐒆 𐒠",
    :rohg => "𐴰",
    :saur => "ꢝ ꣐",
    :shaw => "𐑴",
    :sinh => "ට",
    :sund => "᮰",
    :taml => "௦",
    :tavt => "ꪒ ꪫ",
    :telu => "౦ ౧",
    :tfng => "ⵔ",
    :thai => "า ๅ ๐",
    :vaii => "ꘓ ꖜ ꖴ",
    :limb => "o",
    :orya => "o",
    :sylo => "o",
    :tibt => "o",
    :hani => "田 囗",
  }

  # The face operations the metrics/hints machinery needs — implemented
  # by the TT loader glue.
  module FontFaceAdapter
    abstract def glyph_index(codepoint : Int32) : Int32
    # unhinted outline in font units, or nil when unusable
    abstract def load_unscaled(gid : Int32) : {Array(Int64), Array(Int64), Array(UInt8), Array(Int32)}?
    abstract def advance_unscaled(gid : Int32) : Int64
    abstract def italic? : Bool
  end

  # Common shape shared by the writing systems' metrics (AF_StyleMetrics):
  # lets the loader glue and the shared (latin) segment machinery work on
  # both AF_LatinMetrics and AF_CJKMetrics.
  module StyleMetrics
    abstract def axis : Array(LatinAxis)
    abstract def units_per_em : Int32
    abstract def x_scale : Int64
    abstract def y_scale : Int64
    abstract def x_delta : Int64
    abstract def y_delta : Int64
    abstract def ppem : Int32
    abstract def digits_have_same_width : Bool
    abstract def dummy : Bool
    abstract def latin_constant(c : Int32) : Int64
    abstract def flat_threshold : Int64
    abstract def scale(x_scale : Int64, y_scale : Int64,
                       x_delta : Int64, y_delta : Int64, ppem : Int32) : Nil
  end

  class LatinBlue
    property ref : Width
    property shoot : Width
    property ascender : Int64 = 0
    property descender : Int64 = 0
    property flags : UInt8 = 0_u8

    def initialize
      @ref = Width.new
      @shoot = Width.new
    end
  end

  class LatinAxis
    property scale : Int64 = 0
    property delta : Int64 = 0
    property org_scale : Int64 = 0
    property org_delta : Int64 = 0

    property widths : Array(Width) = Array(Width).new(LATIN_MAX_WIDTHS) { Width.new }
    property width_count : Int32 = 0
    property edge_distance_threshold : Int64 = 0
    property standard_width : Int64 = 0
    property extra_light : Bool = false
    property blues : Array(LatinBlue) = [] of LatinBlue
  end

  class LatinMetrics
    include StyleMetrics

    getter style_class : StyleClass
    getter units_per_em : Int32
    # AF_ScalerRec subset
    property x_scale : Int64 = 0
    property y_scale : Int64 = 0
    property x_delta : Int64 = 0
    property y_delta : Int64 = 0
    property ppem : Int32 = 0 # x_ppem of the active size
    property digits_have_same_width : Bool = false
    # the dummy writing system (none_dflt): metrics are pass-through
    property dummy : Bool = false
    property axis : Array(LatinAxis) = [LatinAxis.new, LatinAxis.new]

    def initialize(@style_class : StyleClass, @units_per_em : Int32,
                   @dummy : Bool = false)
    end

    def latin_constant(c : Int32) : Int64
      c.to_i64! &* @units_per_em // 2048
    end

    def flat_threshold : Int64
      (@units_per_em // 14).to_i64!
    end

    # --- af_latin_metrics_init ----------------------------------------------

    # Returns false when no blue zones were found (the caller disables
    # the style, exactly as FreeType's internal error -1).
    def init(face : FontFaceAdapter) : Bool
      return true if @dummy # dummy metrics: nothing to compute

      init_widths(face)
      return false unless init_blues(face)
      check_digits(face)
      true
    end

    private def standard_glyph(face : FontFaceAdapter) : Int32
      chars = STANDARD_CHARSTRINGS[@style_class.stringset.not_nil!]? ||
              STANDARD_CHARSTRINGS[@style_class.name]?
      return 0 unless chars

      chars.split(' ').each do |ch|
        next if ch.empty?
        cp = ch[0].ord
        return 0 if cp > 0x10FFFF
        gindex = face.glyph_index(cp.to_i32)
        return gindex if gindex != 0
      end
      0
    end

    # af_latin_metrics_init_widths. The final `stdw' defaults run even
    # when the standard glyph is missing or empty (the C's `Exit:'
    # label sits before that loop).
    def init_widths(face : FontFaceAdapter) : Nil
      axis[DIMENSION_HORZ].width_count = 0
      axis[DIMENSION_HORZ].widths.each { |w| w.org = 0; w.cur = 0; w.fit = 0 }
      axis[DIMENSION_VERT].width_count = 0
      axis[DIMENSION_VERT].widths.each { |w| w.org = 0; w.cur = 0; w.fit = 0 }

      gindex = standard_glyph(face)
      if gindex != 0
        outline = face.load_unscaled(gindex)
        if outline && outline[0].size > 0
          xs, ys, tags, contours = outline

          hints = GlyphHints.new
          hints.x_scale = 0x10000_i64
          hints.y_scale = 0x10000_i64
          hints.x_delta = 0
          hints.y_delta = 0

          (0...2).each do |dim|
            ax = axis[dim]
            hints.reload(xs, ys, tags, contours, @units_per_em)

            Latin.compute_segments(hints, self, dim)
            Latin.link_segments(hints, self, 0, dim)

            num_widths = 0
            segs = hints.axis[dim].segments
            segs.each_with_index do |seg, si|
              link = seg.link
              next if link < 0
              lseg = segs.unsafe_fetch(link)
              next unless lseg.link == si && link > si

              dist = (seg.pos.to_i64! &- lseg.pos.to_i64!).abs
              if num_widths < LATIN_MAX_WIDTHS
                ax.widths[num_widths].org = dist
                num_widths += 1
              end
            end

            # sort/quantize in place over the first num_widths entries
            sub = ax.widths[0, num_widths]
            Autofit.sort_and_quantize_widths(sub, @units_per_em // 100)
            num_widths = sub.size
            (0...num_widths).each { |i| ax.widths[i] = sub[i] }
            ax.width_count = num_widths
          end
        end
      end

      (0...2).each do |dim|
        ax = axis[dim]
        stdw = ax.width_count > 0 ? ax.widths[0].org : latin_constant(50)
        ax.edge_distance_threshold = stdw // 5
        ax.standard_width = stdw
        ax.extra_light = false
      end
    end

    # af_latin_metrics_init_blues. Returns false when no blue zone was
    # found at all.
    def init_blues(face : FontFaceAdapter) : Bool
      vert = axis[DIMENSION_VERT]

      stringset_sym = @style_class.stringset.not_nil!
      start = BLUE_STRINGSETS[stringset_sym]

      idx = start
      while STRINGSETS[idx][0] != BLUE_STRING_MAX
        str_off, props = STRINGSETS[idx]
        idx += 1

        is_top = (props & BLUE_PROPERTY_LATIN_TOP) != 0
        is_sub_top = (props & BLUE_PROPERTY_LATIN_SUB_TOP) != 0
        is_neutral = (props & BLUE_PROPERTY_LATIN_NEUTRAL) != 0
        is_x_height = (props & BLUE_PROPERTY_LATIN_X_HEIGHT) != 0
        is_long = (props & BLUE_PROPERTY_LATIN_LONG) != 0

        num_flats = 0
        num_rounds = 0
        flats = [] of Int64
        rounds = [] of Int64
        ascender = 0_i64
        descender = 0_i64

        BLUE_STRINGS[str_off].split(' ').each do |ch|
          next if ch.empty?
          cp = ch[0].ord
          gindex = face.glyph_index(cp.to_i32)
          next if gindex == 0

          best_y_extremum = is_top ? Int64::MIN : Int64::MAX
          best_round = false

          outline = face.load_unscaled(gindex)
          next if outline.nil?
          xs, ys, tags, contours = outline
          next if xs.size <= 2 # reject too-small outlines

          best_point = -1
          best_contour_first = -1
          best_contour_last = -1
          best_y = 0_i64

          last_i = -1
          contours.each do |cend|
            first_i = last_i + 1
            last_i = cend
            next if last_i <= first_i # single-point contours

            if is_top || is_sub_top
              (first_i..last_i).each do |pp|
                if best_point < 0 || ys.unsafe_fetch(pp) > best_y
                  best_point = pp
                  best_y = ys.unsafe_fetch(pp)
                  ascender = {ascender, best_y}.max
                else
                  descender = {descender, ys.unsafe_fetch(pp)}.min
                end
              end
            else
              (first_i..last_i).each do |pp|
                if best_point < 0 || ys.unsafe_fetch(pp) < best_y
                  best_point = pp
                  best_y = ys.unsafe_fetch(pp)
                  descender = {descender, best_y}.min
                else
                  ascender = {ascender, ys.unsafe_fetch(pp)}.max
                end
              end
            end

            if best_point > best_contour_last
              best_contour_first = first_i
              best_contour_last = last_i
            end
          end

          if best_point >= 0
            best_y = ys.unsafe_fetch(best_point)
            best_x = xs.unsafe_fetch(best_point)

            best_segment_first = best_point
            best_segment_last = best_point

            if (tags.unsafe_fetch(best_point) & 0x03) == 1 # ON
              best_on_point_first = best_point
              best_on_point_last = best_point
            else
              best_on_point_first = -1
              best_on_point_last = -1
            end

            prev = best_point
            loop do
              prev = prev > best_contour_first ? prev - 1 : best_contour_last
              dist = (ys.unsafe_fetch(prev) &- best_y).abs
              if dist > 5 &&
                 (xs.unsafe_fetch(prev) &- best_x).abs <= 20 &* dist
                break
              end

              best_segment_first = prev
              if (tags.unsafe_fetch(prev) & 0x03) == 1
                best_on_point_first = prev
                best_on_point_last = prev if best_on_point_last < 0
              end

              break if prev == best_point
            end

            nxt = best_point
            loop do
              nxt = nxt < best_contour_last ? nxt + 1 : best_contour_first
              dist = (ys.unsafe_fetch(nxt) &- best_y).abs
              if dist > 5 &&
                 (xs.unsafe_fetch(nxt) &- best_x).abs <= 20 &* dist
                break
              end

              best_segment_last = nxt
              if (tags.unsafe_fetch(nxt) & 0x03) == 1
                best_on_point_last = nxt
                best_on_point_first = nxt if best_on_point_first < 0
              end

              break if nxt == best_point
            end

            # AF_LATIN_IS_LONG_BLUE handling is not needed for
            # latn/cyrl/grek stringsets (no LONG property there)

            round = false
            if best_on_point_first >= 0 && best_on_point_last >= 0 &&
               (xs.unsafe_fetch(best_on_point_last) &-
                xs.unsafe_fetch(best_on_point_first)).abs > flat_threshold
              round = false
            else
              round = (tags.unsafe_fetch(best_segment_first) & 0x03) != 1 ||
                      (tags.unsafe_fetch(best_segment_last) & 0x03) != 1
            end

            next if round && is_neutral # neutral zones: flat only

            if is_top
              if best_y > best_y_extremum
                best_y_extremum = best_y
                best_round = round
              end
            else
              if best_y < best_y_extremum
                best_y_extremum = best_y
                best_round = round
              end
            end
          end

          if best_y_extremum != Int64::MIN && best_y_extremum != Int64::MAX
            if best_round
              rounds << best_y_extremum if rounds.size < 8
            else
              flats << best_y_extremum if flats.size < 8
            end
          end
        end

        next if flats.empty? && rounds.empty?

        Autofit.sort_pos(rounds)
        Autofit.sort_pos(flats)

        blue = LatinBlue.new
        vert.blues << blue

        if flats.empty?
          blue.ref.org = blue.shoot.org = rounds[rounds.size // 2]
        elsif rounds.empty?
          blue.ref.org = blue.shoot.org = flats[flats.size // 2]
        else
          blue.ref.org = flats[flats.size // 2]
          blue.shoot.org = rounds[rounds.size // 2]
        end

        if blue.shoot.org != blue.ref.org
          ref = blue.ref.org
          shoot = blue.shoot.org
          over_ref = shoot > ref
          if (is_top || is_sub_top) != over_ref
            blue.ref.org = blue.shoot.org = (shoot &+ ref).tdiv(2)
          end
        end

        blue.ascender = ascender
        blue.descender = descender

        blue.flags |= BLUE_TOP if is_top
        blue.flags |= BLUE_SUB_TOP if is_sub_top
        blue.flags |= BLUE_NEUTRAL if is_neutral
        blue.flags |= BLUE_ADJUSTMENT if is_x_height
      end

      return false if vert.blues.empty?

      # af_latin_sort_blue: sort pointers bottom-to-top; the blues array
      # order itself stays as computed
      blue_sorted = vert.blues.dup
      (1...blue_sorted.size).each do |i|
        j = i
        while j > 0
          a = blue_sorted[j - 1]
          b = blue_sorted[j]
          av = a.flags & (BLUE_TOP | BLUE_SUB_TOP) != 0 ? a.ref.org : a.shoot.org
          bv = b.flags & (BLUE_TOP | BLUE_SUB_TOP) != 0 ? b.ref.org : b.shoot.org
          break if bv >= av
          blue_sorted[j - 1] = b
          blue_sorted[j] = a
          j -= 1
        end
      end

      # ...and adjust top values if necessary
      (0...blue_sorted.size - 1).each do |i|
        bi = blue_sorted[i]
        bj = blue_sorted[i + 1]
        a = bi.flags & (BLUE_TOP | BLUE_SUB_TOP) != 0 ? bi.shoot : bi.ref
        b = bj.flags & (BLUE_TOP | BLUE_SUB_TOP) != 0 ? bj.shoot : bj.ref
        a.org = b.org if a.org > b.org
      end

      true
    end

    # af_latin_metrics_check_digits
    def check_digits(face : FontFaceAdapter) : Nil
      started = false
      same_width = true
      old_advance = 0_i64

      (0x30..0x39).each do |cp|
        gindex = face.glyph_index(cp)
        next if gindex == 0

        advance = face.advance_unscaled(gindex)

        if started
          if advance != old_advance
            same_width = false
            break
          end
        else
          old_advance = advance
          started = true
        end
      end

      @digits_have_same_width = same_width
    end

    # --- af_latin_metrics_scale ----------------------------------------------

    def scale(x_scale : Int64, y_scale : Int64,
              x_delta : Int64, y_delta : Int64, ppem : Int32) : Nil
      @x_scale = x_scale
      @y_scale = y_scale
      @x_delta = x_delta
      @y_delta = y_delta
      @ppem = ppem

      return if @dummy # dummy: pass-through scaler, no axis scaling

      scale_dim(DIMENSION_HORZ)
      scale_dim(DIMENSION_VERT)
    end

    private def scale_dim(dim : Int32) : Nil
      sc = dim == DIMENSION_HORZ ? @x_scale : @y_scale
      delta = dim == DIMENSION_HORZ ? @x_delta : @y_delta

      ax = axis[dim]
      return if ax.org_scale == sc && ax.org_delta == delta

      ax.org_scale = sc
      ax.org_delta = delta

      # x-height alignment (VERT blues with ADJUSTMENT)
      vert = axis[DIMENSION_VERT]
      blue = vert.blues.find { |b| b.flags & BLUE_ADJUSTMENT != 0 }

      unless blue.nil?
        scaled = Fixed.mulfix(blue.shoot.org, sc)
        limit = 0 # module default: increase-x-height disabled
        threshold = 40_i64
        threshold = 52_i64 if limit != 0 && ppem <= limit && ppem >= 6

        fitted = (scaled &+ threshold) & ~63_i64

        if scaled != fitted && dim == DIMENSION_VERT
          new_scale = Fixed.muldiv(sc, fitted, scaled)

          max_height = @units_per_em.to_i64!
          vert.blues.each do |b|
            max_height = {max_height, b.ascender}.max
            max_height = {max_height, -b.descender}.max
          end

          dist = Fixed.mulfix(max_height, new_scale &- sc)
          sc = new_scale if -128 < dist && dist < 128
        end
      end

      ax.scale = sc
      ax.delta = delta

      if dim == DIMENSION_HORZ
        @x_scale = sc
        @x_delta = delta
      else
        @y_scale = sc
        @y_delta = delta
      end

      (0...ax.width_count).each do |nn|
        width = ax.widths[nn]
        width.cur = Fixed.mulfix(width.org, sc)
        width.fit = width.cur
      end

      ax.extra_light = Fixed.mulfix(ax.standard_width, sc) < 32 + 8

      if dim == DIMENSION_VERT
        ax.blues.each do |b|
          b.ref.cur = Fixed.mulfix(b.ref.org, sc) &+ delta
          b.ref.fit = b.ref.cur
          b.shoot.cur = Fixed.mulfix(b.shoot.org, sc) &+ delta
          b.shoot.fit = b.shoot.cur
          b.flags &= ~BLUE_ACTIVE

          dist = Fixed.mulfix(b.ref.org &- b.shoot.org, sc)
          if dist <= 48 && dist >= -48
            delta2 = dist < 0 ? -dist : dist
            delta2 = 0_i64 if delta2 < 32
            delta2 = 32_i64 if delta2 >= 32 && delta2 < 48
            delta2 = 64_i64 if delta2 >= 48
            delta2 = -delta2 if dist < 0

            b.ref.fit = (b.ref.cur + 32) & ~63_i64
            b.shoot.fit = b.ref.fit &- delta2

            b.flags |= BLUE_ACTIVE
          end
        end

        # disable sub-top blues overlapping a normal active blue
        ax.blues.each do |b|
          next unless b.flags & BLUE_SUB_TOP != 0
          next unless b.flags & BLUE_ACTIVE != 0

          ax.blues.each do |b2|
            next if b2.flags & BLUE_SUB_TOP != 0
            next unless b2.flags & BLUE_ACTIVE != 0

            if b2.ref.fit <= b.shoot.fit && b2.shoot.fit >= b.ref.fit
              b.flags &= ~BLUE_ACTIVE
              break
            end
          end
        end
      end
    end
  end

  # The latin algorithm functions, operating on GlyphHints.
  module Latin
    extend self

    # --- af_latin_hints_compute_segments -----------------------------------

    def compute_segments(hints : GlyphHints, metrics : StyleMetrics,
                         dim : Int32) : Nil
      ax = hints.axis[dim]

      major_dir = ax.major_dir.abs
      segment_dir = major_dir

      ax.segments.clear

      # set up (u,v) in each point
      hints.points.each do |point|
        if dim == DIMENSION_HORZ
          point.u = point.fx.to_i64!
          point.v = point.fy.to_i64!
        else
          point.u = point.fy.to_i64!
          point.v = point.fx.to_i64!
        end
      end

      flat_threshold = metrics.flat_threshold

      points = hints.points

      (0...hints.contours.size).each do |ci|
        cstart = hints.contours[ci]
        point = cstart
        on_edge = false
        min_pos = 32000_i64
        max_pos = -32000_i64
        min_coord = 32000_i64
        max_coord = -32000_i64
        min_flags = 0_u16
        max_flags = 0_u16
        min_on_coord = 32000_i64
        max_on_coord = -32000_i64

        prev_segment = -1

        prev_min_pos = min_pos
        prev_max_pos = max_pos
        prev_min_coord = min_coord
        prev_max_coord = max_coord
        prev_min_flags = min_flags
        prev_max_flags = max_flags
        prev_min_on_coord = min_on_coord
        prev_max_on_coord = max_on_coord

        segment = -1

        last = points.unsafe_fetch(point).prev
        if last >= 0 && points.unsafe_fetch(last).out_dir.abs == major_dir &&
           points.unsafe_fetch(point).out_dir.abs == major_dir
          # already on an edge; locate its start
          last = point
          loop do
            point = points.unsafe_fetch(point).prev
            if points.unsafe_fetch(point).out_dir.abs != major_dir
              point = points.unsafe_fetch(point).next
              break
            end
            break if point == last
          end
        end

        last = point
        passed = false

        loop do
          if on_edge
            p = points.unsafe_fetch(point)

            u = p.u
            min_pos = u if u < min_pos
            max_pos = u if u > max_pos

            v = p.v
            if v < min_coord
              min_coord = v
              min_flags = p.flags
            end
            if v > max_coord
              max_coord = v
              max_flags = p.flags
            end

            if p.flags & (FLAG_CONIC | FLAG_CUBIC) == 0
              v = p.v
              min_on_coord = v if v < min_on_coord
              max_on_coord = v if v > max_on_coord
            end

            if p.out_dir != segment_dir || point == last
              seg = ax.segments.unsafe_fetch(segment)

              if prev_segment < 0 ||
                 seg.first != ax.segments.unsafe_fetch(prev_segment).last
                # leaving an edge: record a new segment
                seg.last = point
                seg.pos = ((min_pos &+ max_pos) >> 1).to_i16!
                seg.delta = ((max_pos &- min_pos) >> 1).to_i16!

                if (min_flags | max_flags) & (FLAG_CONIC | FLAG_CUBIC) != 0 &&
                   (max_on_coord &- min_on_coord) < flat_threshold
                  seg.flags |= EDGE_ROUND
                end

                seg.min_coord = min_coord.to_i16!
                seg.max_coord = max_coord.to_i16!
                seg.height = (seg.max_coord &- seg.min_coord).to_i16!

                prev_segment = segment
                prev_min_pos = min_pos
                prev_max_pos = max_pos
                prev_min_coord = min_coord
                prev_max_coord = max_coord
                prev_min_flags = min_flags
                prev_max_flags = max_flags
                prev_min_on_coord = min_on_coord
                prev_max_on_coord = max_on_coord
              else
                pseg = ax.segments.unsafe_fetch(prev_segment)
                if points.unsafe_fetch(pseg.last).in_dir == p.in_dir
                  # identical directions: unify segments
                  min_pos = prev_min_pos if prev_min_pos < min_pos
                  max_pos = prev_max_pos if prev_max_pos > max_pos

                  if prev_min_coord < min_coord
                    min_coord = prev_min_coord
                    min_flags = prev_min_flags
                  end
                  if prev_max_coord > max_coord
                    max_coord = prev_max_coord
                    max_flags = prev_max_flags
                  end

                  min_on_coord = prev_min_on_coord if prev_min_on_coord < min_on_coord
                  max_on_coord = prev_max_on_coord if prev_max_on_coord > max_on_coord

                  pseg.last = point
                  pseg.pos = ((min_pos &+ max_pos) >> 1).to_i16!
                  pseg.delta = ((max_pos &- min_pos) >> 1).to_i16!

                  if (min_flags | max_flags) & (FLAG_CONIC | FLAG_CUBIC) != 0 &&
                     (max_on_coord &- min_on_coord) < flat_threshold
                    pseg.flags |= EDGE_ROUND
                  else
                    pseg.flags &= ~EDGE_ROUND
                  end

                  pseg.min_coord = min_coord.to_i16!
                  pseg.max_coord = max_coord.to_i16!
                  pseg.height = (pseg.max_coord &- pseg.min_coord).to_i16!
                else
                  # different directions: keep the longer one
                  if (prev_max_coord &- prev_min_coord).abs >
                     (max_coord &- min_coord).abs
                    # discard the current segment
                    prev_min_pos = min_pos if min_pos < prev_min_pos
                    prev_max_pos = max_pos if max_pos > prev_max_pos

                    pseg.last = point
                    pseg.pos = ((prev_min_pos &+ prev_max_pos) >> 1).to_i16!
                    pseg.delta = ((prev_max_pos &- prev_min_pos) >> 1).to_i16!
                  else
                    # discard the previous segment
                    min_pos = prev_min_pos if prev_min_pos < min_pos
                    max_pos = prev_max_pos if prev_max_pos > max_pos

                    seg.last = point
                    seg.pos = ((min_pos &+ max_pos) >> 1).to_i16!
                    seg.delta = ((max_pos &- min_pos) >> 1).to_i16!

                    if (min_flags | max_flags) & (FLAG_CONIC | FLAG_CUBIC) != 0 &&
                       (max_on_coord &- min_on_coord) < flat_threshold
                      seg.flags |= EDGE_ROUND
                    end

                    seg.min_coord = min_coord.to_i16!
                    seg.max_coord = max_coord.to_i16!
                    seg.height = (seg.max_coord &- seg.min_coord).to_i16!

                    pseg.copy_from(seg)

                    prev_min_pos = min_pos
                    prev_max_pos = max_pos
                    prev_min_coord = min_coord
                    prev_max_coord = max_coord
                    prev_min_flags = min_flags
                    prev_max_flags = max_flags
                    prev_min_on_coord = min_on_coord
                    prev_max_on_coord = max_on_coord
                  end
                end

                ax.segments.pop
              end

              on_edge = false
              segment = -1
            end
          end

          if point == last
            break if passed
            passed = true
          end

          p = points.unsafe_fetch(point)
          if !on_edge &&
             (p.out_dir.abs == major_dir || point == p.prev)
            if ax.segments.size > 1000
              ax.segments.clear
              return
            end

            segment_dir = p.out_dir
            segment = ax.new_segment
            seg = ax.segments.unsafe_fetch(segment)
            seg.flags = EDGE_NORMAL
            seg.dir = segment_dir
            seg.first = point
            seg.last = point
            seg.score = 32000
            seg.edge = -1
            seg.edge_next = -1
            seg.link = -1
            seg.serif = -1
            seg.len = 0

            min_pos = max_pos = p.u
            min_coord = max_coord = p.v
            min_flags = max_flags = p.flags

            if p.flags & (FLAG_CONIC | FLAG_CUBIC) != 0
              min_on_coord = 32000
              max_on_coord = -32000
            else
              min_on_coord = max_on_coord = p.v
            end

            on_edge = true

            if point == p.prev
              # one-point contour
              seg.pos = min_pos.to_i16!
              seg.flags |= EDGE_ROUND if p.flags & (FLAG_CONIC | FLAG_CUBIC) != 0
              seg.min_coord = p.v.to_i16!
              seg.max_coord = p.v.to_i16!
              seg.height = 0

              on_edge = false
              segment = -1
            end
          end

          point = points.unsafe_fetch(point).next
        end
      end

      # slightly increase the height of segments if this makes sense
      ax.segments.each do |seg|
        first = points.unsafe_fetch(seg.first)
        last = points.unsafe_fetch(seg.last)
        first_v = first.v
        last_v = last.v

        if first_v < last_v
          p = points.unsafe_fetch(first.prev)
          if p.v < first_v
            seg.height = (seg.height.to_i64! &+ ((first_v &- p.v) >> 1)).to_i16!
          end

          p = points.unsafe_fetch(last.next)
          if p.v > last_v
            seg.height = (seg.height.to_i64! &+ ((p.v &- last_v) >> 1)).to_i16!
          end
        else
          p = points.unsafe_fetch(first.prev)
          if p.v > first_v
            seg.height = (seg.height.to_i64! &+ ((p.v &- first_v) >> 1)).to_i16!
          end

          p = points.unsafe_fetch(last.next)
          if p.v < last_v
            seg.height = (seg.height.to_i64! &+ ((last_v &- p.v) >> 1)).to_i16!
          end
        end
      end
    end

    # --- af_latin_hints_link_segments ----------------------------------------

    def link_segments(hints : GlyphHints, metrics : StyleMetrics,
                      width_count : Int32, dim : Int32) : Nil
      ax = hints.axis[dim]
      segs = ax.segments
      laxis = metrics.axis[dim]

      max_width = width_count != 0 ? laxis.widths[width_count - 1].org : 0_i64

      len_threshold = metrics.latin_constant(8)
      len_threshold = 1 if len_threshold == 0

      len_score = metrics.latin_constant(6000)
      dist_score = 3000_i64

      segs.each_with_index do |seg1, si1|
        next if seg1.dir != ax.major_dir

        segs.each_with_index do |seg2, si2|
          pos1 = seg1.pos.to_i64!
          pos2 = seg2.pos.to_i64!

          next unless seg1.dir &+ seg2.dir == 0 && pos2 > pos1

          min = seg1.min_coord.to_i64!
          max = seg1.max_coord.to_i64!
          min = seg2.min_coord.to_i64! if min < seg2.min_coord
          max = seg2.max_coord.to_i64! if max > seg2.max_coord

          len = max &- min
          next unless len >= len_threshold

          dist = pos2 &- pos1

          dist_demerit = if max_width != 0
            delta = (dist << 10).tdiv(max_width) &- (1 << 10)
            if delta > 10000
              32000_i64
            elsif delta > 0
              delta &* delta // dist_score
            else
              0_i64
            end
          else
            dist
          end

          score = dist_demerit &+ len_score.tdiv(len)

          if score < seg1.score
            seg1.score = score
            seg1.link = si2
          end

          if score < seg2.score
            seg2.score = score
            seg2.link = si1
          end
        end
      end

      # compute the `serif' segments
      segs.each_with_index do |seg1, si1|
        seg2_i = seg1.link
        next if seg2_i < 0

        seg2 = segs.unsafe_fetch(seg2_i)
        if seg2.link != si1
          seg1.link = -1
          seg1.serif = seg2.link
        end
      end
    end

    # --- af_latin_hints_compute_edges ----------------------------------------

    def compute_edges(hints : GlyphHints, metrics : StyleMetrics,
                      dim : Int32) : Nil
      ax = hints.axis[dim]
      laxis = metrics.axis[dim]

      top_to_bottom_hinting = false

      ax.edges.clear

      scale = dim == DIMENSION_HORZ ? hints.x_scale : hints.y_scale

      segment_length_threshold = dim == DIMENSION_HORZ ? Fixed.divfix(64, hints.y_scale) : 0_i64
      segment_width_threshold = Fixed.divfix(32, scale)

      edge_distance_threshold = Fixed.mulfix(laxis.edge_distance_threshold, scale)
      edge_distance_threshold = 64_i64 // 4 if edge_distance_threshold > 64_i64 // 4
      edge_distance_threshold = Fixed.divfix(edge_distance_threshold, scale)

      segs = ax.segments

      segs.each_with_index do |seg, si|
        next if seg.height.to_i64! < segment_length_threshold ||
                seg.delta.to_i64! > segment_width_threshold ||
                seg.dir == DIR_NONE

        if seg.serif >= 0 &&
           2_i64 &* seg.height < 3_i64 &* segment_length_threshold
          next
        end

        found = -1
        ax.edges.each_with_index do |edge, ee|
          dist = seg.pos.to_i64! &- edge.fpos
          dist = -dist if dist < 0
          if dist < edge_distance_threshold && edge.dir == seg.dir
            found = ee
            break
          end
        end

        if found < 0
          ei = ax.new_edge(seg.pos.to_i32!, seg.dir, top_to_bottom_hinting)
          edge = ax.edges.unsafe_fetch(ei)
          edge.first = si
          edge.last = si
          edge.dir = seg.dir
          edge.fpos = seg.pos
          edge.opos = Fixed.mulfix(seg.pos.to_i64!, scale)
          edge.pos = edge.opos
          seg.edge_next = si
        else
          edge = ax.edges.unsafe_fetch(found)
          seg.edge_next = edge.first
          segs.unsafe_fetch(edge.last).edge_next = si
          edge.last = si
        end
      end

      # one-point segments without a direction
      segs.each_with_index do |seg, si|
        next if seg.dir != DIR_NONE

        found = -1
        ax.edges.each_with_index do |edge, ee|
          dist = seg.pos.to_i64! &- edge.fpos
          dist = -dist if dist < 0
          if dist < edge_distance_threshold
            found = ee
            break
          end
        end

        next if found < 0

        edge = ax.edges.unsafe_fetch(found)
        seg.edge_next = edge.first
        segs.unsafe_fetch(edge.last).edge_next = si
        edge.last = si
      end

      # set the `edge' field in each segment
      ax.edges.each_with_index do |edge, ei|
        si = edge.first
        next if si < 0
        loop do
          seg = segs.unsafe_fetch(si)
          seg.edge = ei
          si = seg.edge_next
          break if si == edge.first
        end
      end

      # now compute each edge's properties
      ax.edges.each_with_index do |edge, ei|
        is_round = 0
        is_straight = 0

        si = edge.first
        loop do
          seg = segs.unsafe_fetch(si)

          if seg.flags & EDGE_ROUND != 0
            is_round += 1
          else
            is_straight += 1
          end

          is_serif = seg.serif >= 0 &&
                     segs.unsafe_fetch(seg.serif).edge >= 0 &&
                     segs.unsafe_fetch(seg.serif).edge != ei

          if (seg.link >= 0 && segs.unsafe_fetch(seg.link).edge >= 0) || is_serif
            seg2_i = seg.link
            edge2_i = edge.link

            if is_serif
              seg2_i = seg.serif
              edge2_i = edge.serif
            end

            seg2 = segs.unsafe_fetch(seg2_i)

            if edge2_i >= 0
              edge2 = ax.edges.unsafe_fetch(edge2_i)

              edge_delta = edge.fpos.to_i64! &- edge2.fpos
              edge_delta = -edge_delta if edge_delta < 0

              seg_delta = seg.pos.to_i64! &- seg2.pos
              seg_delta = -seg_delta if seg_delta < 0

              edge2_i = seg2.edge if seg_delta < edge_delta
            else
              edge2_i = seg2.edge
            end

            if is_serif
              edge.serif = edge2_i
              ax.edges.unsafe_fetch(edge2_i).flags |= EDGE_SERIF
            else
              edge.link = edge2_i
            end
          end

          si = seg.edge_next
          break if si == edge.first
        end

        edge.flags = EDGE_NORMAL
        edge.flags |= EDGE_ROUND if is_round > 0 && is_round >= is_straight

        edge.serif = -1 if edge.serif >= 0 && edge.link >= 0
      end
    end

    # --- af_latin_hints_compute_blue_edges -----------------------------------

    def compute_blue_edges(hints : GlyphHints, metrics : LatinMetrics) : Nil
      ax = hints.axis[DIMENSION_VERT]
      latin = metrics.axis[DIMENSION_VERT]
      scale = latin.scale

      ax.edges.each do |edge|
        best_blue : Width? = nil
        best_blue_is_neutral = false

        best_dist = Fixed.mulfix(metrics.units_per_em.to_i64! // 40, scale)
        best_dist = 64 // 2 if best_dist > 64 // 2

        latin.blues.each do |blue|
          next unless blue.flags & BLUE_ACTIVE != 0

          is_top_blue = blue.flags & (BLUE_TOP | BLUE_SUB_TOP) != 0
          is_neutral_blue = blue.flags & BLUE_NEUTRAL != 0
          is_major_dir = edge.dir == ax.major_dir

          next unless is_top_blue != is_major_dir || is_neutral_blue

          dist = edge.fpos.to_i64! &- blue.ref.org
          dist = -dist if dist < 0
          dist = Fixed.mulfix(dist, scale)

          if dist < best_dist
            best_dist = dist
            best_blue = blue.ref
            best_blue_is_neutral = is_neutral_blue
          end

          if edge.flags & EDGE_ROUND != 0 && dist != 0 && !is_neutral_blue
            is_under_ref = edge.fpos.to_i64! < blue.ref.org

            if is_top_blue != is_under_ref
              dist = edge.fpos.to_i64! &- blue.shoot.org
              dist = -dist if dist < 0
              dist = Fixed.mulfix(dist, scale)

              if dist < best_dist
                best_dist = dist
                best_blue = blue.shoot
                best_blue_is_neutral = is_neutral_blue
              end
            end
          end
        end

        unless best_blue.nil?
          edge.blue_edge = best_blue
          edge.flags |= EDGE_NEUTRAL if best_blue_is_neutral
        end
      end
    end

    # --- af_latin_hints_init --------------------------------------------------

    def hints_init(hints : GlyphHints, metrics : LatinMetrics,
                   italic : Bool) : Nil
      hints.x_scale = metrics.axis[DIMENSION_HORZ].scale
      hints.x_delta = metrics.axis[DIMENSION_HORZ].delta
      hints.y_scale = metrics.axis[DIMENSION_VERT].scale
      hints.y_delta = metrics.axis[DIMENSION_VERT].delta

      # FT_RENDER_MODE_NORMAL: no snapping flags, stem adjust on.
      # The scaler flags start from a rescale reset (af_glyph_hints_
      # rescale assigns metrics->scaler.flags == 0), so the NO_ADVANCE
      # bit a previous CJK glyph may have set must not survive here.
      hints.other_flags = LATIN_HINTS_STEM_ADJUST

      flags = hints.scaler_flags & ~(SCALER_FLAG_NO_HORIZONTAL | SCALER_FLAG_NO_ADVANCE)
      flags |= SCALER_FLAG_NO_HORIZONTAL if italic
      hints.scaler_flags = flags
    end

    # --- stem width computation ------------------------------------------------

    def snap_width(widths : Array(Width), count : Int32, width : Int64) : Int64
      best = 64 + 32 + 2
      reference = width

      (0...count).each do |n|
        w = widths[n].cur
        dist = width &- w
        dist = -dist if dist < 0
        if dist < best
          best = dist
          reference = w
        end
      end

      scaled = (reference &+ 32) & ~63_i64

      if width >= reference
        width = reference if width < scaled &+ 48
      else
        width = reference if width > scaled &- 48
      end

      width
    end

    def compute_stem_width(hints : GlyphHints, metrics : LatinMetrics,
                           dim : Int32, width : Int64, base_delta : Int64,
                           base_flags : UInt8, stem_flags : UInt8) : Int64
      laxis = metrics.axis[dim]
      dist = width
      sign = false
      vertical = dim == DIMENSION_VERT

      stem_adjust = hints.other_flags & LATIN_HINTS_STEM_ADJUST != 0
      r = if !stem_adjust || laxis.extra_light
        width
      else
        nil
      end
      return r.not_nil! unless r.nil?

      if dist < 0
        dist = -width
        sign = true
      end

      horz_snap = hints.other_flags & LATIN_HINTS_HORZ_SNAP != 0
      vert_snap = hints.other_flags & LATIN_HINTS_VERT_SNAP != 0

      if (vertical && !vert_snap) || (!vertical && !horz_snap)
        # smooth hinting: very lightly quantize

        # `goto Done_Width' in af_latin_compute_stem_width: a serif width
        # below 3px stays untouched — no round/56 clamp, no width snapping.
        serif_leave = stem_flags & EDGE_SERIF != 0 && vertical &&
                      dist < 3 &* 64

        if serif_leave
          # leave the widths of serifs alone
        elsif base_flags & EDGE_ROUND != 0
          dist = 64_i64 if dist < 80
        elsif dist < 56
          dist = 56_i64
        end

        if laxis.width_count > 0 && !serif_leave
          delta = dist &- laxis.widths[0].cur
          delta = -delta if delta < 0

          if delta < 40
            dist = laxis.widths[0].cur
            dist = 48_i64 if dist < 48
            # Done_Width
          elsif dist < 3 &* 64
            delta = dist & 63
            dist &= ~63_i64

            if delta < 10
              dist += delta
            elsif delta < 32
              dist += 10
            elsif delta < 54
              dist += 54
            else
              dist += delta
            end
          else
            bdelta = 0_i64

            if (width > 0 && base_delta > 0) || (width < 0 && base_delta < 0)
              ppem = metrics.ppem

              if ppem < 10
                bdelta = base_delta
              elsif ppem < 30
                # C integer division truncates toward zero
                bdelta = (base_delta &* (30 - ppem)).tdiv(20)
              end

              bdelta = -bdelta if bdelta < 0
            end

            dist = (dist &- bdelta &+ 32) & ~63_i64
          end
        end
      else
        # strong hinting: snap to integer pixels
        org_dist = dist

        dist = snap_width(laxis.widths, laxis.width_count, dist)

        if vertical
          dist = dist >= 64 ? (dist &+ 16) & ~63_i64 : 64_i64
        else
          if hints.other_flags & LATIN_HINTS_MONO != 0
            dist = dist < 64 ? 64_i64 : (dist &+ 32) & ~63_i64
          else
            if dist < 48
              dist = (dist &+ 64) >> 1
            elsif dist < 128
              dist = (dist &+ 22) & ~63_i64
              delta = dist &- org_dist
              delta = -delta if delta < 0
              if delta >= 16
                dist = org_dist
                dist = (dist &+ 64) >> 1 if dist < 48
              end
            else
              dist = (dist &+ 32) & ~63_i64
            end
          end
        end
      end

      dist = -dist if sign
      dist
    end

    def align_linked_edge(hints : GlyphHints, metrics : LatinMetrics,
                          dim : Int32, edges : Array(Edge), base_i : Int32,
                          stem_i : Int32) : Nil
      base_edge = edges.unsafe_fetch(base_i)
      stem_edge = edges.unsafe_fetch(stem_i)

      dist = stem_edge.opos &- base_edge.opos
      base_delta = base_edge.pos &- base_edge.opos

      fitted_width = compute_stem_width(hints, metrics, dim, dist,
                                        base_delta, base_edge.flags,
                                        stem_edge.flags)

      stem_edge.pos = base_edge.pos &+ fitted_width
    end

    def align_serif_edge(edges : Array(Edge), base_i : Int32, serif_i : Int32) : Nil
      base = edges.unsafe_fetch(base_i)
      serif = edges.unsafe_fetch(serif_i)
      serif.pos = base.pos &+ (serif.opos &- base.opos)
    end

    # --- af_latin_hint_edges ----------------------------------------------------

    def hint_edges(hints : GlyphHints, metrics : LatinMetrics, dim : Int32) : Nil
      ax = hints.axis[dim]
      edges = ax.edges
      n_edges = edges.size
      anchor = -1
      has_serifs = false

      top_to_bottom_hinting = false

      # align stems relative to blue zones (horizontal edges)
      if dim == DIMENSION_VERT
        edges.each_with_index do |edge, ei|
          next if edge.flags & EDGE_DONE != 0

          edge1 = -1
          edge2 = edge.link

          if !edge.blue_edge.nil? && edge2 >= 0 && !edges[edge2].blue_edge.nil?
            neutral = edge.flags & EDGE_NEUTRAL != 0
            neutral2 = edges[edge2].flags & EDGE_NEUTRAL != 0

            if neutral2
              edges[edge2].blue_edge = nil
              edges[edge2].flags &= ~EDGE_NEUTRAL
            elsif neutral
              edge.blue_edge = nil
              edge.flags &= ~EDGE_NEUTRAL
            end
          end

          blue = edge.blue_edge
          if blue
            edge1 = ei
          elsif edge2 >= 0 && !edges[edge2].blue_edge.nil?
            blue = edges[edge2].blue_edge
            edge1 = edge2
            edge2 = ei
          end

          next if edge1 < 0

          e1 = edges.unsafe_fetch(edge1)
          e1.pos = blue.not_nil!.fit
          e1.flags |= EDGE_DONE

          if edge2 >= 0 && edges[edge2].blue_edge.nil?
            align_linked_edge(hints, metrics, dim, edges, edge1, edge2)
            edges[edge2].flags |= EDGE_DONE
          end

          anchor = ei if anchor < 0
        end
      end

      # align all other stem edges
      edges.each_with_index do |edge, ei|
        next if edge.flags & EDGE_DONE != 0

        edge2 = edge.link
        if edge2 < 0
          has_serifs = true
          next
        end

        # this should not happen, but it's better to be safe
        if !edges[edge2].blue_edge.nil?
          align_linked_edge(hints, metrics, dim, edges, edge2, ei)
          edge.flags |= EDGE_DONE
          next
        end

        if anchor < 0
          e2 = edges.unsafe_fetch(edge2)
          org_len = e2.opos &- edge.opos
          cur_len = compute_stem_width(hints, metrics, dim, org_len, 0,
                                       edge.flags, e2.flags)

          if cur_len <= 64
            u_off = 32_i64
            d_off = 32_i64
          else
            u_off = 38_i64
            d_off = 26_i64
          end

          if cur_len < 96
            org_center = edge.opos &+ (org_len >> 1)
            cur_pos1 = (org_center &+ 32) & ~63_i64

            error1 = (org_center &- (cur_pos1 &- u_off)).abs
            error2 = (org_center &- (cur_pos1 &+ d_off)).abs

            cur_pos1 &-= u_off if error1 < error2
            cur_pos1 &+= d_off unless error1 < error2

            edge.pos = cur_pos1 &- cur_len // 2
            e2.pos = edge.pos &+ cur_len
          else
            edge.pos = (edge.opos &+ 32) & ~63_i64
          end

          anchor = ei
          edge.flags |= EDGE_DONE

          align_linked_edge(hints, metrics, dim, edges, ei, edge2)
        else
          a = edges.unsafe_fetch(anchor)
          org_pos = a.pos &+ (edge.opos &- a.opos)
          e2 = edges.unsafe_fetch(edge2)
          org_len = e2.opos &- edge.opos
          org_center = org_pos &+ (org_len >> 1)

          cur_len = compute_stem_width(hints, metrics, dim, org_len, 0,
                                       edge.flags, e2.flags)

          if e2.flags & EDGE_DONE != 0
            edge.pos = e2.pos &- cur_len
          elsif cur_len < 96
            if cur_len <= 64
              u_off = 32_i64
              d_off = 32_i64
            else
              u_off = 38_i64
              d_off = 26_i64
            end

            cur_pos1 = (org_center &+ 32) & ~63_i64

            delta1 = (org_center &- (cur_pos1 &- u_off)).abs
            delta2 = (org_center &- (cur_pos1 &+ d_off)).abs

            cur_pos1 &-= u_off if delta1 < delta2
            cur_pos1 &+= d_off unless delta1 < delta2

            edge.pos = cur_pos1 &- cur_len // 2
            e2.pos = cur_pos1 &+ cur_len // 2
          else
            cur_pos1 = (org_pos &+ 32) & ~63_i64
            delta1 = (cur_pos1 &+ (cur_len >> 1) &- org_center).abs

            cur_pos2 = ((org_pos &+ org_len &+ 32) & ~63_i64) &- cur_len
            delta2 = (cur_pos2 &+ (cur_len >> 1) &- org_center).abs

            edge.pos = delta1 < delta2 ? cur_pos1 : cur_pos2
            e2.pos = edge.pos &+ cur_len
          end

          edge.flags |= EDGE_DONE
          e2.flags |= EDGE_DONE

          if ei > 0 &&
             (top_to_bottom_hinting ? edge.pos > edges[ei - 1].pos
                                    : edge.pos < edges[ei - 1].pos)
            if edge.link >= 0 &&
               (edges[edge.link].pos &- edges[ei - 1].pos).abs > 16
              edge.pos = edges[ei - 1].pos
            end
          end
        end
      end

      # lowercase m symmetry
      if dim == DIMENSION_HORZ && (n_edges == 6 || n_edges == 12)
        if n_edges == 6
          edge1_i = 0
          edge2_i = 2
          edge3_i = 4
        else
          edge1_i = 1
          edge2_i = 5
          edge3_i = 9
        end

        e1 = edges.unsafe_fetch(edge1_i)
        e2 = edges.unsafe_fetch(edge2_i)
        e3 = edges.unsafe_fetch(edge3_i)

        dist1 = e2.opos &- e1.opos
        dist2 = e3.opos &- e2.opos

        span = (dist1 &- dist2).abs

        if span < 8
          delta = e3.pos &- (2_i64 &* e2.pos &- e1.pos)
          e3.pos &-= delta
          e3_linked = e3.link
          if e3_linked >= 0
            edges[e3_linked].pos &-= delta
          end

          if n_edges == 12
            edges[8].pos &-= delta
            edges[11].pos &-= delta
          end

          e3.flags |= EDGE_DONE
          edges[e3_linked].flags |= EDGE_DONE if e3_linked >= 0
        end
      end

      # hint the remaining edges (serifs and single)
      if has_serifs || anchor < 0
        edges.each_with_index do |edge, ei|
          next if edge.flags & EDGE_DONE != 0

          delta = 1000_i64

          if edge.serif >= 0
            delta = (edges[edge.serif].opos &- edge.opos).abs
          end

          if delta < 64 + 16
            align_serif_edge(edges, edge.serif, ei)
          elsif anchor < 0
            edge.pos = (edge.opos &+ 32) & ~63_i64
            anchor = ei
          else
            before = -1
            (ei - 1).downto(0) do |bi|
              if edges[bi].flags & EDGE_DONE != 0
                before = bi
                break
              end
            end

            after = -1
            ((ei + 1)...n_edges).each do |ai|
              if edges[ai].flags & EDGE_DONE != 0
                after = ai
                break
              end
            end

            if before >= 0 && before < ei && after >= 0 && after < n_edges && after > ei
              b = edges.unsafe_fetch(before)
              a = edges.unsafe_fetch(after)
              if a.opos == b.opos
                edge.pos = b.pos
              else
                edge.pos = b.pos &+ Fixed.muldiv(edge.opos &- b.opos,
                                                 a.pos &- b.pos,
                                                 a.opos &- b.opos)
              end
            else
              a = edges.unsafe_fetch(anchor)
              edge.pos = a.pos &+ ((edge.opos &- a.opos &+ 16) & ~31_i64)
            end
          end

          edge.flags |= EDGE_DONE

          if ei > 0 &&
             (top_to_bottom_hinting ? edge.pos > edges[ei - 1].pos
                                    : edge.pos < edges[ei - 1].pos)
            if edge.link >= 0 &&
               (edges[edge.link].pos &- edges[ei - 1].pos).abs > 16
              edge.pos = edges[ei - 1].pos
            end
          end

          if ei + 1 < n_edges &&
             edges[ei + 1].flags & EDGE_DONE != 0 &&
             (top_to_bottom_hinting ? edge.pos < edges[ei + 1].pos
                                    : edge.pos > edges[ei + 1].pos)
            if edge.link >= 0 &&
               (edges[edge.link].pos &- edges[ei - 1].pos).abs > 16
              edge.pos = edges[ei + 1].pos
            end
          end
        end
      end
    end

    # --- af_latin_hints_apply ----------------------------------------------------

    # Returns the hinted (scaled + grid-fitted) outline. `italic' selects
    # the NO_HORIZONTAL scaler flag (af_latin_hints_init).
    def apply(hints : GlyphHints, metrics : LatinMetrics,
              glyph_index : Int32, nonbase : Bool, italic : Bool,
              xs : Array(Int64), ys : Array(Int64), tags : Array(UInt8),
              contours : Array(Int32)) : Nil
      if metrics.dummy
        # af_dummy_hints_apply: scale only
        hints.x_scale = metrics.x_scale
        hints.y_scale = metrics.y_scale
        hints.x_delta = metrics.x_delta
        hints.y_delta = metrics.y_delta
        hints.other_flags = 0
        hints.scaler_flags = 0
        hints.reload(xs, ys, tags, contours, metrics.units_per_em)
        hints.save(xs, ys, tags)
        return
      end

      hints_init(hints, metrics, italic)

      hints.reload(xs, ys, tags, contours, metrics.units_per_em)

      do_horizontal = hints.scaler_flags & SCALER_FLAG_NO_HORIZONTAL == 0
      do_vertical = hints.scaler_flags & SCALER_FLAG_NO_VERTICAL == 0

      if do_horizontal
        laxis = metrics.axis[DIMENSION_HORZ]
        compute_segments(hints, metrics, DIMENSION_HORZ)
        link_segments(hints, metrics, laxis.width_count, DIMENSION_HORZ)
        compute_edges(hints, metrics, DIMENSION_HORZ)
      end

      if do_vertical
        laxis = metrics.axis[DIMENSION_VERT]
        compute_segments(hints, metrics, DIMENSION_VERT)
        link_segments(hints, metrics, laxis.width_count, DIMENSION_VERT)
        compute_edges(hints, metrics, DIMENSION_VERT)

        compute_blue_edges(hints, metrics) unless nonbase
      end

      (0...2).each do |dim|
        next unless (dim == DIMENSION_HORZ && do_horizontal) ||
                    (dim == DIMENSION_VERT && do_vertical)

        hint_edges(hints, metrics, dim)

        hints.align_edge_points(dim)
        hints.align_strong_points(dim)
        hints.align_weak_points(dim)
      end

      hints.save(xs, ys, tags)
    end
  end
end

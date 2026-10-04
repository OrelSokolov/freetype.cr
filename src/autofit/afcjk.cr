# afcjk.cr — a port of FreeType's `src/autofit/afcjk.c': the CJK writing
# system. The blue-zone and stem-width machinery is much simpler than the
# latin one: per-dimension blue zones (vertical AND horizontal), a
# distance-based segment linking with `serif' de-linking for wide stroke
# ends, and the af_hint_normal_stem grid fitter. The segment computation
# reuses the latin machinery (af_cjk_hints_compute_segments calls
# af_latin_hints_compute_segments, then recomputes the round flag from
# successive on-curve points).
#
# AF_CONFIG_OPTION_CJK_BLUE_HANI_VERT is undefined in afcjk.c: the hani
# stringset ends after CJK_BOTTOM (the LEFT/RIGHT entries of
# af_blue_stringsets are compiled out — see afblue_data.cr).
require "./aflatin"
require "./afglobal"

module Autofit
  # AF_BLUE_PROPERTY_CJK_* (afblue.h); CJK_TOP == BLUE_PROPERTY_LATIN_TOP
  BLUE_PROPERTY_CJK_TOP   = 1_u8
  BLUE_PROPERTY_CJK_HORIZ = 2_u8

  # AF_CJK_BLUE_* (afcjk.h); the values coincide with AF_LATIN_BLUE_*,
  # so the shared LatinBlue flags field is reused.
  CJK_BLUE_ACTIVE = (1_u8 << 0)
  CJK_BLUE_TOP    = (1_u8 << 1)
  CJK_BLUE_ADJUSTMENT = (1_u8 << 2)

  CJK_MAX_WIDTHS = 16

  FLAG_CONTROL = FLAG_CONIC | FLAG_CUBIC

  # af_light_mode_max_* (afcjk.c); used by af_hint_normal_stem when the
  # stem adjust flag is off (light mode — outside the NORMAL scope but
  # ported for faithfulness).
  LIGHT_MODE_MAX_HORZ_GAP   = 9
  LIGHT_MODE_MAX_VERT_GAP   = 15
  LIGHT_MODE_MAX_DELTA_ABS  = 14

  # AF_CJKMetricsRec. The axes reuse LatinAxis (identical layout; the
  # blues carry no ascender/descender for CJK). Note that unlike the
  # latin metrics, the CJK scaler never scales widths[].cur (they stay 0
  # — af_cjk_metrics_scale_dim only touches scale/delta and the blue
  # zones) and never rewrites the scaler values.
  class CjkMetrics
    include StyleMetrics

    getter style_class : StyleClass
    getter units_per_em : Int32
    # AF_ScalerRec subset (root.scaler: copied verbatim by scale)
    property x_scale : Int64 = 0
    property y_scale : Int64 = 0
    property x_delta : Int64 = 0
    property y_delta : Int64 = 0
    property ppem : Int32 = 0
    property digits_have_same_width : Bool = false
    property dummy : Bool = false
    property axis : Array(LatinAxis) = [LatinAxis.new, LatinAxis.new]

    def initialize(@style_class : StyleClass, @units_per_em : Int32)
    end

    def latin_constant(c : Int32) : Int64
      c.to_i64! &* @units_per_em // 2048
    end

    def flat_threshold : Int64
      (@units_per_em // 14).to_i64!
    end

    # --- af_cjk_metrics_init --------------------------------------------------

    # af_cjk_metrics_init always succeeds (unlike the latin one, a CJK
    # style with zero blue zones is not disabled).
    def init(face : FontFaceAdapter) : Bool
      init_widths(face)
      init_blues(face)
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

    # af_cjk_metrics_init_widths: basically the latin version — latin
    # segment computation and linking, then stem pairs of mutually
    # linked segments become the widths. The final `stdw' defaults run
    # even when the standard glyph is missing (the C's `Exit:' label
    # sits before that loop).
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
              if num_widths < CJK_MAX_WIDTHS
                ax.widths[num_widths].org = dist
                num_widths += 1
              end
            end

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

    # af_cjk_metrics_init_blues: vertical and horizontal blue zones; a
    # '|' in the blue string switches from overshoot (fill) values to
    # reference (flat) ones.
    def init_blues(face : FontFaceAdapter) : Nil
      stringset_sym = @style_class.stringset.not_nil!
      idx = BLUE_STRINGSETS[stringset_sym]

      loop do
        str_off, props = STRINGSETS[idx]
        break if str_off == BLUE_STRING_MAX
        idx += 1

        is_horiz = (props & BLUE_PROPERTY_CJK_HORIZ) != 0
        is_top = (props & BLUE_PROPERTY_CJK_TOP) != 0
        ax = axis[is_horiz ? DIMENSION_HORZ : DIMENSION_VERT]

        fills = [] of Int64
        flats = [] of Int64
        fill = true

        BLUE_STRINGS[str_off].split(' ').each do |ch|
          next if ch.empty?
          if ch == "|"
            fill = false
            next
          end

          cp = ch[0].ord
          gindex = face.glyph_index(cp.to_i32)
          next if gindex == 0

          outline = face.load_unscaled(gindex)
          next if outline.nil?
          xs, ys, tags, contours = outline
          next if xs.size <= 2

          best_point = -1
          best_pos = 0_i64

          last_i = -1
          contours.each do |cend|
            first_i = last_i + 1
            last_i = cend
            next if last_i <= first_i # single-point contours

            (first_i..last_i).each do |pp|
              coord = is_horiz ? xs.unsafe_fetch(pp) : ys.unsafe_fetch(pp)
              if is_top # top (vert) / right (horiz)
                if best_point < 0 || coord > best_pos
                  best_point = pp
                  best_pos = coord
                end
              else # bottom (vert) / left (horiz)
                if best_point < 0 || coord < best_pos
                  best_point = pp
                  best_pos = coord
                end
              end
            end
          end

          (fill ? fills : flats) << best_pos
        end

        next if fills.empty? && flats.empty?

        Autofit.sort_pos(fills)
        Autofit.sort_pos(flats)

        blue = LatinBlue.new
        ax.blues << blue

        if flats.empty?
          blue.ref.org = blue.shoot.org = fills[fills.size // 2]
        elsif fills.empty?
          blue.ref.org = blue.shoot.org = flats[flats.size // 2]
        else
          blue.ref.org = fills[fills.size // 2]
          blue.shoot.org = flats[flats.size // 2]
        end

        # make sure blue_ref >= blue_shoot for top/right or vice versa
        if blue.shoot.org != blue.ref.org
          ref = blue.ref.org
          shoot = blue.shoot.org
          under_ref = shoot < ref
          if is_top != under_ref
            blue.ref.org = blue.shoot.org = (shoot &+ ref).tdiv(2)
          end
        end

        blue.flags |= CJK_BLUE_TOP if is_top
      end
    end

    # af_cjk_metrics_check_digits: identical to the latin version.
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

    # --- af_cjk_metrics_scale ---------------------------------------------------

    # the whole scaler is copied (the CJK scale values are not modified,
    # contrary to the latin metrics)
    def scale(x_scale : Int64, y_scale : Int64,
              x_delta : Int64, y_delta : Int64, ppem : Int32) : Nil
      @x_scale = x_scale
      @y_scale = y_scale
      @x_delta = x_delta
      @y_delta = y_delta
      @ppem = ppem

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

      ax.scale = sc
      ax.delta = delta

      # scale the blue zones (both dimensions; the widths are NOT
      # scaled — widths[].cur stays 0, exactly as the C)
      ax.blues.each do |blue|
        blue.ref.cur = Fixed.mulfix(blue.ref.org, sc) &+ delta
        blue.ref.fit = blue.ref.cur
        blue.shoot.cur = Fixed.mulfix(blue.shoot.org, sc) &+ delta
        blue.shoot.fit = blue.shoot.cur
        blue.flags &= ~CJK_BLUE_ACTIVE

        # a blue zone is only active if it is less than 3/4 pixels tall
        dist = Fixed.mulfix(blue.ref.org &- blue.shoot.org, sc)
        next unless dist <= 48 && dist >= -48

        blue.ref.fit = (blue.ref.cur &+ 32) & ~63_i64

        # shoot is under shoot for cjk
        delta1 = Fixed.divfix(blue.ref.fit, sc) &- blue.shoot.org
        delta2 = delta1.abs
        delta2 = Fixed.mulfix(delta2, sc)
        delta2 = 0_i64 if delta2 < 32
        delta2 = (delta2 &+ 32) & ~63_i64 unless delta2 < 32
        delta2 = -delta2 if delta1 < 0

        blue.shoot.fit = blue.ref.fit &- delta2

        blue.flags |= CJK_BLUE_ACTIVE
      end
    end
  end

  # The CJK algorithm functions, operating on GlyphHints.
  module Cjk
    extend self

    # AF_SEGMENT_DIST
    private def segment_dist(segs : Array(Segment), a : Int32, b : Int32) : Int64
      pa = segs.unsafe_fetch(a).pos.to_i64!
      pb = segs.unsafe_fetch(b).pos.to_i64!
      pa > pb ? pa &- pb : pb &- pa
    end

    # --- af_cjk_hints_compute_segments ---------------------------------------

    # Latin segment computation, then a segment is round if it doesn't
    # have successive on-curve points.
    def compute_segments(hints : GlyphHints, metrics : StyleMetrics,
                         dim : Int32) : Nil
      Latin.compute_segments(hints, metrics, dim)

      points = hints.points
      hints.axis[dim].segments.each do |seg|
        pt_i = seg.first
        last_i = seg.last
        f0 = points.unsafe_fetch(pt_i).flags & FLAG_CONTROL

        seg.flags &= ~EDGE_ROUND

        while pt_i != last_i
          pt_i = points.unsafe_fetch(pt_i).next
          f1 = points.unsafe_fetch(pt_i).flags & FLAG_CONTROL

          break if f0 == 0 && f1 == 0

          seg.flags |= EDGE_ROUND if pt_i == last_i
          f0 = f1
        end
      end
    end

    # --- af_cjk_hints_link_segments --------------------------------------------

    def link_segments(hints : GlyphHints, metrics : StyleMetrics,
                      dim : Int32) : Nil
      ax = hints.axis[dim]
      segs = ax.segments

      len_threshold = metrics.latin_constant(8)

      dist_threshold = Fixed.divfix(64_i64 &* 3,
                                    dim == DIMENSION_HORZ ? hints.x_scale : hints.y_scale)

      # now compare each segment to the others
      segs.each_with_index do |seg1, si1|
        next if seg1.dir != ax.major_dir

        segs.each_with_index do |seg2, si2|
          next unless si2 != si1 && seg1.dir &+ seg2.dir == 0

          dist = seg2.pos.to_i64! &- seg1.pos.to_i64!
          next if dist < 0

          min = seg1.min_coord.to_i64!
          max = seg1.max_coord.to_i64!
          min = seg2.min_coord.to_i64! if min < seg2.min_coord
          max = seg2.max_coord.to_i64! if max > seg2.max_coord

          len = max &- min
          next unless len >= len_threshold

          if dist &* 8 < seg1.score &* 9 &&
             (dist &* 8 < seg1.score &* 7 || seg1.len < len)
            seg1.score = dist
            seg1.len = len
            seg1.link = si2
          end

          if dist &* 8 < seg2.score &* 9 &&
             (dist &* 8 < seg2.score &* 7 || seg2.len < len)
            seg2.score = dist
            seg2.len = len
            seg2.link = si1
          end
        end
      end

      # now compute the `serif' segments: in Hanzi, some strokes are
      # wider on one or both of the ends; either identify the stems on
      # the ends as serifs or remove the linkage, depending on the
      # length of the stems.
      segs.each_with_index do |seg1, si1|
        link1_i = seg1.link
        next if link1_i < 0
        link1 = segs.unsafe_fetch(link1_i)
        next if link1.link != si1 || link1.pos <= seg1.pos
        next if seg1.score >= dist_threshold

        segs.each_with_index do |seg2, si2|
          next if seg2.pos > seg1.pos || si1 == si2

          link2_i = seg2.link
          next if link2_i < 0
          link2 = segs.unsafe_fetch(link2_i)
          next if link2.link != si2 || link2.pos < link1.pos
          next if seg1.pos == seg2.pos && link1.pos == link2.pos
          next if seg2.score <= seg1.score || seg1.score &* 4 <= seg2.score

          # seg2 < seg1 < link1 < link2

          if seg1.len >= seg2.len &* 3
            segs.each do |seg|
              link = seg.link
              if link == si2
                seg.link = -1
                seg.serif = link1_i
              elsif link == link2_i
                seg.link = -1
                seg.serif = si1
              end
            end
          else
            seg1.link = -1
            link1.link = -1
            break
          end
        end
      end

      segs.each_with_index do |seg1, si1|
        seg2_i = seg1.link
        next if seg2_i < 0

        seg2 = segs.unsafe_fetch(seg2_i)
        if seg2.link != si1
          seg1.link = -1

          seg1.serif = seg2.link if seg2.score < dist_threshold ||
                                     seg1.score < seg2.score &* 4
        end
      end
    end

    # --- af_cjk_hints_compute_edges ---------------------------------------------

    def compute_edges(hints : GlyphHints, metrics : StyleMetrics,
                      dim : Int32) : Nil
      ax = hints.axis[dim]
      laxis = metrics.axis[dim]
      segs = ax.segments

      ax.edges.clear

      scale = dim == DIMENSION_HORZ ? hints.x_scale : hints.y_scale

      # af_cjk_hints_compute_edges: only the overscaled threshold gets
      # the DivFix treatment (the latin version re-scales in both cases)
      edt = Fixed.mulfix(laxis.edge_distance_threshold, scale)
      edt = if edt > 64_i64 // 4
        Fixed.divfix(64_i64 // 4, scale)
      else
        laxis.edge_distance_threshold
      end

      segs.each_with_index do |seg, si|
        found = -1
        best = 0xFFFF_i64

        # look for an edge corresponding to the segment
        ax.edges.each_with_index do |edge, ee|
          next if edge.dir != seg.dir

          dist = seg.pos.to_i64! &- edge.fpos
          dist = -dist if dist < 0

          next unless dist < edt && dist < best

          # check whether all linked segments of the candidate edge can
          # make a single edge
          link = seg.link
          if link >= 0
            dist2 = 0_i64
            seg1_i = edge.first
            loop do
              seg1 = segs.unsafe_fetch(seg1_i)
              link1 = seg1.link
              if link1 >= 0
                dist2 = segment_dist(segs, link, link1)
                break if dist2 >= edt
              end
              seg1_i = seg1.edge_next
              break if seg1_i == edge.first
            end
            next if dist2 >= edt
          end

          best = dist
          found = ee
        end

        if found < 0
          # insert a new edge in the list, sorted according to position
          ei = ax.new_edge(seg.pos.to_i32!, seg.dir, false)
          edge = ax.edges.unsafe_fetch(ei)

          edge.first = si
          edge.last = si
          edge.dir = seg.dir
          edge.fpos = seg.pos
          edge.opos = Fixed.mulfix(seg.pos.to_i64!, scale)
          edge.pos = edge.opos
          seg.edge_next = si
        else
          # simply add the segment to the edge's list
          edge = ax.edges.unsafe_fetch(found)
          seg.edge_next = edge.first
          segs.unsafe_fetch(edge.last).edge_next = si
          edge.last = si
        end
      end

      # set the `edge' field in each segment
      ax.edges.each_with_index do |edge, ei|
        si = edge.first
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

          # check for roundness of segment
          if seg.flags & EDGE_ROUND != 0
            is_round += 1
          else
            is_straight += 1
          end

          # if seg->serif is set, seg->link must be ignored
          is_serif = seg.serif >= 0 &&
                     segs.unsafe_fetch(seg.serif).edge != ei

          if seg.link >= 0 || is_serif
            seg2_i = is_serif ? seg.serif : seg.link
            edge2_i = is_serif ? edge.serif : edge.link

            if edge2_i >= 0
              edge2 = ax.edges.unsafe_fetch(edge2_i)

              edge_delta = edge.fpos.to_i64! &- edge2.fpos
              edge_delta = -edge_delta if edge_delta < 0

              seg_delta = segment_dist(segs, si, seg2_i)

              edge2_i = segs.unsafe_fetch(seg2_i).edge if seg_delta < edge_delta
            else
              edge2_i = segs.unsafe_fetch(seg2_i).edge
            end

            if is_serif
              edge.serif = edge2_i
              ax.edges.unsafe_fetch(edge2_i).flags |= EDGE_SERIF if edge2_i >= 0
            else
              edge.link = edge2_i
            end
          end

          si = seg.edge_next
          break if si == edge.first
        end

        # set the round/straight flags
        edge.flags = EDGE_NORMAL
        edge.flags |= EDGE_ROUND if is_round > 0 && is_round >= is_straight

        # get rid of serifs if link is set
        edge.serif = -1 if edge.serif >= 0 && edge.link >= 0
      end
    end

    # --- af_cjk_hints_detect_features ------------------------------------------

    def detect_features(hints : GlyphHints, metrics : StyleMetrics,
                        dim : Int32) : Nil
      compute_segments(hints, metrics, dim)
      link_segments(hints, metrics, dim)
      compute_edges(hints, metrics, dim)
    end

    # --- af_cjk_hints_compute_blue_edges ---------------------------------------

    # Compute all edges which lie within blue zones (per dimension,
    # unlike the latin blue-edge pass).
    def compute_blue_edges(hints : GlyphHints, metrics : CjkMetrics,
                           dim : Int32) : Nil
      ax = hints.axis[dim]
      cjk = metrics.axis[dim]
      scale = cjk.scale

      # the initial threshold as a fraction of the EM size,
      # at most 1/2 pixel
      best_dist0 = Fixed.mulfix(metrics.units_per_em.to_i64! // 40, scale)
      best_dist0 = 64_i64 // 2 if best_dist0 > 64_i64 // 2

      ax.edges.each do |edge|
        best_blue : Width? = nil
        best_dist = best_dist0

        cjk.blues.each do |blue|
          # skip inactive blue zones (i.e. those that are too small)
          next unless blue.flags & CJK_BLUE_ACTIVE != 0

          # a top/right zone must be against the major direction, a
          # bottom/left zone in the major direction
          is_top_right_blue = (blue.flags & CJK_BLUE_TOP) != 0
          is_major_dir = edge.dir == ax.major_dir

          next if is_top_right_blue == is_major_dir

          # compare the edge to the closest blue zone type
          fpos = edge.fpos.to_i64!
          compare = (fpos &- blue.ref.org).abs > (fpos &- blue.shoot.org).abs ? blue.shoot : blue.ref

          dist = (fpos &- compare.org).abs
          dist = Fixed.mulfix(dist, scale)
          if dist < best_dist
            best_dist = dist
            best_blue = compare
          end
        end

        edge.blue_edge = best_blue unless best_blue.nil?
      end
    end

    # --- af_cjk_hints_init -------------------------------------------------------

    def hints_init(hints : GlyphHints, metrics : CjkMetrics) : Nil
      # af_glyph_hints_rescale resets the scaler flags, then the CJK
      # init adds NO_ADVANCE (the advance fixups are disabled for CJK)
      hints.scaler_flags = SCALER_FLAG_NO_ADVANCE

      hints.x_scale = metrics.axis[DIMENSION_HORZ].scale
      hints.x_delta = metrics.axis[DIMENSION_HORZ].delta
      hints.y_scale = metrics.axis[DIMENSION_VERT].scale
      hints.y_delta = metrics.axis[DIMENSION_VERT].delta

      # FT_RENDER_MODE_NORMAL: no snapping flags and no mono flag, but
      # stem adjustment on
      hints.other_flags = LATIN_HINTS_STEM_ADJUST
    end

    # --- stem width computation ----------------------------------------------------

    # af_cjk_compute_stem_width
    def compute_stem_width(hints : GlyphHints, metrics : CjkMetrics,
                           dim : Int32, width : Int64,
                           base_flags : UInt8, stem_flags : UInt8) : Int64
      axis = metrics.axis[dim]
      dist = width
      sign = false
      vertical = dim == DIMENSION_VERT

      return width if hints.other_flags & LATIN_HINTS_STEM_ADJUST == 0

      if dist < 0
        dist = -width
        sign = true
      end

      horz_snap = hints.other_flags & LATIN_HINTS_HORZ_SNAP != 0
      vert_snap = hints.other_flags & LATIN_HINTS_VERT_SNAP != 0

      if (vertical && !vert_snap) || (!vertical && !horz_snap)
        # smooth hinting process: very lightly quantize the stem width

        if axis.width_count > 0
          w0 = axis.widths[0].cur
          if (dist &- w0).abs < 40
            dist = w0
            dist = 48_i64 if dist < 48

            dist = -dist if sign
            return dist # goto Done_Width
          end
        end

        if dist < 54
          dist += (54 &- dist).tdiv(2)
        elsif dist < 3 &* 64
          delta = dist & 63
          dist &= ~63_i64

          if delta < 10
            dist += delta
          elsif delta < 22
            dist += 10
          elsif delta < 42
            dist += delta
          elsif delta < 54
            dist += 54
          else
            dist += delta
          end
        end
      else
        # strong hinting process: snap the stem width to integer pixels

        dist = Latin.snap_width(axis.widths, axis.width_count, dist)

        if vertical
          # in the case of vertical hinting, always round the stem
          # heights to integer pixels
          dist = dist >= 64 ? (dist &+ 16) & ~63_i64 : 64_i64
        else
          if hints.other_flags & LATIN_HINTS_MONO != 0
            # monochrome horizontal hinting
            dist = dist < 64 ? 64_i64 : (dist &+ 32) & ~63_i64
          else
            # anti-aliased horizontal hinting: strengthen small stems,
            # round 1..2 pixel stems to an integer, otherwise round
            if dist < 48
              dist = (dist &+ 64) >> 1
            elsif dist < 128
              dist = (dist &+ 22) & ~63_i64
            else
              dist = (dist &+ 32) & ~63_i64
            end
          end
        end
      end

      dist = -dist if sign
      dist
    end

    # af_cjk_align_linked_edge: align one stem edge relative to the
    # previous stem edge.
    def align_linked_edge(hints : GlyphHints, metrics : CjkMetrics,
                          dim : Int32, edges : Array(Edge),
                          base_i : Int32, stem_i : Int32) : Nil
      base_edge = edges.unsafe_fetch(base_i)
      stem_edge = edges.unsafe_fetch(stem_i)

      dist = stem_edge.opos &- base_edge.opos

      fitted_width = compute_stem_width(hints, metrics, dim, dist,
                                        base_edge.flags, stem_edge.flags)

      stem_edge.pos = base_edge.pos &+ fitted_width
    end

    # --- af_hint_normal_stem ------------------------------------------------------

    def hint_normal_stem(hints : GlyphHints, metrics : CjkMetrics,
                         dim : Int32, edges : Array(Edge),
                         ei : Int32, ei2 : Int32, anchor : Int64) : Int64
      edge = edges.unsafe_fetch(ei)
      edge2 = edges.unsafe_fetch(ei2)

      threshold = 64_i64
      stem_adjust = hints.other_flags & LATIN_HINTS_STEM_ADJUST != 0

      unless stem_adjust
        if edge.flags & EDGE_ROUND != 0 && edge2.flags & EDGE_ROUND != 0
          threshold = dim == DIMENSION_VERT ? 64 - LIGHT_MODE_MAX_HORZ_GAP : 64 - LIGHT_MODE_MAX_VERT_GAP
        else
          threshold = dim == DIMENSION_VERT ? 64 - LIGHT_MODE_MAX_HORZ_GAP // 3 : 64 - LIGHT_MODE_MAX_VERT_GAP // 3
        end
        threshold = threshold.to_i64!
      end

      org_len = edge2.opos &- edge.opos
      cur_len = compute_stem_width(hints, metrics, dim, org_len,
                                   edge.flags, edge2.flags)

      org_center = (edge.opos &+ edge2.opos).tdiv(2) &+ anchor
      cur_pos1 = org_center &- cur_len.tdiv(2)
      cur_pos2 = cur_pos1 &+ cur_len
      d_off1 = cur_pos1 & 63
      d_off2 = cur_pos2 & 63
      u_off1 = 64_i64 &- d_off1
      u_off2 = 64_i64 &- d_off2
      delta = 0_i64

      if d_off1 != 0 && d_off2 != 0
        if cur_len <= threshold
          if d_off2 < cur_len
            delta = u_off1 <= d_off2 ? u_off1 : -d_off2
          end
        elsif threshold >= 64 ||
              !(d_off1 >= threshold || u_off1 >= threshold ||
                d_off2 >= threshold || u_off2 >= threshold)
          offset = cur_len & 63

          if offset < 32
            unless u_off1 <= offset || d_off2 <= offset
              d_off1 = threshold &- u_off1
              u_off1 = u_off1 &- offset
              u_off2 = threshold &- d_off2
              d_off2 = d_off2 &- offset

              u_off1 = -d_off1 if d_off1 <= u_off1
              u_off2 = -d_off2 if d_off2 <= u_off2

              delta = u_off1.abs <= u_off2.abs ? u_off1 : u_off2
            end
          else
            offset = 64_i64 &- threshold

            d_off1 = threshold &- u_off1
            u_off1 = u_off1 &- offset
            u_off2 = threshold &- d_off2
            d_off2 = d_off2 &- offset

            u_off1 = -d_off1 if d_off1 <= u_off1
            u_off2 = -d_off2 if d_off2 <= u_off2

            delta = u_off1.abs <= u_off2.abs ? u_off1 : u_off2
          end
        end
      end

      unless stem_adjust
        if delta > LIGHT_MODE_MAX_DELTA_ABS
          delta = LIGHT_MODE_MAX_DELTA_ABS.to_i64!
        elsif delta < -LIGHT_MODE_MAX_DELTA_ABS
          delta = -LIGHT_MODE_MAX_DELTA_ABS.to_i64!
        end
      end

      cur_pos1 &+= delta

      if edge.opos < edge2.opos
        edge.pos = cur_pos1
        edge2.pos = cur_pos1 &+ cur_len
      else
        edge.pos = cur_pos1 &+ cur_len
        edge2.pos = cur_pos1
      end

      delta
    end

    # --- af_cjk_hint_edges ---------------------------------------------------------

    def hint_edges(hints : GlyphHints, metrics : CjkMetrics,
                   dim : Int32) : Nil
      ax = hints.axis[dim]
      edges = ax.edges
      n_edges = edges.size

      anchor = -1
      delta = 0_i64
      skipped = 0
      has_last_stem = false
      last_stem_pos = 0_i64

      # we begin by aligning all stems relative to the blue zone
      edges.each_with_index do |edge, ei|
        next if edge.flags & EDGE_DONE != 0

        blue = edge.blue_edge
        edge1_i = -1
        edge2_i = edge.link

        if blue
          edge1_i = ei
        elsif edge2_i >= 0 && !edges[edge2_i].blue_edge.nil?
          blue = edges[edge2_i].blue_edge
          edge1_i = edge2_i
          edge2_i = ei
        end

        next if edge1_i < 0

        edge1 = edges.unsafe_fetch(edge1_i)
        edge1.pos = blue.not_nil!.fit
        edge1.flags |= EDGE_DONE

        if edge2_i >= 0 && edges[edge2_i].blue_edge.nil?
          align_linked_edge(hints, metrics, dim, edges, edge1_i, edge2_i)
          edges[edge2_i].flags |= EDGE_DONE
        end

        anchor = ei if anchor < 0
      end

      # now we align all stem edges
      edges.each_with_index do |edge, ei|
        next if edge.flags & EDGE_DONE != 0

        # skip all non-stem edges
        edge2_i = edge.link
        if edge2_i < 0
          skipped += 1
          next
        end

        # some CJK characters have so many stems that the hinter is
        # likely to merge two adjacent ones: if either edge of a stem
        # is too close to the previous one, interpolate its location
        # at the end instead
        if has_last_stem &&
           (edge.pos < last_stem_pos &+ 64 ||
            edges[edge2_i].pos < last_stem_pos &+ 64)
          skipped += 1
          next
        end

        # this should not happen, but it's better to be safe
        if !edges[edge2_i].blue_edge.nil?
          align_linked_edge(hints, metrics, dim, edges, edge2_i, ei)
          edge.flags |= EDGE_DONE
          next
        end

        if edge2_i < ei
          align_linked_edge(hints, metrics, dim, edges, edge2_i, ei)
          edge.flags |= EDGE_DONE

          # we rarely reach here; usually the two edges belonging to
          # one stem are marked as DONE together
          has_last_stem = true
          last_stem_pos = edge.pos
          next
        end

        if dim != DIMENSION_VERT && anchor < 0
          delta = hint_normal_stem(hints, metrics, dim, edges, ei, edge2_i, 0)
        else
          # the C ignores the return value here: `delta' keeps the
          # first stem's shift for all subsequent stems
          hint_normal_stem(hints, metrics, dim, edges, ei, edge2_i, delta)
        end

        anchor = ei
        edge.flags |= EDGE_DONE
        edges[edge2_i].flags |= EDGE_DONE
        has_last_stem = true
        last_stem_pos = edges[edge2_i].pos
      end

      # make sure that lowercase m's maintain their symmetry
      if dim == DIMENSION_HORZ && (n_edges == 6 || n_edges == 12)
        edge1_i = n_edges == 6 ? 0 : 1
        edge2_i = n_edges == 6 ? 2 : 5
        edge3_i = n_edges == 6 ? 4 : 9

        e1 = edges.unsafe_fetch(edge1_i)
        e2 = edges.unsafe_fetch(edge2_i)
        e3 = edges.unsafe_fetch(edge3_i)

        dist1 = e2.opos &- e1.opos
        dist2 = e3.opos &- e2.opos

        span = (dist1 &- dist2).abs

        if e1.link == edge1_i + 1 && e2.link == edge2_i + 1 &&
           e3.link == edge3_i + 1 && span < 8
          delta = e3.pos &- (2_i64 &* e2.pos &- e1.pos)
          e3.pos &-= delta
          if e3.link >= 0
            edges[e3.link].pos &-= delta
          end

          # move the serifs along with the stem
          if n_edges == 12
            edges[8].pos &-= delta
            edges[11].pos &-= delta
          end

          e3.flags |= EDGE_DONE
          edges[e3.link].flags |= EDGE_DONE if e3.link >= 0
        end
      end

      return if skipped == 0

      # now hint the remaining edges (serifs and single)
      edges.each_with_index do |edge, ei|
        next if edge.flags & EDGE_DONE != 0

        if edge.serif >= 0
          Latin.align_serif_edge(edges, edge.serif, ei)
          edge.flags |= EDGE_DONE
          skipped -= 1
        end
      end

      return if skipped == 0

      edges.each_with_index do |edge, ei|
        next if edge.flags & EDGE_DONE != 0

        before = ei
        after = ei

        before -= 1
        while before >= 0
          break if edges[before].flags & EDGE_DONE != 0
          before -= 1
        end

        after += 1
        while after < n_edges
          break if edges[after].flags & EDGE_DONE != 0
          after += 1
        end

        next unless before >= 0 || after < n_edges

        if before < 0
          Latin.align_serif_edge(edges, after, ei)
        elsif after >= n_edges
          Latin.align_serif_edge(edges, before, ei)
        elsif edges[after].fpos == edges[before].fpos
          edge.pos = edges[before].pos
        else
          edge.pos = edges[before].pos &+
                     Fixed.muldiv(edge.fpos.to_i64! &- edges[before].fpos,
                                  edges[after].pos &- edges[before].pos,
                                  edges[after].fpos.to_i64! &- edges[before].fpos)
        end
      end
    end

    # --- af_cjk_align_edge_points ------------------------------------------------

    def align_edge_points(hints : GlyphHints, dim : Int32) : Nil
      ax = hints.axis[dim]
      segs = ax.segments
      points = hints.points

      snapping = (dim == DIMENSION_HORZ &&
                  hints.other_flags & LATIN_HINTS_HORZ_SNAP != 0) ||
                 (dim == DIMENSION_VERT &&
                  hints.other_flags & LATIN_HINTS_VERT_SNAP != 0)

      ax.edges.each do |edge|
        delta = edge.pos &- edge.opos unless snapping

        seg_i = edge.first
        loop do
          seg = segs.unsafe_fetch(seg_i)

          point_i = seg.first
          loop do
            point = points.unsafe_fetch(point_i)
            if dim == DIMENSION_HORZ
              if snapping
                point.x = edge.pos
              else
                point.x &+= delta.not_nil!
              end
              point.flags |= FLAG_TOUCH_X
            else
              if snapping
                point.y = edge.pos
              else
                point.y &+= delta.not_nil!
              end
              point.flags |= FLAG_TOUCH_Y
            end

            break if point_i == seg.last
            point_i = point.next
          end

          seg_i = seg.edge_next
          break if seg_i == edge.first
        end
      end
    end

    # --- af_cjk_hints_apply ---------------------------------------------------------

    # Apply the complete hinting algorithm to a CJK glyph: returns the
    # hinted (scaled + grid-fitted) outline.
    def apply(hints : GlyphHints, metrics : CjkMetrics,
              xs : Array(Int64), ys : Array(Int64), tags : Array(UInt8),
              contours : Array(Int32)) : Nil
      hints_init(hints, metrics)

      hints.reload(xs, ys, tags, contours, metrics.units_per_em)

      do_horizontal = hints.scaler_flags & SCALER_FLAG_NO_HORIZONTAL == 0
      do_vertical = hints.scaler_flags & SCALER_FLAG_NO_VERTICAL == 0

      # analyze glyph outline
      if do_horizontal
        detect_features(hints, metrics, DIMENSION_HORZ)
        compute_blue_edges(hints, metrics, DIMENSION_HORZ)
      end

      if do_vertical
        detect_features(hints, metrics, DIMENSION_VERT)
        compute_blue_edges(hints, metrics, DIMENSION_VERT)
      end

      # grid-fit the outline
      (0...2).each do |dim|
        next unless (dim == DIMENSION_HORZ && do_horizontal) ||
                    (dim == DIMENSION_VERT && do_vertical)

        hint_edges(hints, metrics, dim)
        align_edge_points(hints, dim)
        hints.align_strong_points(dim)
        hints.align_weak_points(dim)
      end

      hints.save(xs, ys, tags)
    end
  end
end

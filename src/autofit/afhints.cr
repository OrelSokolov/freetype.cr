# afhints.cr — a port of the shared auto-hinter hint machinery from
# FreeType's `src/autofit/afhints.c' (+ the `ft_corner_is_flat' /
# `FT_HYPOT' helpers from ftcalc.c and `FT_Outline_Get_Orientation'
# from ftoutln.c). Segments, edges and points reference each other by
# index into the hints' arrays (the C uses pointers into contiguous
# buffers with pointer arithmetic; the numeric semantics are kept
# identical, including the 16-bit fields of AF_SegmentRec/AF_EdgeRec
# and the 8-bit direction codes).
require "../tt/loader" # TT::Fixed fixed-point helpers

module Autofit
  VERSION = "2.13.3"

  # The fixed-point helpers shared with the bytecode loader (FT_MulFix and
  # friends, TT::Fixed): the port spells them the way afhints.c does.
  Fixed = ::TT::Fixed

  # --- AF_Direction (values: opposite dirs sum to zero) -------------------

  DIR_NONE  =  4_i8
  DIR_RIGHT =  1_i8
  DIR_LEFT  = -1_i8
  DIR_UP    =  2_i8
  DIR_DOWN  = -2_i8

  DIMENSION_HORZ = 0
  DIMENSION_VERT = 1

  # --- point flags ---------------------------------------------------------

  FLAG_CONIC = (1_u16 << 0)
  FLAG_CUBIC = (1_u16 << 1)
  # AF_FLAG_CONTROL = FLAG_CONIC | FLAG_CUBIC
  FLAG_TOUCH_X = (1_u16 << 2)
  FLAG_TOUCH_Y = (1_u16 << 3)
  FLAG_WEAK_INTERPOLATION = (1_u16 << 4)
  FLAG_NEAR = (1_u16 << 5)

  # --- edge/segment flags --------------------------------------------------

  EDGE_NORMAL = 0_u8
  EDGE_ROUND  = (1_u8 << 0)
  EDGE_SERIF  = (1_u8 << 1)
  EDGE_DONE   = (1_u8 << 2)
  EDGE_NEUTRAL = (1_u8 << 3)

  # AF_WidthRec: an entry of the width/blue tables. A class (reference
  # semantics): the C mutates width/blue records in place through the
  # table arrays, and Crystal struct elements are copied on such writes.
  class Width
    property org : Int64 # original position/width in font units
    property cur : Int64 # current/scaled position/width
    property fit : Int64 # current/fitted position/width

    def initialize(@org = 0_i64, @cur = 0_i64, @fit = 0_i64)
    end
  end

  # AF_PointRec (next/prev are indices into GlyphHints#points).
  class AfPoint
    property flags : UInt16 = 0_u16
    property in_dir : Int8 = DIR_NONE
    property out_dir : Int8 = DIR_NONE

    property ox : Int64 = 0 # original, scaled position
    property oy : Int64 = 0
    property fx : Int16 = 0 # original, unscaled position (font units)
    property fy : Int16 = 0
    property x : Int64 = 0 # current position
    property y : Int64 = 0
    property u : Int64 = 0 # current (x,y)/(y,x); index delta during reload
    property v : Int64 = 0

    property next : Int32 = -1
    property prev : Int32 = -1
  end

  # AF_SegmentRec (edge/link/serif/first/last are indices).
  class Segment
    property flags : UInt8 = 0_u8
    property dir : Int8 = 0_i8
    property pos : Int16 = 0
    property delta : Int16 = 0
    property min_coord : Int16 = 0
    property max_coord : Int16 = 0
    property height : Int16 = 0

    property edge : Int32 = -1
    property edge_next : Int32 = -1

    property link : Int32 = -1
    property serif : Int32 = -1
    property score : Int64 = 0
    property len : Int64 = 0

    property first : Int32 = -1
    property last : Int32 = -1

    def copy_from(other : Segment) : Nil
      @flags = other.flags
      @dir = other.dir
      @pos = other.pos
      @delta = other.delta
      @min_coord = other.min_coord
      @max_coord = other.max_coord
      @height = other.height
      @edge = other.edge
      @edge_next = other.edge_next
      @link = other.link
      @serif = other.serif
      @score = other.score
      @len = other.len
      @first = other.first
      @last = other.last
    end
  end

  # AF_EdgeRec (blue_edge is a copy of a width; C stores a pointer into
  # the metrics' blue table — copies keep the C values read through it).
  class Edge
    property fpos : Int16 = 0 # original, unscaled position
    property opos : Int64 = 0 # original, scaled position
    property pos : Int64 = 0  # current position

    property flags : UInt8 = 0_u8
    property dir : Int8 = 0_i8
    property scale : Int64 = 0 # 16.16, for interpolation between edges

    property blue_edge : Width?
    property link : Int32 = -1
    property serif : Int32 = -1
    property score : Int32 = 0

    property first : Int32 = -1 # first/last segment indices
    property last : Int32 = -1
  end

  class AxisHints
    property segments : Array(Segment) = [] of Segment
    property edges : Array(Edge) = [] of Edge
    property major_dir : Int8 = DIR_UP

    def reset
      segments.clear
      edges.clear
    end

    # af_axis_hints_new_segment: index of a fresh segment.
    def new_segment : Int32
      segments << Segment.new
      segments.size - 1
    end

    # af_axis_hints_new_edge: index of a new edge inserted sorted by
    # `fpos' (the C shifts array entries; the resulting order is what
    # matters — the equal-position tie-break keeps the major direction
    # last).
    def new_edge(fpos : Int32, dir : Int8, top_to_bottom_hinting : Bool) : Int32
      edge = Edge.new

      idx = edges.size
      while idx > 0
        prev = edges.unsafe_fetch(idx - 1)
        break if top_to_bottom_hinting ? (prev.fpos > fpos) : (prev.fpos < fpos)
        break if prev.fpos == fpos && dir == major_dir
        idx -= 1
      end
      edges.insert(idx, edge)
      edge.fpos = fpos.to_i16!
      edge.dir = dir
      idx
    end
  end

  # --- small helpers -------------------------------------------------------

  def self.ft_msb(v : UInt32) : Int32
    raise "msb(0)" if v == 0
    31 - v.leading_zeros_count.to_i32
  end

  # FT_HYPOT (integer approximation, ftobjs.h): |x| + 3/8 |y| of the
  # larger/smaller pair.
  def self.hypot(x : Int64, y : Int64) : Int64
    x = x.abs
    y = y.abs
    x > y ? x + ((3 &* y) >> 3) : y + ((3 &* x) >> 3)
  end

  # ft_corner_is_flat (ftcalc.c).
  def self.corner_is_flat(in_x : Int64, in_y : Int64,
                          out_x : Int64, out_y : Int64) : Bool
    ax = in_x &+ out_x
    ay = in_y &+ out_y

    d_in = hypot(in_x, in_y)
    d_out = hypot(out_x, out_y)
    d_hypot = hypot(ax, ay)

    (d_in &+ d_out &- d_hypot) < (d_hypot >> 4)
  end

  # af_sort_pos: insertion sort ascending.
  def self.sort_pos(table : Array(Int64)) : Nil
    (1...table.size).each do |i|
      j = i
      while j > 0
        break if table.unsafe_fetch(j) >= table.unsafe_fetch(j - 1)
        table.swap(j, j - 1)
        j -= 1
      end
    end
  end

  # af_sort_and_quantize_widths: sort by `org', then average clusters
  # no wider than `threshold' and squeeze out the zeros.
  def self.sort_and_quantize_widths(table : Array(Width), threshold : Int64) : Nil
    return if table.size == 1

    (1...table.size).each do |i|
      j = i
      while j > 0
        break if table.unsafe_fetch(j).org >= table.unsafe_fetch(j - 1).org
        t = table.unsafe_fetch(j)
        table[j] = table.unsafe_fetch(j - 1)
        table[j - 1] = t
        j -= 1
      end
    end

    count = table.size
    cur_idx = 0
    cur_val = table.unsafe_fetch(0).org

    i = 1
    while i < count
      if table.unsafe_fetch(i).org &- cur_val > threshold || i == count - 1
        sum = 0_i64

        # fix loop for end of array
        if table.unsafe_fetch(i).org &- cur_val <= threshold && i == count - 1
          i += 1
        end

        j = cur_idx
        while j < i
          sum &+= table.unsafe_fetch(j).org
          table[j].org = 0
          j += 1
        end
        table[cur_idx].org = sum.tdiv(j)

        if i < count - 1
          cur_idx = i + 1
          cur_val = table.unsafe_fetch(cur_idx).org
        end
      end
      i += 1
    end

    cur_idx = 1

    # compress array to remove zero values
    i = 1
    while i < count
      if table.unsafe_fetch(i).org != 0
        table[cur_idx] = table.unsafe_fetch(i)
        cur_idx += 1
      end
      i += 1
    end

    while table.size > cur_idx
      table.pop
    end
  end

  # af_direction_compute.
  def self.direction_compute(dx : Int64, dy : Int64) : Int8
    if dy >= dx
      if dy >= -dx
        dir = DIR_UP
        ll = dy
        ss = dx
      else
        dir = DIR_LEFT
        ll = -dx
        ss = dy
      end
    else # dy < dx
      if dy >= -dx
        dir = DIR_RIGHT
        ll = dx
        ss = dy
      else
        dir = DIR_DOWN
        ll = -dy
        ss = dx
      end
    end

    # no direction if arm lengths do not differ enough
    # (14 ~ 4.1 degrees); the long arm is never negative
    dir = DIR_NONE if ll <= 14 &* ss.abs
    dir
  end

  # FT_Outline_Get_Orientation on font-unit coordinates: 1 = postscript
  # (clockwise), -1 = truetype, 0 = none.
  def self.outline_orientation(xs : Array(Int64), ys : Array(Int64),
                               contours : Array(Int32)) : Int32
    return -1_i32 if xs.empty? # empty -> FT_ORIENTATION_TRUETYPE

    x_min = Int64::MAX // 2
    x_max = Int64::MIN // 2
    y_min = Int64::MAX // 2
    y_max = Int64::MIN // 2
    xs.each do |v|
      x_min = v if v < x_min
      x_max = v if v > x_max
    end
    ys.each do |v|
      y_min = v if v < y_min
      y_max = v if v > y_max
    end

    return 0 if x_min == x_max || y_min == y_max
    return 0 if x_min < -0x1000000_i64 || y_min < -0x1000000_i64 ||
                x_max > 0x1000000_i64 || y_max > 0x1000000_i64

    xshift = ft_msb((x_max.abs | x_min.abs).to_u32!) - 14
    xshift = 0 if xshift < 0
    yshift = ft_msb((y_max - y_min).to_u32!) - 14
    yshift = 0 if yshift < 0

    area = 0_i64
    last = -1
    contours.each do |cend|
      first = last + 1
      last = cend

      prev_x = xs.unsafe_fetch(last) >> xshift
      prev_y = ys.unsafe_fetch(last) >> yshift

      (first..last).each do |n|
        cur_x = xs.unsafe_fetch(n) >> xshift
        cur_y = ys.unsafe_fetch(n) >> yshift
        area = area &+ (cur_y &- prev_y) &* (cur_x &+ prev_x)
        prev_x = cur_x
        prev_y = cur_y
      end
    end

    area > 0 ? 1 : (area < 0 ? -1 : 0)
  end

  # --- AF_GlyphHintsRec ----------------------------------------------------

  class GlyphHints
    property x_scale : Int64 = 0
    property x_delta : Int64 = 0
    property y_scale : Int64 = 0
    property y_delta : Int64 = 0

    property points : Array(AfPoint) = [] of AfPoint
    # index of each contour's first point
    property contours : Array(Int32) = [] of Int32
    # index of each contour's last point
    property contour_ends : Array(Int32) = [] of Int32

    property axis : Array(AxisHints) = [AxisHints.new, AxisHints.new]

    property scaler_flags : UInt32 = 0
    property other_flags : UInt32 = 0

    property units_per_em : Int32 = 2048

    def initialize
    end

    def reset
      points.clear
      contours.clear
      contour_ends.clear
      axis[DIMENSION_HORZ].reset
      axis[DIMENSION_VERT].reset
    end

    # af_glyph_hints_reload: (re)build the point network from an outline
    # in font units, scaling onto the pixel grid.
    def reload(xs : Array(Int64), ys : Array(Int64), tags : Array(UInt8),
               in_contours : Array(Int32), units_per_em : Int32) : Nil
      reset
      @units_per_em = units_per_em

      # value 20 in `near_limit' is heuristic
      near_limit = 20 &* units_per_em // 2048

      axis[DIMENSION_HORZ].major_dir = DIR_UP
      axis[DIMENSION_VERT].major_dir = DIR_LEFT

      if Autofit.outline_orientation(xs, ys, in_contours) == 1 # postscript
        axis[DIMENSION_HORZ].major_dir = DIR_DOWN
        axis[DIMENSION_VERT].major_dir = DIR_RIGHT
      end

      n_points = xs.size
      return if n_points == 0

      n_points.times { points << AfPoint.new }
      start_idx = 0
      in_contours.each do |cend|
        @contours << start_idx
        @contour_ends << cend
        start_idx = cend + 1
      end

      # compute coordinates & Bezier flags, next and prev
      ci = 0
      end_i = @contour_ends.empty? ? n_points - 1 : @contour_ends.unsafe_fetch(0)
      prev = end_i

      near_limit2 = 2 &* near_limit &- 1

      n_points.times do |i|
        point = points.unsafe_fetch(i)

        point.fx = xs.unsafe_fetch(i).to_i16!
        point.fy = ys.unsafe_fetch(i).to_i16!
        point.ox = point.x = Fixed.mulfix(xs.unsafe_fetch(i), @x_scale) &+ @x_delta
        point.oy = point.y = Fixed.mulfix(ys.unsafe_fetch(i), @y_scale) &+ @y_delta

        pend = points.unsafe_fetch(end_i)
        pend.fx = xs.unsafe_fetch(end_i).to_i16!
        pend.fy = ys.unsafe_fetch(end_i).to_i16!

        case tags.unsafe_fetch(i) & 0x03
        when 0 then point.flags = FLAG_CONIC
        when 2 then point.flags = FLAG_CUBIC
        else        point.flags = 0_u16
        end

        pprev = points.unsafe_fetch(prev)
        out_x = point.fx.to_i64! &- pprev.fx
        out_y = point.fy.to_i64! &- pprev.fy
        pprev.flags |= FLAG_NEAR if out_x.abs &+ out_y.abs < near_limit

        point.prev = prev
        pprev.next = i
        prev = i

        if i == end_i && ci + 1 < @contour_ends.size
          ci += 1
          end_i = @contour_ends.unsafe_fetch(ci)
          prev = end_i
        end
      end

      # `in'/'out' vector directions per contour
      contours.each_with_index do |cstart, ci|
        cend = contour_ends.unsafe_fetch(ci)
        first = cstart

        # go backwards to find the first non-near point
        point = first
        prev_pt = points.unsafe_fetch(point).prev
        while prev_pt != first
          p = points.unsafe_fetch(point)
          q = points.unsafe_fetch(prev_pt)
          out_x = p.fx.to_i64! &- q.fx
          out_y = p.fy.to_i64! &- q.fy
          break if out_x.abs &+ out_y.abs >= near_limit2

          point = prev_pt
          prev_pt = q.prev
        end
        first = point

        curr = first
        points.unsafe_fetch(curr).u = 0
        points.unsafe_fetch(first).v = 0

        out_x = 0_i64
        out_y = 0_i64
        next_i = first

        loop do
          point = next_i
          next_i = points.unsafe_fetch(point).next

          p = points.unsafe_fetch(point)
          n = points.unsafe_fetch(next_i)
          out_x &+= n.fx.to_i64! &- p.fx
          out_y &+= n.fy.to_i64! &- p.fy

          if out_x.abs &+ out_y.abs < near_limit
            n.flags |= FLAG_WEAK_INTERPOLATION
          else
            points.unsafe_fetch(curr).u = (next_i - curr).to_i64!
            n.v = -(next_i - curr).to_i64!

            out_dir = Autofit.direction_compute(out_x, out_y)

            # adjust directions for all points inbetween
            points.unsafe_fetch(curr).out_dir = out_dir
            c = points.unsafe_fetch(curr).next
            while c != next_i
              cp = points.unsafe_fetch(c)
              cp.in_dir = out_dir
              cp.out_dir = out_dir
              c = cp.next
            end
            n.in_dir = out_dir

            points.unsafe_fetch(next_i).u = (first - next_i).to_i64!
            points.unsafe_fetch(first).v = -(first - next_i).to_i64!

            out_x = 0_i64
            out_y = 0_i64
            curr = next_i
          end

          break if next_i == first
        end
      end

      # simplify topology: same-quadrant in/out vectors collapse
      n_points.times do |i|
        point = points.unsafe_fetch(i)
        next if point.flags & FLAG_WEAK_INTERPOLATION != 0
        next unless point.in_dir == DIR_NONE && point.out_dir == DIR_NONE

        next_u = (i + point.u).to_i32!
        prev_v = (i + point.v).to_i32!
        nu = points.unsafe_fetch(next_u)
        pv = points.unsafe_fetch(prev_v)

        in_x = point.fx.to_i64! &- pv.fx
        in_y = point.fy.to_i64! &- pv.fy
        out_x = nu.fx.to_i64! &- point.fx
        out_y = nu.fy.to_i64! &- point.fy

        if (in_x ^ out_x) >= 0 && (in_y ^ out_y) >= 0
          point.flags |= FLAG_WEAK_INTERPOLATION
          pv.u = (next_u - prev_v).to_i64!
          nu.v = -(next_u - prev_v).to_i64!
        end
      end

      # remaining weak points
      n_points.times do |i|
        point = points.unsafe_fetch(i)
        next if point.flags & FLAG_WEAK_INTERPOLATION != 0

        if point.flags & (FLAG_CONIC | FLAG_CUBIC) != 0
          # control points are always weak
          point.flags |= FLAG_WEAK_INTERPOLATION
        elsif point.out_dir == point.in_dir
          if point.out_dir != DIR_NONE
            # on a horizontal/vertical segment
            point.flags |= FLAG_WEAK_INTERPOLATION
          else
            next_u = (i + point.u).to_i32!
            prev_v = (i + point.v).to_i32!
            nu = points.unsafe_fetch(next_u)
            pv = points.unsafe_fetch(prev_v)

            if Autofit.corner_is_flat(point.fx.to_i64! &- pv.fx,
                                      point.fy.to_i64! &- pv.fy,
                                      nu.fx.to_i64! &- point.fx,
                                      nu.fy.to_i64! &- point.fy)
              pv.u = (next_u - prev_v).to_i64!
              nu.v = -(next_u - prev_v).to_i64!
              point.flags |= FLAG_WEAK_INTERPOLATION
            end
          end
        elsif point.in_dir == -point.out_dir
          # spike
          point.flags |= FLAG_WEAK_INTERPOLATION
        end
      end
    end

    # af_glyph_hints_save: write the hinted positions back.
    def save(xs : Array(Int64), ys : Array(Int64), tags : Array(UInt8)) : Nil
      points.each_with_index do |p, i|
        xs[i] = p.x
        ys[i] = p.y
        tags[i] = (p.flags & FLAG_CONIC != 0 ? 0_u8 : (p.flags & FLAG_CUBIC != 0 ? 2_u8 : 1_u8))
      end
    end

    # af_glyph_hints_align_edge_points.
    def align_edge_points(dim : Int32) : Nil
      ax = axis[dim]
      ax.segments.each do |seg|
        next if seg.edge < 0
        pos = ax.edges.unsafe_fetch(seg.edge).pos

        point = seg.first
        loop do
          p = points.unsafe_fetch(point)
          if dim == DIMENSION_HORZ
            p.x = pos
            p.flags |= FLAG_TOUCH_X
          else
            p.y = pos
            p.flags |= FLAG_TOUCH_Y
          end
          break if point == seg.last
          point = p.next
        end
      end
    end

    # af_glyph_hints_align_strong_points (the TrueType `IP' equivalent).
    def align_strong_points(dim : Int32) : Nil
      touch_flag = dim == DIMENSION_HORZ ? FLAG_TOUCH_X : FLAG_TOUCH_Y
      edges = axis[dim].edges
      n_edges = edges.size

      return if edges.empty?

      points.each_with_index do |point, _|
        next if point.flags & touch_flag != 0
        next if point.flags & FLAG_WEAK_INTERPOLATION != 0

        if dim == DIMENSION_VERT
          u = point.fy.to_i64!
          ou = point.oy
        else
          u = point.fx.to_i64!
          ou = point.ox
        end
        fu = u

        # before the first edge?
        edge = edges.unsafe_fetch(0)
        if edge.fpos.to_i64! &- u >= 0
          u = edge.pos &- (edge.opos &- ou)
          point = store_point(point, dim, u, touch_flag)
          next
        end

        # after the last edge?
        edge = edges.unsafe_fetch(n_edges - 1)
        if u &- edge.fpos >= 0
          u = edge.pos &+ (ou &- edge.opos)
          point = store_point(point, dim, u, touch_flag)
          next
        end

        # find enclosing edges
        min_idx = 0
        max_idx = n_edges

        if max_idx <= 8
          nn = 0
          while nn < max_idx
            break if edges.unsafe_fetch(nn).fpos.to_i64! >= u
            nn += 1
          end
          if nn < max_idx && edges.unsafe_fetch(nn).fpos.to_i64! == u
            u = edges.unsafe_fetch(nn).pos
            point = store_point(point, dim, u, touch_flag)
            next
          end
          min_idx = nn
        else
          found = false
          while min_idx < max_idx
            mid = (max_idx &+ min_idx) >> 1
            edge = edges.unsafe_fetch(mid)
            fpos = edge.fpos.to_i64!
            if u < fpos
              max_idx = mid
            elsif u > fpos
              min_idx = mid + 1
            else
              u = edge.pos
              point = store_point(point, dim, u, touch_flag)
              found = true
              break
            end
          end
          next if found
        end

        before = edges.unsafe_fetch(min_idx - 1)
        after = edges.unsafe_fetch(min_idx)

        if before.scale == 0
          before.scale = Fixed.divfix(after.pos &- before.pos,
                                      after.fpos.to_i64! &- before.fpos)
        end

        u = before.pos &+ Fixed.mulfix(fu &- before.fpos, before.scale)
        point = store_point(point, dim, u, touch_flag)
      end
    end

    private def store_point(point : AfPoint, dim : Int32, u : Int64,
                            touch_flag : UInt16) : AfPoint
      if dim == DIMENSION_HORZ
        point.x = u
      else
        point.y = u
      end
      point.flags |= touch_flag
      point
    end

    # af_iup_shift: shift p1..p2 (exclusive ref) by ref.u - ref.v.
    private def iup_shift(p1 : Int32, p2 : Int32, ref : Int32) : Nil
      delta = points.unsafe_fetch(ref).u &- points.unsafe_fetch(ref).v
      return if delta == 0

      (p1...ref).each { |p| points.unsafe_fetch(p).u = points.unsafe_fetch(p).v &+ delta }
      ((ref + 1)..p2).each { |p| points.unsafe_fetch(p).u = points.unsafe_fetch(p).v &+ delta }
    end

    # af_iup_interp.
    private def iup_interp(p1 : Int32, p2 : Int32, ref1 : Int32, ref2 : Int32) : Nil
      return if p1 > p2

      if points.unsafe_fetch(ref1).v > points.unsafe_fetch(ref2).v
        ref1, ref2 = ref2, ref1
      end

      v1 = points.unsafe_fetch(ref1).v
      v2 = points.unsafe_fetch(ref2).v
      u1 = points.unsafe_fetch(ref1).u
      u2 = points.unsafe_fetch(ref2).u
      d1 = u1 &- v1
      d2 = u2 &- v2

      if u1 == u2 || v1 == v2
        (p1..p2).each do |p|
          pt = points.unsafe_fetch(p)
          u = pt.v
          if u <= v1
            u = u &+ d1
          elsif u >= v2
            u = u &+ d2
          else
            u = u1
          end
          pt.u = u
        end
      else
        scale = Fixed.divfix(u2 &- u1, v2 &- v1)
        (p1..p2).each do |p|
          pt = points.unsafe_fetch(p)
          u = pt.v
          if u <= v1
            u = u &+ d1
          elsif u >= v2
            u = u &+ d2
          else
            u = u1 &+ Fixed.mulfix(u &- v1, scale)
          end
          pt.u = u
        end
      end
    end

    # af_glyph_hints_align_weak_points (the TrueType `IUP' equivalent).
    def align_weak_points(dim : Int32) : Nil
      touch_flag = dim == DIMENSION_HORZ ? FLAG_TOUCH_X : FLAG_TOUCH_Y

      if dim == DIMENSION_HORZ
        points.each { |p| p.u = p.x; p.v = p.ox }
      else
        points.each { |p| p.u = p.y; p.v = p.oy }
      end

      contours.each_with_index do |cstart, ci|
        cend = contour_ends.unsafe_fetch(ci)
        first_point = cstart
        end_point = cend

        # find first touched point
        point = cstart
        first_touched = -1
        loop do
          if point > end_point # no touched point in contour
            first_touched = -1
            break
          end
          if points.unsafe_fetch(point).flags & touch_flag != 0
            first_touched = point
            break
          end
          point += 1
        end
        next if first_touched < 0

        point = first_touched
        last_touched = point
        ended = false
        loop do
          # skip any touched neighbours
          while point < end_point &&
                points.unsafe_fetch(point + 1).flags & touch_flag != 0
            point += 1
          end
          last_touched = point

          # find the next touched point, if any
          point += 1
          nxt = -1
          loop do
            if point > end_point
              ended = true
              break
            end
            if points.unsafe_fetch(point).flags & touch_flag != 0
              nxt = point
              break
            end
            point += 1
          end

          unless ended
            iup_interp(last_touched + 1, nxt - 1, last_touched, nxt)
          else
            break
          end
        end

        # special case: only one point was touched
        if last_touched == first_touched
          iup_shift(first_point, end_point, first_touched)
        else
          # interpolate the last part
          if last_touched < end_point
            iup_interp(last_touched + 1, end_point, last_touched, first_touched)
          end
          if first_touched > 0
            iup_interp(first_point, first_touched - 1, last_touched, first_touched)
          end
        end
      end

      # save the interpolated values back to x/y
      if dim == DIMENSION_HORZ
        points.each { |p| p.x = p.u }
      else
        points.each { |p| p.y = p.u }
      end
    end
  end
end

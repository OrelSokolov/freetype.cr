# Crystal port of the FreeType fixed-point CORDIC trigonometry needed for
# bit-exact `FT_Hypot` (~/freetype/src/base/fttrigon.c `FT_Vector_Length` +
# ftcalc.c `FT_Hypot`).  Used by the TrueType composite-glyph loader for the
# SCALED_COMPONENT_OFFSET path (`mac_xscale`/`mac_yscale`).

module Fttrigon
  # The Cordic shrink factor 0.858785336480436 * 2^32.
  TRIG_SCALE = 0xDBD95B16_u64

  # The highest bit in overflow-safe vector components.
  TRIG_SAFE_MSB = 29

  # Generated for FT_PI = 180L << 16, i.e. degrees.
  ARCTAN_TABLE = [
    1740967, 919879, 466945, 234379, 117304, 58666, 29335,
    14668, 7334, 3667, 1833, 917, 458, 229, 115,
    57, 29, 14, 7, 4, 2, 1,
  ] of Int64

  FT_ANGLE_PI4 = 45_i64 << 16
  FT_ANGLE_PI2 = 90_i64 << 16
  FT_ANGLE_PI  = 180_i64 << 16

  # FT_MSB of a nonzero 32-bit value (index of the highest set bit).
  private def self.msb32(v : UInt32) : Int32
    31 - v.leading_zeros_count.to_i32
  end

  # Multiply by the CORDIC shrink factor (ft_trig_downscale, FT_INT64 path).
  private def self.downscale(val : Int64) : Int64
    s = 1_i64
    if val < 0
      val = -val
      s = -1
    end
    # 0x40000000 comes from regression analysis between true and CORDIC
    # hypotenuse, so it minimizes the error.
    res = ((val.to_u64! * TRIG_SCALE + 0x40000000_u64) >> 32).to_i64!
    s < 0 ? -res : res
  end

  # ft_trig_prenorm: normalize the vector magnitude close to 2^29 and return
  # the applied shift (positive: left shift, negative: right shift).
  private def self.prenorm(x0 : Int64, y0 : Int64) : {Int64, Int64, Int32}
    shift = msb32((x0.abs.to_u32! | y0.abs.to_u32!))
    x = x0
    y = y0
    if shift <= TRIG_SAFE_MSB
      shift = TRIG_SAFE_MSB - shift
      x = x.to_u64! << shift
      y = y.to_u64! << shift
    else
      shift -= TRIG_SAFE_MSB
      x = x >> shift
      y = y >> shift
      shift = -shift
    end
    {x.to_i64!, y.to_i64!, shift}
  end

  # ft_trig_pseudo_polarize: rotates the vector onto the positive x axis,
  # accumulating the rotation angle in v.y; we only need the resulting x.
  private def self.pseudo_polarize(x0 : Int64, y0 : Int64) : {Int64, Int64}
    x = x0
    y = y0
    theta = 0_i64

    # Get the vector into [-PI/4,PI/4] sector.
    if y > x
      if y > -x
        theta = FT_ANGLE_PI2
        xtemp = y
        y = -x
        x = xtemp
      else
        theta = y > 0 ? FT_ANGLE_PI : -FT_ANGLE_PI
        x = -x
        y = -y
      end
    else
      if y < -x
        theta = -FT_ANGLE_PI2
        xtemp = -y
        y = x
        x = xtemp
      end
    end

    # Pseudorotations, with right shifts.
    each_idx = 0
    b = 1_i64
    (1...23).each do |i|
      if y > 0
        xtemp = x + ((y + b) >> i)
        y = y - ((x + b) >> i)
        x = xtemp
        theta += ARCTAN_TABLE[each_idx]
      else
        xtemp = x - ((y + b) >> i)
        y = y + ((x + b) >> i)
        x = xtemp
        theta -= ARCTAN_TABLE[each_idx]
      end
      each_idx += 1
      b <<= 1
    end

    # Round theta to acknowledge its error that mostly comes from
    # accumulated rounding errors in the arctan table.
    theta = theta >= 0 ? (theta + 8) & -16 : -((-theta + 8) & -16)

    {x, theta}
  end

  # FT_Vector_Length (fttrigon.c).
  def self.vector_length(x : Int64, y : Int64) : Int64
    return y.abs if x == 0
    return x.abs if y == 0

    px, py, shift = prenorm(x, y)
    vx, _theta = pseudo_polarize(px, py)
    vx = downscale(vx)

    return (vx + (1_i64 << (shift - 1))) >> shift if shift > 0

    (vx.to_u32!.to_i64!) << -shift
  end

  # FT_Hypot (ftcalc.c).
  def self.hypot(x : Int64, y : Int64) : Int64
    vector_length(x, y)
  end
end

#include <ft2build.h>
#include FT_FREETYPE_H
/* LP64 FT_DivFix replica (ftcalc.c) to satisfy FT_Tan's link dependency */
FT_Long
FT_DivFix( FT_Long a_, FT_Long b_ )
{
  FT_Int  s = 1;
  FT_UInt64  a, b, q;
  FT_Long    q_;

  s = 1; a = (FT_UInt64)a_; if (a_ < 0) { s = -s; a = (FT_UInt64)-(FT_Int64)a_; }
  b = (FT_UInt64)b_; if (b_ < 0) { s = -s; b = (FT_UInt64)-(FT_Int64)b_; }
  q = b > 0 ? ( ( a << 16 ) + ( b >> 1 ) ) / b : 0x7FFFFFFFUL;
  q_ = (FT_Long)q;
  return s < 0 ? -q_ : q_;
}

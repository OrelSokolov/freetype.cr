#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

/* pull in the real CORDIC implementation */
#include "/home/oleg/freetype/src/base/fttrigon.c"

static FT_Fixed my_hypot(FT_Fixed x, FT_Fixed y)
{
  FT_Vector v;
  v.x = x; v.y = y;
  return FT_Vector_Length(&v);
}

int main(int argc, char **argv)
{
  (void)argc; (void)argv;
  unsigned long seed = 12345;
  unsigned long rng(void) { seed = seed * 6364136223846793005UL + 1442695040888963407UL; return seed >> 33; }
  /* deterministic mix: extremes, small, random widths */
  static const FT_Fixed specials[] = { 0, 1, -1, 2, -2, 63, 64, 1<<14, -(1<<14),
    1<<16, -(1<<16), 1<<20, 1<<29, -(1<<29), 0x40000000-1, -(0x40000000-1) };
  for (unsigned i = 0; i < sizeof(specials)/sizeof(specials[0]); i++)
    for (unsigned j = 0; j < sizeof(specials)/sizeof(specials[0]); j++)
      printf("%ld\n", (long)my_hypot(specials[i], specials[j]));
  for (int k = 0; k < 200000; k++)
  {
    int bits = 1 + (int)(rng() % 46);
    long m = (1L << bits) - 1;
    long x = (long)(rng() & m); if (rng() & 1) x = -x;
    long y = (long)(rng() & m); if (rng() & 1) y = -y;
    if (x == 0 && y == 0) y = 1;
    printf("%ld\n", (long)my_hypot((FT_Fixed)x, (FT_Fixed)y));
  }
  return 0;
}

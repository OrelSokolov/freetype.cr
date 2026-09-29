/* Standalone C oracle for ftgrays.c: reads an outline dump on stdin,
 * renders it through the rasterizer (exactly like ftsmooth's NORMAL
 * path, with the caller-supplied bitmap geometry), writes coverage
 * bytes to stdout.
 *
 * Input format (all integers, whitespace-separated):
 *   width height
 *   x_shift y_shift          (26.6 translation applied to all points)
 *   n_points n_contours
 *   n_points * ( x y tag )   (26.6; tag: 1 on, 0 conic, 2 cubic)
 *   n_contours * last_index
 * Output: width*height unsigned bytes, top row first (the rasterizer's
 * bottom-up buffer is flipped here).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* shims for the internal FreeType bits ftgrays.c references */
#define FALL_THROUGH __attribute__((fallthrough))
typedef unsigned long FT_ULong;
typedef int FT_Error;
typedef struct FT_MemoryRec_* FT_Memory;
#define FT_QNEW_ARRAY( ptr, count ) \
          ( (ptr) = calloc( (size_t)(count), sizeof *(ptr) ), 0 )
#define FT_FREE( ptr ) free( ptr )

#include "ftint64_shim.h"
#define STANDALONE_
#include "ftgrays.c"

int main(void)
{
  int width, height;
  long long x_shift, y_shift;
  int n_points, n_contours;

  if ( scanf( "%d %d %lld %lld %d %d", &width, &height,
              &x_shift, &y_shift, &n_points, &n_contours ) != 6 )
    return 2;

  FT_Vector* points = calloc( n_points ? n_points : 1, sizeof ( FT_Vector ) );
  char*      tags    = calloc( n_points ? n_points : 1, 1 );
  short*     cont    = calloc( n_contours ? n_contours : 1, sizeof ( short ) );

  for ( int i = 0; i < n_points; i++ )
  {
    long long x, y;
    int tag;
    if ( scanf( "%lld %lld %d", &x, &y, &tag ) != 3 )
      return 2;
    points[i].x = (FT_Pos)( x + x_shift );
    points[i].y = (FT_Pos)( y + y_shift );
    tags[i] = (char)tag;
  }
  for ( int i = 0; i < n_contours; i++ )
  {
    int last;
    if ( scanf( "%d", &last ) != 1 )
      return 2;
    cont[i] = (short)last;
  }

  FT_Outline outline;
  outline.n_contours = (short)n_contours;
  outline.n_points   = (short)n_points;
  outline.points     = points;
  outline.tags       = tags;
  outline.contours   = cont;
  outline.flags      = 0;

  unsigned char* buf = calloc( (size_t)width * height, 1 );
  FT_Bitmap target;
  memset( &target, 0, sizeof ( target ) );
  target.rows       = height;
  target.width      = width;
  target.pitch      = width;
  target.buffer     = buf;
  target.pixel_mode = FT_PIXEL_MODE_GRAY;

  FT_Raster raster;
  if ( ft_grays_raster.raster_new( NULL, &raster ) )
    return 3;

  FT_Raster_Params params;
  memset( &params, 0, sizeof ( params ) );
  params.flags  = FT_RASTER_FLAG_AA;
  params.source = &outline;
  params.target = &target;

  int err = ft_grays_raster.raster_render( raster, &params );
  if ( err )
  {
    fprintf( stderr, "raster_render err=%d\n", err );
    return 4;
  }

  /* FT gray bitmaps with positive pitch are already top-down in memory */
  fwrite( buf, 1, (size_t)width * height, stdout );
  return 0;
}

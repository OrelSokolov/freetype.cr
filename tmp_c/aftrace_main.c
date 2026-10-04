/* aftrace_main.c: load one glyph with the auto-hinter, dump outline,
 * full FT trace goes to stderr. Usage: aftrace <font> <px> <gid> */
#include <stdio.h>
#include <ft2build.h>
#include FT_FREETYPE_H

int main(int argc, char **argv)
{
  FT_Library lib;
  FT_Face face;
  FT_Error err;
  int px, gid, i;

  if (argc < 4) { fprintf(stderr, "usage: %s font px gid\n", argv[0]); return 2; }
  px = atoi(argv[2]);
  gid = atoi(argv[3]);

  err = FT_Init_FreeType(&lib);
  if (err) return 1;
  err = FT_New_Face(lib, argv[1], 0, &face);
  if (err) { fprintf(stderr, "new_face %d\n", err); return 1; }
  err = FT_Set_Pixel_Sizes(face, 0, px);
  if (err) return 1;

  err = FT_Load_Glyph(face, gid, FT_LOAD_DEFAULT);
  if (err) { fprintf(stderr, "load %d\n", err); return 1; }

  printf("adv=%ld npoints=%d\n",
         (long)face->glyph->advance.x, face->glyph->outline.n_points);
  for (i = 0; i < face->glyph->outline.n_points; i++)
  {
    FT_Vector *p = &face->glyph->outline.points[i];
    printf("  [%3d] (%5ld,%5ld) tag=%d\n",
           i, (long)p->x, (long)p->y, face->glyph->outline.tags[i] & 3);
  }
  FT_Done_Face(face);
  FT_Done_FreeType(lib);
  return 0;
}

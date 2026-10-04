# Entry point of the freetype-cr shard: the self-contained font
# pipeline — SFNT parsing + hinted TrueType glyph loading (ttinterp
# bytecode VM), unhinted CFF (Type 2 charstring) loading, the ftgrays
# rasterizer and the ftsmooth-style render glue — with no dependency on
# the C library. See README.md for the acceptance numbers.

require "./ftgrays"
require "./ftrender"
require "./fttrigon"
require "./tt/sfnt"
require "./tt/ttgxvar"
require "./tt/loader"
require "./tt/ttinterp"
require "./autofit/afloader"
require "./cff/face"

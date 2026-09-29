# Entry point of the freetype-cr shard: the self-contained TrueType
# pipeline — SFNT parsing + hinted glyph loading (ttinterp bytecode VM),
# the ftgrays rasterizer and the ftsmooth-style render glue — with no
# dependency on the C library. See README.md for the acceptance numbers.

require "./ftgrays"
require "./ftrender"
require "./fttrigon"
require "./tt/sfnt"
require "./tt/loader"
require "./tt/ttinterp"

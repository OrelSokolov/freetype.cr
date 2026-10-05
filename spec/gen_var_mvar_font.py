# Build a minimal VARIABLE font with an `MVAR' table out of a static
# TrueType face (Liberation Sans), so the MVAR metric adjustments can be
# exercised against the oracle. One axis (wght 400..700, default 400);
# the VariationStore has a single region peaking at +1.0 (wght=700) and
# one VarData item per metric tag. Deltas at the peak instance:
#   hasc +37  hdsc -27  hlgp +12  hcla +40  hcld +30
#   undo  -6  unds  +3  xhgt +25  stro +15  strs  +2
import struct, sys

SRC = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
DST = "/tmp/LibVarMvar.ttf"

def be32(x): return struct.pack('>I', x)
def be16(x): return struct.pack('>H', x)
def i16(x): return struct.pack('>h', x)

sfnt = open(SRC, 'rb').read()
num = struct.unpack('>H', sfnt[4:6])[0]
tables = []
for i in range(num):
    off = 12 + 16 * i
    tag, cks, o, l = struct.unpack('>4sIII', sfnt[off:off+16])
    tables.append([tag, cks, sfnt[o:o+l]])

# ---- fvar: one axis, no named instances
fvar = be16(1) + be16(0) + be16(16) + be16(2) + be16(1) + be16(20) + be16(0) + be16(8)
fvar += b'wght' + struct.pack('>iii', 400 << 16, 400 << 16, 700 << 16) + be16(0) + be16(257)

# ---- MVAR
# records: (tag, outer, inner) — inner indexes the VarData delta rows
tags_deltas = [
    (b'hasc', 37), (b'hdsc', -27), (b'hlgp', 12), (b'hcla', 40), (b'hcld', 30),
    (b'undo', -6), (b'unds', 3), (b'xhgt', 25), (b'stro', 15), (b'strs', 2),
]
item_count = len(tags_deltas)

# ItemVariationStore: header (12) + region list (10) + one VarData
region_list = be16(1) + be16(1) + i16(0) + i16(16384) + i16(16384)
var_data = be16(item_count) + be16(0) + be16(1) + be16(0)
for _, delta in tags_deltas:
    var_data += struct.pack('>b', delta)

store_header_size = 2 + 4 + 2 + 4
region_list_off = store_header_size
var_data_off = region_list_off + len(region_list)
ivs = be16(1) + be32(region_list_off) + be16(1) + be32(var_data_off)
ivs += region_list + var_data

records_off = 12
store_off = records_off + 8 * item_count
mvar = be16(1) + be16(0) + be16(0) + be16(8) + be16(item_count) + be16(store_off)
for i, (tag, _) in enumerate(tags_deltas):
    mvar += tag + be16(0) + be16(i)
assert len(mvar) == store_off
mvar += ivs

# ---- rebuild the SFNT
tables.append([b'fvar', 0, fvar])
tables.append([b'MVAR', 0, mvar])
tables.sort(key=lambda t: t[0])

n = len(tables)
out = bytearray()
directory = bytearray()
offset = 12 + 16 * n
blobs = bytearray()
for tag, cks, blob in tables:
    pad = (4 - (offset % 4)) % 4
    blobs += b'\0' * pad
    offset += pad
    directory += tag + be32(cks) + be32(offset) + be32(len(blob))
    blobs += blob
    offset += len(blob)
out += sfnt[:4] + be16(n) + sfnt[6:12] + directory + blobs

open(DST, 'wb').write(bytes(out))
print("wrote", DST, len(out), "bytes; MVAR:", mvar.hex())

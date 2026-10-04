# Build a minimal VARIABLE font with a `cvar' table out of a static
# TrueType face (Liberation Sans: it has fpgm/prep/cvt bytecode), so the
# cvar path can be exercised against the oracle. One axis (wght
# 400..700, default 400), one embedded tuple peaking at +1.0 with ALL
# points and a constant +20 font-unit delta on the first 8 CVT entries.
import struct, sys

SRC = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
DST = "/tmp/LibVarCvar.ttf"

def be32(x): return struct.pack('>I', x)
def be16(x): return struct.pack('>H', x)

sfnt = open(SRC, 'rb').read()
num = struct.unpack('>H', sfnt[4:6])[0]
tables = []
for i in range(num):
    off = 12 + 16 * i
    tag, cks, o, l = struct.unpack('>4sIII', sfnt[off:off+16])
    tables.append([tag, cks, sfnt[o:o+l]])

# drop existing checksum-dependent head adjust later; keep tables as-is
cvt = None
for t in tables:
    if t[0] == b'cvt ':
        cvt = t[2]
if cvt is None:
    sys.exit("no cvt table in " + SRC)
cvt_size = len(cvt) // 2
print("cvt entries:", cvt_size)

# ---- fvar: one axis, no named instances
fvar = be16(1) + be16(0) + be16(16) + be16(2) + be16(1) + be16(20) + be16(0) + be16(8)
fvar += b'wght' + struct.pack('>iii', 400 << 16, 400 << 16, 700 << 16) + be16(0) + be16(257)

# ---- cvar: header + one tuple
# tuple data: points (ALL -> single 0x00 byte) + deltas for cvt_size
deltas = bytearray()
delta_run = cvt_size              # +20 on EVERY entry (runs of <=64 bytes)
while delta_run > 0:
    run = min(delta_run, 64)
    deltas += bytes([run - 1]) + bytes([20] * run)
    delta_run -= run
tuple_data = b'\x00' + bytes(deltas)

tuple_header = be16(len(tuple_data)) + be16(0x8000 | 0x2000) + be16(0x4000)
# dataOffset counts from the table start; tuples start right after the
# 8-byte header, the point/delta data follows the 6-byte tuple header
data_offset = 8 + len(tuple_header)
cvar = be16(1) + be16(0) + be16(1) + be16(data_offset) + tuple_header + tuple_data

# ---- rebuild the SFNT
tables.append([b'fvar', 0, fvar])
tables.append([b'cvar', 0, cvar])
# keep 'head' checksumAdjustment stale: FreeType does not verify by default
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
print("wrote", DST, len(out), "bytes; cvar:", cvar.hex())

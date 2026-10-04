# Shared FFI oracle for the specs: a minimal binding of the system
# FreeType (LP64 offsets, verified against the 2.13/2.14 headers — the
# same layout the egui.cr backend mirrors) plus helpers to snapshot an
# FT_Outline and an oracle coverage bitmap.
#
# 64-bit non-Windows only.

{% unless flag?(:bits64) && !flag?(:win32) %}
  {{ raise "LP64 mirror: run on a 64-bit Unix target" }}
{% end %}

@[Link("freetype")]
lib LibFT
  alias Long = Int64

  FT_LOAD_DEFAULT    = 0
  FT_LOAD_NO_HINTING = 0x2  # (1L << 1); the earlier 0x10 was
                           # FT_LOAD_VERTICAL_LAYOUT
  FT_LOAD_RENDER     = 0x4
  FT_LOAD_NO_BITMAP  = 0x8
  FT_LOAD_FORCE_AUTOHINT = 0x20 # (1L << 5)
  FT_PIXEL_MODE_GRAY = 2

  # FT_Render_Mode_ (ftimage.h)
  FT_RENDER_MODE_NORMAL = 0
  FT_RENDER_MODE_LIGHT  = 1
  FT_RENDER_MODE_MONO   = 2
  FT_RENDER_MODE_LCD    = 3
  FT_RENDER_MODE_LCD_V  = 4

  struct Vector
    x : Long
    y : Long
  end

  struct Bitmap
    rows : Int32
    width : Int32
    pitch : Int32
    pad0 : Int32
    buffer : UInt8*
    num_grays : UInt16
    pixel_mode : UInt8
    palette_mode : UInt8
    pad1 : UInt8[4]
    palette : Void*
  end

  struct OutlineRec # FT_Outline, @200 in FT_GlyphSlotRec (LP64)
    n_contours : Int16
    n_points : Int16
    pad0 : Int32
    points : Vector*
    tags : UInt8*
    contours : Int16*
    flags : Int32
  end

  struct GlyphSlotRec # accessed fields only (LP64 offsets in comments)
    pad0 : UInt8[112]            # library..metrics (48 + 64)
    linear_hori_advance : Long   # @112
    linear_vert_advance : Long   # @120
    advance : Vector             # @128
    format : Int32               # @144
    pad2 : Int32                 # @148
    bitmap : Bitmap              # @152
    bitmap_left : Int32          # @192
    bitmap_top : Int32           # @196
    outline : OutlineRec         # @200
  end

  struct FaceRec # accessed fields only (LP64 offsets in comments)
    num_faces : Long   # @0
    face_index : Long  # @8
    face_flags : Long  # @16
    style_flags : Long # @24
    num_glyphs : Int32 # @32
    pad0 : UInt8[100]  # @36..136: family_name .. bbox
    units_per_em : UInt16 # @136
    ascender : Int16      # @138
    descender : Int16     # @140
    pad1 : UInt8[10]      # @142..152
    glyph : GlyphSlotRec* # @152
    size : Void*          # @160
  end

  fun init_free_type = FT_Init_FreeType(a_library : Void**) : Int32
  fun property_set = FT_Property_Set(library : Void*, module_name : UInt8*,
                                     property_name : UInt8*, value : Void*) : Int32
  fun new_memory_face = FT_New_Memory_Face(library : Void*, file_base : UInt8*,
                                           file_size : Long, face_index : Long,
                                           a_face : FaceRec**) : Int32
  fun set_pixel_sizes = FT_Set_Pixel_Sizes(face : FaceRec*, pixel_width : UInt32,
                                           pixel_height : UInt32) : Int32
  fun get_char_index = FT_Get_Char_Index(face : FaceRec*, char_code : UInt32) : UInt32
  fun load_glyph = FT_Load_Glyph(face : FaceRec*, glyph_index : UInt32,
                                 load_flags : Int32) : Int32
  fun set_var_design = FT_Set_Var_Design_Coordinates(face : FaceRec*, num_coords : UInt32,
                                                     coords : Long*) : Int32
  fun render_glyph = FT_Render_Glyph(slot : GlyphSlotRec*, render_mode : Int32) : Int32
  fun done_face = FT_Done_Face(face : FaceRec*) : Int32
  fun done_free_type = FT_Done_FreeType(library : Void*) : Int32
end

# An FT_Outline snapshot (26.6, y up), copied out of the glyph slot.
struct Snapshot
  getter xs : Array(Int64)
  getter ys : Array(Int64)
  getter tags : Array(UInt8)
  getter contours : Array(Int32)
  getter flags : Int32

  def initialize(ol : LibFT::OutlineRec)
    n = ol.n_points
    @xs = Array(Int64).new(n) { |i| ol.points[i].x }
    @ys = Array(Int64).new(n) { |i| ol.points[i].y }
    @tags = Array(UInt8).new(n) { |i| ol.tags[i] }
    @contours = Array(Int32).new(ol.n_contours) { |i| ol.contours[i].to_i32 }
    @flags = ol.flags
  end

  def to_outline : Ftgrays::Outline
    Ftgrays::Outline.new(@xs, @ys, @tags, @contours, @flags)
  end

  def ==(other : Snapshot)
    @xs == other.xs && @ys == other.ys && @tags == other.tags &&
      @contours == other.contours
  end
end

def load_outline(face, gid, flags) : Snapshot?
  return nil if LibFT.load_glyph(face, gid, flags) != 0
  ol = face.value.glyph.value.outline
  return nil if ol.n_points == 0 || ol.n_contours == 0
  Snapshot.new(ol)
end

# FT_New_Memory_Face does not copy the font buffer. Crystal's
# Pointer#malloc goes through the Boehm GC: once the compiler considers
# the FtFace wrapper dead, the GC may hand the bytes to something else
# while the live face keeps reading them (observed as FT
# Invalid_Argument storms in long benchmark loops). Allocate through
# libc malloc instead — memory the GC never touches or reuses. The
# process frees it at exit; FtFace has no done path by design.
class FtFace
  getter face : LibFT::FaceRec*

  def initialize(library : Void*, path : String, face_index : Int32 = 0)
    data = File.read(path)
    @buf = LibC.malloc(data.bytesize)
    data.to_unsafe.copy_to(@buf.as(UInt8*), data.bytesize)
    @face = Pointer(LibFT::FaceRec).null
    err = LibFT.new_memory_face(library, @buf.as(UInt8*), data.bytesize,
                                face_index.to_i64, pointerof(@face))
    raise "FT_New_Memory_Face(#{path}##{face_index}) failed: #{err}" if err != 0
  end

  def done : Nil
    LibFT.done_face(@face)
  end
end

# The oracle: an 8-bit coverage bitmap rasterized by the system FreeType
# (FT gray bitmaps are top-down, pitch = row stride).
struct OracleBitmap
  getter width : Int32
  getter height : Int32
  getter left : Int32
  getter top : Int32
  getter cov : Bytes

  def initialize(slot : LibFT::GlyphSlotRec)
    bmp = slot.bitmap
    @width = bmp.width
    @height = bmp.rows
    @left = slot.bitmap_left
    @top = slot.bitmap_top
    w = bmp.width
    cov = Bytes.new(w * bmp.rows)
    bmp.rows.times do |r|
      src = bmp.buffer + r * bmp.pitch
      w.times { |c| cov[r * w + c] = src[c] }
    end
    @cov = cov
  end
end

require "../src/ftrender"

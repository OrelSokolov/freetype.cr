# Crystal port of FreeType's TrueType bytecode interpreter
# (`~/freetype/src/truetype/ttinterp.c`, snapshot 2.14.3).
#
# Compiled-for configuration replicated here:
#   TT_CONFIG_OPTION_BYTECODE_INTERPRETER       ON
#   TT_CONFIG_OPTION_SUBPIXEL_HINTING           ON
#     (=> TT_SUPPORT_SUBPIXEL_HINTING_MINIMAL: all v40 "minimal" branches
#         are ported as runtime behavior gated on `interpreter_version == 40`)
#   FT_DEBUG_LEVEL_TRACE                        OFF (no tracing)
#   TT_CONFIG_OPTION_INTERPRETER_SWITCH         irrelevant (plain switch)
#   TT_CONFIG_OPTION_GX_VAR_SUPPORT             represented by the optional
#         `variation_coords` property (nil == no variation instance, which is
#         what a plain FT_Open_Face without MM calls behaves like)
#
# Bit-exactness rules (same conventions as src/ftgrays.cr):
#   * LP64 C widths are kept per field: FT_Long/FT_Pos/FT_Fixed/FT_F26Dot6
#     are Int64, FT_Int/FT_UInt/FT_Int32 are Int32, F2Dot14 is Int16.
#   * all arithmetic that C may overflow uses wrapping operators (&+ &- &*)
#     with explicit .to_i32!/.to_u32!/.to_u64! bit-reinterpreting casts;
#   * `/` is C integer division -> `tdiv` (truncation toward zero);
#   * `>>` is the arithmetic shift, `>>` on UInt32 is logical, like C;
#   * BOUNDS(x, n) is `(FT_UInt)(x) >= (FT_UInt)(n)` (32-bit), BOUNDSL is
#     the 64-bit flavor; both truncate/reinterpret before comparing.
#
# C's `exc->error` + return-from-TT_RunIns is modeled by raising
# TT::ExecutionError; the "ignore errors unless pedantic" policy of
# Excute_Glyph-level callers stays in the glue code (step B3).

module TT
  # Per-instruction trace to STDERR, mirroring the C interpreter's
  # FT_DEBUG_LEVEL_TRACE dump (opcode + top-of-stack). Enable with TT_TRACE=1.
  TRACE_ENABLED = ENV["TT_TRACE"]? == "1"

  class ExecutionError < Exception
    getter code : Int32

    def initialize(@code : Int32, message : String)
      super(message)
    end
  end

  # FT error codes as produced by FT_THROW with FT_Mod_Err_TrueType = 0x1200.
  ERR_INVALID_OPCODE            = 0x1200 + 0x80
  ERR_TOO_FEW_ARGUMENTS         = 0x1200 + 0x81
  ERR_STACK_OVERFLOW            = 0x1200 + 0x82
  ERR_CODE_OVERFLOW             = 0x1200 + 0x83
  ERR_BAD_ARGUMENT              = 0x1200 + 0x84
  ERR_DIVIDE_BY_ZERO            = 0x1200 + 0x85
  ERR_INVALID_REFERENCE         = 0x1200 + 0x86
  ERR_DEBUG_OPCODE              = 0x1200 + 0x87
  ERR_ENDF_IN_EXEC_STREAM       = 0x1200 + 0x88
  ERR_NESTED_DEFS               = 0x1200 + 0x89
  ERR_INVALID_CODERANGE         = 0x1200 + 0x8A
  ERR_EXECUTION_TOO_LONG        = 0x1200 + 0x8B
  ERR_TOO_MANY_FUNCTION_DEFS    = 0x1200 + 0x8C
  ERR_TOO_MANY_INSTRUCTION_DEFS = 0x1200 + 0x8D
  ERR_DEF_IN_GLYF_BYTECODE      = 0x1200 + 0x9C

  TT_CONFIG_OPTION_MAX_RUNNABLE_OPCODES = 1_000_000_u64

  # FT_Render_Mode constants (only the equality tests matter).
  RENDER_MODE_NORMAL = 0
  RENDER_MODE_LIGHT  = 1
  RENDER_MODE_MONO   = 2
  RENDER_MODE_LCD    = 3
  RENDER_MODE_LCD_V  = 4

  # Code range tags.
  CODERANGE_NONE  = 0
  CODERANGE_FONT  = 1
  CODERANGE_CVT   = 2
  CODERANGE_GLYPH = 3

  # Rounding state constants (ttinterp.h).
  ROUND_TO_HALF_GRID   = 0
  ROUND_TO_GRID        = 1
  ROUND_TO_DOUBLE_GRID = 2
  ROUND_DOWN_TO_GRID   = 3
  ROUND_UP_TO_GRID     = 4
  ROUND_OFF            = 5
  ROUND_SUPER          = 6
  ROUND_SUPER_45       = 7

  # Selector values of the current rounding/projection/move function
  # pointers (the C `func_round`, `func_project`, ... fields).
  ROUND_FUNC_NONE     = 0
  ROUND_FUNC_TO_GRID  = 1
  ROUND_FUNC_TO_HALF  = 2
  ROUND_FUNC_TO_DOUBLE = 3
  ROUND_FUNC_DOWN     = 4
  ROUND_FUNC_UP       = 5
  ROUND_FUNC_SUPER    = 6
  ROUND_FUNC_SUPER_45 = 7

  PROJECT_FUNC_GENERIC = 0
  PROJECT_FUNC_X       = 1
  PROJECT_FUNC_Y       = 2

  MOVE_FUNC_GENERIC = 0
  MOVE_FUNC_X       = 1
  MOVE_FUNC_Y       = 2

  # FT_CURVE_TAG_* (ftimage.h).
  CURVE_TAG_ON         = 0x01_u8
  CURVE_TAG_TOUCH_X    = 0x08_u8
  CURVE_TAG_TOUCH_Y    = 0x10_u8
  CURVE_TAG_TOUCH_BOTH = 0x18_u8

  # FT_GASP flags used by tt_face_get_cleartype_policy.
  FT_GASP_GRIDFIT             = 0x01
  FT_GASP_DOGRAY              = 0x02
  FT_GASP_SYMMETRIC_GRIDFIT   = 0x0004
  FT_GASP_SYMMETRIC_SMOOTHING = 0x0008

  # Interpreter versions (FT_TT_INTERPRETER_VERSION_xx).
  INTERPRETER_VERSION_35 = 35
  INTERPRETER_VERSION_40 = 40

  # A glyph zone: the TT_GlyphZoneRec subset the interpreter consumes.
  #
  #   n_points   current number of points (includes 4 phantom points in the
  #              glyph zone; the interpreter reads and clamps this)
  #   n_contours current number of contours
  #   cur_x/cur_y     current (scaled, hinted) coordinates, Int64 26.6
  #   org_x/org_y     original (scaled, unhinted) coordinates, Int64 26.6
  #   orus_x/orus_y   original *unscaled* coordinates (font units as loaded);
  #                   used by MD/IP/IUP for glyph-zone measurements; the
  #                   twilight zone never dereferences them (like in C)
  #   tags        touch/on-curve flags (FT_CURVE_TAG_*)
  #   contours    index of each contour's last point
  #   first_point offset of point #0 (used by SHC on composite sub-zones)
  class Zone
    property n_points : Int32
    property n_contours : Int32
    property cur_x : Array(Int64)
    property cur_y : Array(Int64)
    property org_x : Array(Int64)
    property org_y : Array(Int64)
    property orus_x : Array(Int64)
    property orus_y : Array(Int64)
    property tags : Array(UInt8)
    property contours : Array(Int32)
    property first_point : Int32 = 0

    def initialize(@n_points : Int32, @n_contours : Int32,
                   @cur_x : Array(Int64), @cur_y : Array(Int64),
                   @org_x : Array(Int64), @org_y : Array(Int64),
                   @orus_x : Array(Int64), @orus_y : Array(Int64),
                   @tags : Array(UInt8), @contours : Array(Int32),
                   @first_point : Int32 = 0)
    end

    # A zeroed zone with capacity for `n` points and `c` contours
    # (tt_glyphzone_new in ttobjs.c).
    def self.new_capacity(n : Int32, c : Int32) : self
      new(n, c,
        Array(Int64).new(n, 0_i64), Array(Int64).new(n, 0_i64),
        Array(Int64).new(n, 0_i64), Array(Int64).new(n, 0_i64),
        Array(Int64).new(n, 0_i64), Array(Int64).new(n, 0_i64),
        Array(UInt8).new(n, 0_u8), Array(Int32).new(c, 0))
    end
  end

  # TT_GraphicsState (ttobjs.h) with TT_Default_GraphicsState values
  # (ttinterp.c:106) as the defaults.
  #
  # delta_base/delta_shift/instruct_control/scan_type are FT_UShort/FT_Byte
  # in C; the interpreter always stores the (masked) values through the
  # same casts, so they are kept as Int64 here for glue convenience.
  class GraphicsState
    property rp0 : Int32 = 0
    property rp1 : Int32 = 0
    property rp2 : Int32 = 0

    property gep0 : Int32 = 1
    property gep1 : Int32 = 1
    property gep2 : Int32 = 1

    # FT_UnitVector components are FT_F2Dot14 (Int16); kept sign-extended
    # in Int32 but always assigned through to_i16! casts.
    property dual_vector_x : Int32 = 0x4000
    property dual_vector_y : Int32 = 0
    property proj_vector_x : Int32 = 0x4000
    property proj_vector_y : Int32 = 0
    property free_vector_x : Int32 = 0x4000
    property free_vector_y : Int32 = 0

    property loop : Int64 = 1
    property round_state : Int32 = ROUND_TO_GRID
    property compensation : Array(Int64) = [0_i64, 0_i64, 0_i64, 0_i64]

    property minimum_distance : Int64 = 64
    property control_value_cutin : Int64 = 68
    property single_width_cutin : Int64 = 0
    property single_width_value : Int64 = 0
    property delta_base : Int64 = 9
    property delta_shift : Int64 = 3

    property auto_flip : Bool = true
    property instruct_control : Int64 = 0
    property scan_control : Bool = false
    property scan_type : Int64 = 0

    def initialize
    end

    def self.default : GraphicsState
      new
    end

    # Struct assignment (C `a = b`).
    def assign(other : GraphicsState) : self
      @rp0 = other.rp0
      @rp1 = other.rp1
      @rp2 = other.rp2
      @gep0 = other.gep0
      @gep1 = other.gep1
      @gep2 = other.gep2
      @dual_vector_x = other.dual_vector_x
      @dual_vector_y = other.dual_vector_y
      @proj_vector_x = other.proj_vector_x
      @proj_vector_y = other.proj_vector_y
      @free_vector_x = other.free_vector_x
      @free_vector_y = other.free_vector_y
      @loop = other.loop
      @round_state = other.round_state
      4.times { |i| @compensation[i] = other.compensation[i] }
      @minimum_distance = other.minimum_distance
      @control_value_cutin = other.control_value_cutin
      @single_width_cutin = other.single_width_cutin
      @single_width_value = other.single_width_value
      @delta_base = other.delta_base
      @delta_shift = other.delta_shift
      @auto_flip = other.auto_flip
      @instruct_control = other.instruct_control
      @scan_control = other.scan_control
      @scan_type = other.scan_type
      self
    end

    def dup : GraphicsState
      GraphicsState.new.assign(self)
    end
  end

  # TT_DefRecord (ttinterp.h): one FDEF or IDEF body. `start_`/`end_` are
  # instruction-pointer offsets inside code_range_table[range - 1]'s Bytes.
  class DefRecord
    property range : Int32 = 0
    property start_ : Int64 = 0_i64
    property end_ : Int64 = 0_i64
    property opc : Int32 = 0
    property active : Bool = false
  end

  # TT_CallRec (ttinterp.h).
  class CallRec
    property caller_range : Int32 = 0
    property caller_ip : Int64 = 0_i64
    property cur_count : Int64 = 0_i64
    property def_rec : DefRecord? = nil
  end

  # Pop_Push_Count[256]: (pops << 4) | pushes, verbatim from ttinterp.c.
  POP_PUSH_COUNT = [
    # 0x00
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x02, 0x02, 0x00, 0x50,
    # 0x10
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x00, 0x00, 0x10, 0x00, 0x10, 0x10, 0x10, 0x10,
    # 0x20
    0x12, 0x10, 0x00, 0x22, 0x01, 0x11, 0x10, 0x20, 0x00, 0x10, 0x20, 0x10, 0x10, 0x00, 0x10, 0x10,
    # 0x30
    0x00, 0x00, 0x00, 0x00, 0x10, 0x10, 0x10, 0x10, 0x10, 0x00, 0x20, 0x20, 0x00, 0x00, 0x20, 0x20,
    # 0x40
    0x00, 0x00, 0x20, 0x11, 0x20, 0x11, 0x11, 0x11, 0x20, 0x21, 0x21, 0x01, 0x01, 0x00, 0x00, 0x10,
    # 0x50
    0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x11, 0x11, 0x10, 0x00, 0x21, 0x21, 0x11, 0x10, 0x10, 0x10,
    # 0x60
    0x21, 0x21, 0x21, 0x21, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
    # 0x70
    0x20, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x10, 0x10,
    # 0x80
    0x00, 0x20, 0x20, 0x00, 0x00, 0x10, 0x20, 0x20, 0x11, 0x10, 0x33, 0x21, 0x21, 0x10, 0x20, 0x00,
    # 0x90
    0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    # 0xA0
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    # 0xB0
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    # 0xC0
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    # 0xD0
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    # 0xE0
    0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    # 0xF0
    0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
  ] of UInt8

  # opcode_length[256], verbatim from ttinterp.c (-1 for NPUSHB, -2 for
  # NPUSHW).
  OPCODE_LENGTH = [
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    -1, -2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 3, 4, 5, 6, 7, 8, 9, 3, 5, 7, 9, 11, 13, 15, 17,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  ] of Int8

  # The interpreter (TT_ExecContextRec). See the class-level docs of the
  # properties for the caller (glue) contract.
  class ExecContext
    @max_fdefs : Int32
    @max_idefs : Int32
    @max_stack : Int32

    # execution state
    @error : Int32 = 0                    # unused, kept for symmetry
    @top : Int64 = 0
    @stack_size : Int64
    @stack : Array(Int64)
    @args_base : Int64 = 0                # exc->args
    @new_top : Int64 = 0

    @zp0 : Zone
    @zp1 : Zone
    @zp2 : Zone

    @gs : GraphicsState = GraphicsState.new
    # `size->GS`: what TT_Run_Context resets @gs from, and what
    # TT_Save_Context persists into after `fpgm'/'prep' runs.
    @saved_gs : GraphicsState = GraphicsState.default

    @ini_range : Int32 = 0
    @cur_range : Int32 = 0
    @code : Bytes = Bytes.new(0)
    @ip : Int64 = 0
    @code_size : Int64 = 0

    @opcode : UInt8 = 0_u8
    @length : Int32 = 1

    # cvt: current working copy (@cvt) and the persistent base (@cvt_base).
    # During glyph-program execution the first write clones the base into
    # @glyf_cvt (Modify_CVT_Check in ttinterp.c) and switches @cvt to it.
    @cvt_base : Array(Int64)
    @cvt : Array(Int64)
    @glyf_cvt : Array(Int64)? = nil

    @num_fdefs : Int32 = 0
    @fdefs : Array(DefRecord)
    @num_idefs : Int32 = 0
    @idefs : Array(DefRecord)
    @max_func : Int32 = 0
    @max_ins : Int32 = 0

    @call_top : Int32 = 0
    @call_size : Int32 = 32
    @call_stack : Array(CallRec)

    @code_range_table : Array({Bytes, Int64}) =
      Array({Bytes, Int64}).new(3, {Bytes.new(0), 0_i64})

    @storage_base : Array(Int64)
    @storage : Array(Int64)
    @glyf_storage : Array(Int64)? = nil

    # super rounding state
    @period : Int64 = 0
    @phase : Int64 = 0
    @threshold : Int64 = 0

    @instruction_trap : Bool = false

    # function selectors (C function pointers)
    @func_round : Int32 = ROUND_FUNC_TO_GRID
    @func_project : Int32 = PROJECT_FUNC_GENERIC
    @func_dualproj : Int32 = PROJECT_FUNC_GENERIC
    @func_move : Int32 = MOVE_FUNC_GENERIC
    @func_move_orig : Int32 = MOVE_FUNC_GENERIC
    @func_cur_ppem_stretched : Bool = false
    @func_cvt_stretched : Bool = false

    # "projected" freedom vector (Compute_Funcs)
    @move_vector_x : Int64 = 0
    @move_vector_y : Int64 = 0

    # v40 subpixel state
    @native_cleartype_x : Bool = false
    @backward_compatibility : Int32 = 0

    # loop detectors
    @loopcall_counter : UInt64 = 0
    @loopcall_counter_max : UInt64 = 0
    @neg_jump_counter : UInt64 = 0
    @neg_jump_counter_max : UInt64 = 0
    @ins_counter : UInt64 = 0

    # ---- caller-visible state (the "size"/"face" subset) ----
    @point_size : Int64 = 0                      # size->point_size (26.6)
    @tt_scale : Int64 = 0x10000                  # tt_metrics.scale (16.16)
    @tt_ppem : Int32 = 0                         # tt_metrics.ppem
    @tt_x_ratio : Int64 = 0x10000                # tt_metrics.x_ratio
    @tt_y_ratio : Int64 = 0x10000                # tt_metrics.y_ratio
    @tt_ratio : Int64 = 0x10000                  # tt_metrics.ratio (cache)
    @tt_rotated : Bool = false
    @tt_stretched : Bool = false
    @metrics_x_scale : Int64 = 0x10000           # metrics.x_scale
    @metrics_y_scale : Int64 = 0x10000           # metrics.y_scale
    @metrics_x_ppem : Int32 = 0
    @metrics_y_ppem : Int32 = 0

    @pts : Zone
    @twilight : Zone

    @cvt_raw : Array(Int64) = Array(Int64).new(0, 0_i64)

    @is_composite : Bool = false
    @pedantic_hinting : Bool = false
    @grayscale : Bool = false
    @render_mode : Int32 = RENDER_MODE_NORMAL
    @interpreter_version : Int32 = INTERPRETER_VERSION_40
    @is_tricky : Bool = false
    @num_glyphs : Int32 = 65536
    # GX variation instance (face->blend): nil == no variation instance.
    @variation_coords : Array(Int64)? = nil
    # cleartype policy inputs (tt_face_get_cleartype_policy)
    @max_size_of_instructions : Int32 = 0
    @gasp_version : Int32 = 0
    @gasp_ranges : Array(Tuple(Int32, Int32)) = Array(Tuple(Int32, Int32)).new(0)

    # `max_functions`  = maxp.maxFunctionDefs
    # `max_instruction_defs` = maxp.maxInstructionDefs
    # `max_storage` = maxp.maxStorage
    # `max_stack`   = maxp.maxStackElements + max(maxStackElements/2, 128)
    #                (tt_size_init_bytecode in ttobjs.c does this padding;
    #                 pass the padded value or pad here)
    # `max_twilight` = maxp.maxTwilightPoints + 4
    def initialize(max_functions : Int32, max_instruction_defs : Int32,
                   max_storage : Int32, max_stack : Int32, max_twilight : Int32)
      @max_fdefs = max_functions
      @max_idefs = max_instruction_defs
      @max_stack = max_stack
      @stack_size = max_stack.to_i64
      @stack = Array(Int64).new(max_stack, 0_i64)
      @cvt_base = Array(Int64).new(0, 0_i64)
      @cvt = @cvt_base
      @storage_base = Array(Int64).new(max_storage, 0_i64)
      @storage = @storage_base
      @fdefs = Array(DefRecord).new(max_functions) { DefRecord.new }
      @idefs = Array(DefRecord).new(max_instruction_defs) { DefRecord.new }
      @call_stack = Array(CallRec).new(32) { CallRec.new }
      @pts = Zone.new_capacity(0, 0)
      @twilight = Zone.new_capacity(max_twilight, 0)
      @zp0 = @pts
      @zp1 = @pts
      @zp2 = @pts
    end

    # ---- glue-visible properties -----------------------------------------

    # Graphics state: current (as used by the bytecode) and the persisted
    # copy that run_context resets from / run_(fpgm|prep) saves to.
    def graphics_state : GraphicsState
      @gs
    end

    def graphics_state=(gs : GraphicsState)
      @gs = gs
      @saved_gs = gs.dup
    end

    def saved_graphics_state : GraphicsState
      @saved_gs
    end

    def saved_graphics_state=(gs : GraphicsState)
      @saved_gs = gs
    end

    def zp0 : Zone
      @zp0
    end

    def zp0=(z : Zone)
      @zp0 = z
    end

    def zp1 : Zone
      @zp1
    end

    def zp1=(z : Zone)
      @zp1 = z
    end

    def zp2 : Zone
      @zp2
    end

    def zp2=(z : Zone)
      @zp2 = z
    end

    # The glyph zone. The caller assigns a freshly loaded/scaled zone
    # (with org copied from cur, plus orus) before `run`.
    def pts : Zone
      @pts
    end

    def pts=(z : Zone)
      @pts = z
    end

    # The twilight zone (persistent across glyphs, like size->twilight).
    def twilight : Zone
      @twilight
    end

    def twilight=(z : Zone)
      @twilight = z
    end

    # Current CVT (the per-glyph working copy while a glyph program runs).
    # Assigning replaces the persistent base and drops any working copy.
    def cvt : Array(Int64)
      @cvt
    end

    def cvt=(a : Array(Int64))
      @cvt_base = a
      @cvt = a
      @glyf_cvt = nil
    end

    # The persistent CVT (what the next run starts from).
    def cvt_base : Array(Int64)
      @cvt_base
    end

    def cvt_base=(a : Array(Int64))
      @cvt_base = a
      @cvt = a
      @glyf_cvt = nil
    end

    # Unscaled CVT from the `cvt ' table (26.6 font units, FT_Int32 values);
    # run_prep scales it by tt_scale into cvt_base.
    def cvt_raw : Array(Int64)
      @cvt_raw
    end

    def cvt_raw=(a : Array(Int64))
      @cvt_raw = a
    end

    def storage : Array(Int64)
      @storage
    end

    def storage=(a : Array(Int64))
      @storage_base = a
      @storage = a
      @glyf_storage = nil
    end

    def storage_base : Array(Int64)
      @storage_base
    end

    def stack : Array(Int64)
      @stack
    end

    def top : Int64
      @top
    end

    def funcs : Array(DefRecord)
      @fdefs
    end

    def instruction_defs : Array(DefRecord)
      @idefs
    end

    def num_funcs : Int32
      @num_fdefs
    end

    def num_instruction_defs : Int32
      @num_idefs
    end

    def max_func : Int32
      @max_func
    end

    def max_ins : Int32
      @max_ins
    end

    def instruction_trap : Bool
      @instruction_trap
    end

    def instruction_trap=(v : Bool)
      @instruction_trap = v
    end

    def backward_compatibility : Int32
      @backward_compatibility
    end

    def backward_compatibility=(v : Int32)
      @backward_compatibility = v
    end

    def native_cleartype_x : Bool
      @native_cleartype_x
    end

    # number of instructions executed by the last run
    def ins_counter : UInt64
      @ins_counter
    end

    def loopcall_counter : UInt64
      @loopcall_counter
    end

    def loopcall_counter_max : UInt64
      @loopcall_counter_max
    end

    def neg_jump_counter : UInt64
      @neg_jump_counter
    end

    # metrics the glue sets per size (TT_Size_Metrics + FT_Size_Metrics)
    def point_size : Int64
      @point_size
    end

    def point_size=(v : Int64)
      @point_size = v
    end

    def ppem : Int32
      @tt_ppem
    end

    def ppem=(v : Int32)
      @tt_ppem = v
    end

    def tt_scale : Int64
      @tt_scale
    end

    def tt_scale=(v : Int64)
      @tt_scale = v
    end

    def scale_x : Int64
      @metrics_x_scale
    end

    def scale_x=(v : Int64)
      @metrics_x_scale = v
    end

    def scale_y : Int64
      @metrics_y_scale
    end

    def scale_y=(v : Int64)
      @metrics_y_scale = v
    end

    def x_ppem : Int32
      @metrics_x_ppem
    end

    def x_ppem=(v : Int32)
      @metrics_x_ppem = v
    end

    def y_ppem : Int32
      @metrics_y_ppem
    end

    def y_ppem=(v : Int32)
      @metrics_y_ppem = v
    end

    def x_ratio : Int64
      @tt_x_ratio
    end

    def x_ratio=(v : Int64)
      @tt_x_ratio = v
    end

    def y_ratio : Int64
      @tt_y_ratio
    end

    def y_ratio=(v : Int64)
      @tt_y_ratio = v
    end

    def ratio : Int64
      @tt_ratio
    end

    def ratio=(v : Int64)
      @tt_ratio = v
    end

    def rotated : Bool
      @tt_rotated
    end

    def rotated=(v : Bool)
      @tt_rotated = v
    end

    def stretched : Bool
      @tt_stretched
    end

    def stretched=(v : Bool)
      @tt_stretched = v
    end

    def is_composite : Bool
      @is_composite
    end

    def is_composite=(v : Bool)
      @is_composite = v
    end

    def pedantic_hinting : Bool
      @pedantic_hinting
    end

    def pedantic_hinting=(v : Bool)
      @pedantic_hinting = v
    end

    def grayscale : Bool
      @grayscale
    end

    def grayscale=(v : Bool)
      @grayscale = v
    end

    # one of RENDER_MODE_*; affects GETINFO and the v40 gates
    def render_mode : Int32
      @render_mode
    end

    def render_mode=(v : Int32)
      @render_mode = v
    end

    # 35 or 40 (FT_TT_INTERPRETER_VERSION_xx)
    def interpreter_version : Int32
      @interpreter_version
    end

    def interpreter_version=(v : Int32)
      @interpreter_version = v
    end

    def is_tricky : Bool
      @is_tricky
    end

    def is_tricky=(v : Bool)
      @is_tricky = v
    end

    def num_glyphs : Int32
      @num_glyphs
    end

    def num_glyphs=(v : Int32)
      @num_glyphs = v
    end

    def variation_coords : Array(Int64)?
      @variation_coords
    end

    def variation_coords=(v : Array(Int64)?)
      @variation_coords = v
    end

    def max_size_of_instructions : Int32
      @max_size_of_instructions
    end

    def max_size_of_instructions=(v : Int32)
      @max_size_of_instructions = v
    end

    def gasp_version : Int32
      @gasp_version
    end

    def gasp_version=(v : Int32)
      @gasp_version = v
    end

    # array of {maxPPEM, gaspFlag} pairs
    def gasp_ranges : Array(Tuple(Int32, Int32))
      @gasp_ranges
    end

    def gasp_ranges=(v : Array(Tuple(Int32, Int32)))
      @gasp_ranges = v
    end

    # ---- fixed point helpers (ftcalc.c / fttrigon.c replicas) ------------

    private def err(code : Int32, msg : String) : NoReturn
      raise ExecutionError.new(code, msg)
    end

    # BOUNDS(x, n): (FT_UInt)(x) >= (FT_UInt)(n)
    private def bounds32?(x : Int64, n : Int32) : Bool
      x.to_u32! >= n.to_u32!
    end

    private def bounds32?(x : Int64, n : Int64) : Bool
      x.to_u32! >= n.to_u32!
    end

    private def bounds32?(x : Int32, n : Int32) : Bool
      x.to_u32! >= n.to_u32!
    end

    # BOUNDSL(x, n): (FT_ULong)(x) >= (FT_ULong)(n)
    private def boundsl?(x : Int64, n : Int64) : Bool
      x.to_u64! >= n.to_u64!
    end

    private def boundsl?(x : Int64, n : Int32) : Bool
      x.to_u64! >= n.to_u64!
    end

    # (FT_UShort) cast
    private def to_ushort(v : Int64) : Int32
      (v & 0xFFFF).to_i32!
    end

    # (FT_Short) cast: sign-extend the low 16 bits
    private def to_short(v : Int64) : Int64
      ((v & 0xFFFF).to_i16!).to_i64
    end

    # FT_MulFix (ftcalc.c, FT_INT64 path).
    private def ft_mulfix(a : Int64, b : Int64) : Int64
      ab = a &* b
      ab = ab &+ 0x8000_i64 &+ (ab >> 63)
      ab >> 16
    end

    # FT_MulDiv (ftcalc.c, FT_INT64 path): round-half-away result of a*b/c
    # computed in unsigned 64-bit, exactly like FT_MulDiv_64.
    private def ft_muldiv(a_ : Int64, b_ : Int64, c_ : Int64) : Int64
      s = 1
      a = a_ < 0 ? (0_u64 &- a_.to_u64!) : a_.to_u64!
      s = -s if a_ < 0
      b = b_ < 0 ? (0_u64 &- b_.to_u64!) : b_.to_u64!
      s = -s if b_ < 0
      c = c_ < 0 ? (0_u64 &- c_.to_u64!) : c_.to_u64!
      s = -s if c_ < 0

      d = c > 0 ? (a &* b &+ (c >> 1)) // c : 0x7FFFFFFF_u64
      d_ = d.to_i64!
      s < 0 ? (0_i64 &- d_) : d_
    end

    # FT_MulDiv_No_Round (ftcalc.c, FT_INT64 path).
    private def ft_muldiv_no_round(a_ : Int64, b_ : Int64, c_ : Int64) : Int64
      s = 1
      a = a_ < 0 ? (0_u64 &- a_.to_u64!) : a_.to_u64!
      s = -s if a_ < 0
      b = b_ < 0 ? (0_u64 &- b_.to_u64!) : b_.to_u64!
      s = -s if b_ < 0
      c = c_ < 0 ? (0_u64 &- c_.to_u64!) : c_.to_u64!
      s = -s if c_ < 0

      d = c > 0 ? (a &* b) // c : 0x7FFFFFFF_u64
      d_ = d.to_i64!
      s < 0 ? (0_i64 &- d_) : d_
    end

    # FT_DivFix (ftcalc.c, FT_INT64 path).
    private def ft_divfix(a_ : Int64, b_ : Int64) : Int64
      s = 1
      a = a_ < 0 ? (0_u64 &- a_.to_u64!) : a_.to_u64!
      s = -s if a_ < 0
      b = b_ < 0 ? (0_u64 &- b_.to_u64!) : b_.to_u64!
      s = -s if b_ < 0

      q = b > 0 ? ((a &* 0x10000_u64) &+ (b >> 1)) // b : 0x7FFFFFFF_u64
      q_ = q.to_i64!
      s < 0 ? (0_i64 &- q_) : q_
    end

    # FT_PIX_FLOOR / FT_PIX_ROUND_LONG / FT_PIX_CEIL_LONG / FT_PAD_ROUND_LONG
    private def pix_floor(x : Int64) : Int64
      x & ~63_i64
    end

    private def pix_round_long(x : Int64) : Int64
      (x &+ 32) & ~63_i64
    end

    private def pix_ceil_long(x : Int64) : Int64
      (x &+ 63) & ~63_i64
    end

    private def pad_round_long(x : Int64, n : Int64) : Int64
      (x &+ (n // 2)) & ~(n - 1)
    end

    # TT_MulFix14_64 (ttinterp.c): (a*b)/2^14 rounded, Int64.
    private def tt_mulfix14(a : Int64, b : Int32) : Int64
      ab = a &* b.to_i64
      ab = ab &+ 0x2000_i64 &+ (ab >> 63)
      ab >> 14
    end

    # TT_DotFix14 (ttinterp.c): (ax*bx+ay*by)/2^14 rounded, Int64.
    private def tt_dotfix14(ax : Int64, ay : Int64, bx : Int32, by : Int32) : Int64
      c = ax &* bx.to_i64 &+ ay &* by.to_i64
      c = c &+ 0x2000_i64 &+ (c >> 63)
      c >> 14
    end

    # FT_MSB fallback (ftcalc.c).
    private def ft_msb(z0 : UInt32) : Int32
      z = z0
      shift = 0
      if z & 0xFFFF0000_u32 != 0
        z >>= 16
        shift += 16
      end
      if z & 0x0000FF00_u32 != 0
        z >>= 8
        shift += 8
      end
      if z & 0x000000F0_u32 != 0
        z >>= 4
        shift += 4
      end
      if z & 0x0000000C_u32 != 0
        z >>= 2
        shift += 2
      end
      if z & 0x00000002_u32 != 0
        shift += 1
      end
      shift
    end

    # FT_Vector_NormLen (ftcalc.c). Normalizes (x0, y0) to 16.16 and
    # returns {nx, ny, len} (len is UInt32 like the C return).
    private def ft_vector_norm_len(x0 : Int64, y0 : Int64) : {Int64, Int64, UInt32}
      x_ = x0.to_i32!
      y_ = y0.to_i32!
      sx = x_ < 0 ? -1 : 1
      sy = y_ < 0 ? -1 : 1

      x = x_ < 0 ? (0_u32 &- x_.to_u32!) : x_.to_u32!
      y = y_ < 0 ? (0_u32 &- y_.to_u32!) : y_.to_u32!

      if x == 0
        if y > 0
          return {x0, sy.to_i64 &* 0x10000_i64, y}
        else
          return {x0, y0, y}
        end
      elsif y == 0
        if x > 0
          return {sx.to_i64 &* 0x10000_i64, y0, x}
        else
          return {x0, y0, x}
        end
      end

      l = x > y ? x &+ (y >> 1) : y &+ (x >> 1)

      shift = 31 - ft_msb(l)
      shift -= 15 + (l >= (0xAAAAAAAA_u32 >> shift) ? 1 : 0)

      if shift > 0
        x = x << shift
        y = y << shift
        l = x > y ? x &+ (y >> 1) : y &+ (x >> 1)
      else
        x = x >> (-shift)
        y = y >> (-shift)
        l = l >> (-shift)
      end

      # lower linear approximation for reciprocal length minus one
      b = 0x10000_i32 &- l.to_i32!

      x_ = x.to_i32!
      y_ = y.to_i32!

      # Newton's iterations
      u = 0_u32
      v = 0_u32
      while true
        u = (x_ &+ ((x_ &* b) >> 16)).to_u32!
        v = (y_ &+ ((y_ &* b) >> 16)).to_u32!

        z = (0_i32 &- (u &* u &+ v &* v).to_i32!).tdiv(0x200)
        z = (z &* ((0x10000_i32 &+ b) >> 8)).tdiv(0x10000)

        b = b &+ z

        break unless z > 0
      end

      nx = sx < 0 ? (0_i64 &- u.to_i64) : u.to_i64
      ny = sy < 0 ? (0_i64 &- v.to_i64) : v.to_i64

      l = (0x10000_i32 &+ (u &* x &+ v &* y).to_i32!.tdiv(0x10000)).to_u32!
      if shift > 0
        l = (l &+ (1_u32 << (shift - 1))) >> shift
      else
        l = l << (-shift)
      end

      {nx, ny, l}
    end

    # ---- fttrigon.c subset used by FT_Hypot -> Current_Ratio ------------

    FT_TRIG_SCALE = 0xDBD95B16_u64

    FT_TRIG_ARCTAN_TABLE = [
      1740967_i64, 919879_i64, 466945_i64, 234379_i64, 117304_i64,
      58666_i64, 29335_i64, 14668_i64, 7334_i64, 3667_i64, 1833_i64,
      917_i64, 458_i64, 229_i64, 115_i64, 57_i64, 29_i64, 14_i64,
      7_i64, 4_i64, 2_i64, 1_i64,
    ] of Int64

    private def ft_abs64(v : Int64) : Int64
      v < 0 ? (0_i64 &- v) : v
    end

    # ft_trig_downscale (FT_INT64 path).
    private def ft_trig_downscale(val : Int64) : Int64
      s = 1
      if val < 0
        val = -val
        s = -1
      end
      val = ((val.to_u64! &* FT_TRIG_SCALE &+ 0x40000000_u64) >> 32).to_i64!
      s < 0 ? (0_i64 &- val) : val
    end

    # ft_trig_prenorm: returns {x, y, shift}.
    private def ft_trig_prenorm(x : Int64, y : Int64) : {Int64, Int64, Int32}
      shift = ft_msb((ft_abs64(x) | ft_abs64(y)).to_u32!)

      if shift <= 29 # FT_TRIG_SAFE_MSB
        shift = 29 - shift
        x = (x.to_u64! << shift).to_i64!
        y = (y.to_u64! << shift).to_i64!
      else
        shift -= 29
        x = x >> shift
        y = y >> shift
        shift = -shift
      end

      {x, y, shift}
    end

    # ft_trig_pseudo_polarize: rotates the vector onto the x axis;
    # returns {pseudo_length, theta}.
    private def ft_trig_pseudo_polarize(x : Int64, y : Int64) : {Int64, Int64}
      if y > x
        if y > -x
          theta = 90_i64 << 16 # FT_ANGLE_PI2
          xtemp = y
          y = 0_i64 &- x
          x = xtemp
        else
          theta = y > 0 ? (180_i64 << 16) : -(180_i64 << 16)
          x = 0_i64 &- x
          y = 0_i64 &- y
        end
      else
        if y < -x
          theta = -(90_i64 << 16)
          xtemp = 0_i64 &- y
          y = x
          x = xtemp
        else
          theta = 0_i64
        end
      end

      i = 1
      b = 1_i64
      k = 0
      while i < 23 # FT_TRIG_MAX_ITERS
        if y > 0
          xtemp = x &+ ((y &+ b) >> i)
          y = y &- ((x &+ b) >> i)
          x = xtemp
          theta &+= FT_TRIG_ARCTAN_TABLE[k]
          k += 1
        else
          xtemp = x &- ((y &+ b) >> i)
          y = y &+ ((x &+ b) >> i)
          x = xtemp
          theta &-= FT_TRIG_ARCTAN_TABLE[k]
          k += 1
        end
        b = b << 1
        i += 1
      end

      # round theta to acknowledge its error
      if theta >= 0
        theta = (theta &+ 8) & ~15_i64
      else
        theta = 0_i64 &- ((0_i64 &- theta &+ 8) & ~15_i64)
      end

      {x, theta}
    end

    # FT_Vector_Length (fttrigon.c).
    private def ft_vector_length(x : Int64, y : Int64) : Int64
      return ft_abs64(y) if x == 0
      return ft_abs64(x) if y == 0

      x, y, shift = ft_trig_prenorm(x, y)
      x, _theta = ft_trig_pseudo_polarize(x, y)

      x = ft_trig_downscale(x)

      if shift > 0
        (x &+ (1_i64 << (shift - 1))) >> shift
      else
        (x.to_u32! << (-shift)).to_i64!
      end
    end

    # ---- coderange functions (ttinterp.c) ---------------------------------

    # TT_Set_CodeRange.
    def set_code_range(range : Int32, base : Bytes) : Nil
      raise ArgumentError.new("bad code range #{range}") unless range >= 1 && range <= 3
      @code_range_table[range - 1] = {base, base.size.to_i64}
      @code = base
      @code_size = base.size.to_i64
      @ip = 0
      @cur_range = range
      @ini_range = range
    end

    # TT_Clear_CodeRange.
    def clear_code_range(range : Int32) : Nil
      raise ArgumentError.new("bad code range #{range}") unless range >= 1 && range <= 3
      @code_range_table[range - 1] = {Bytes.new(0), 0_i64}
    end

    # Ins_Goto_CodeRange.
    private def goto_code_range(a_range : Int32, a_ip : Int64) : Nil
      if a_range < 1 || a_range > 3
        err(ERR_BAD_ARGUMENT, "Ins_Goto_CodeRange: invalid range")
      end

      base, size = @code_range_table[a_range - 1]

      if base.empty? # invalid coderange
        err(ERR_INVALID_CODERANGE, "Ins_Goto_CodeRange: NULL coderange")
      end

      # NOTE: Because the last instruction of a program may be a CALL
      #       which will return to the first byte *after* the code range,
      #       we test for aIP <= Size, instead of aIP < Size.
      if a_ip > size
        err(ERR_CODE_OVERFLOW, "Ins_Goto_CodeRange: address out of range")
      end

      @code = base
      @code_size = size
      @ip = a_ip
      @length = 0
      @cur_range = a_range
    end

    # ---- context load/save (ttinterp.c) ------------------------------------

    # TT_Load_Context: reset the CVT/storage working pointers to the
    # persistent arrays and drop the per-glyph copies.
    private def load_context : Nil
      @cvt = @cvt_base
      @storage = @storage_base
      @glyf_cvt = nil
      @glyf_storage = nil
    end

    # TT_Save_Context: only these GS values survive `fpgm'/'prep'.
    private def save_context : Nil
      @saved_gs.minimum_distance = @gs.minimum_distance
      @saved_gs.control_value_cutin = @gs.control_value_cutin
      @saved_gs.single_width_cutin = @gs.single_width_cutin
      @saved_gs.single_width_value = @gs.single_width_value
      @saved_gs.delta_base = @gs.delta_base
      @saved_gs.delta_shift = @gs.delta_shift
      @saved_gs.auto_flip = @gs.auto_flip
      @saved_gs.instruct_control = @gs.instruct_control
      @saved_gs.scan_control = @gs.scan_control
      @saved_gs.scan_type = @gs.scan_type
    end

    # ---- CVT helpers (ttinterp.c) ------------------------------------------

    # Current_Ratio.
    private def current_ratio : Int64
      if @tt_ratio == 0
        if @gs.proj_vector_y == 0
          @tt_ratio = @tt_x_ratio
        elsif @gs.proj_vector_x == 0
          @tt_ratio = @tt_y_ratio
        else
          x = tt_mulfix14(@tt_x_ratio, @gs.proj_vector_x.to_i16!.to_i32)
          y = tt_mulfix14(@tt_y_ratio, @gs.proj_vector_y.to_i16!.to_i32)
          @tt_ratio = ft_vector_length(x, y)
        end
      end
      @tt_ratio
    end

    # Current_Ppem / Current_Ppem_Stretched.
    private def current_ppem : Int64
      if @func_cur_ppem_stretched
        ft_mulfix(@tt_ppem.to_i64, current_ratio)
      else
        @tt_ppem.to_i64
      end
    end

    # Read_CVT / Read_CVT_Stretched.
    private def read_cvt(idx : Int32) : Int64
      if @func_cvt_stretched
        ft_mulfix(@cvt[idx], current_ratio)
      else
        @cvt[idx]
      end
    end

    # Modify_CVT_Check.
    private def modify_cvt_check : Nil
      if @ini_range == CODERANGE_GLYPH && !@glyf_cvt
        @glyf_cvt = @cvt_base.dup
        @cvt = @glyf_cvt.not_nil!
      end
    end

    # Write_CVT / Write_CVT_Stretched.
    private def write_cvt(idx : Int32, value : Int64) : Nil
      modify_cvt_check
      @cvt[idx] = @func_cvt_stretched ? ft_divfix(value, current_ratio) : value
    end

    # Move_CVT / Move_CVT_Stretched.
    private def move_cvt(idx : Int32, value : Int64) : Nil
      modify_cvt_check
      if @func_cvt_stretched
        @cvt[idx] = @cvt[idx] &+ ft_divfix(value, current_ratio)
      else
        @cvt[idx] = @cvt[idx] &+ value
      end
    end

    # ---- rounding (ttinterp.c) ---------------------------------------------

    # dispatch on @func_round (cur_round_func)
    private def round_call(distance : Int64, compensation : Int64) : Int64
      case @func_round
      when ROUND_FUNC_NONE      then round_none(distance, compensation)
      when ROUND_FUNC_TO_GRID   then round_to_grid(distance, compensation)
      when ROUND_FUNC_TO_HALF   then round_to_half_grid(distance, compensation)
      when ROUND_FUNC_TO_DOUBLE then round_to_double_grid(distance, compensation)
      when ROUND_FUNC_DOWN      then round_down_to_grid(distance, compensation)
      when ROUND_FUNC_UP        then round_up_to_grid(distance, compensation)
      when ROUND_FUNC_SUPER     then round_super(distance, compensation)
      else                           round_super_45(distance, compensation)
      end
    end

    # Round_None.
    private def round_none(distance : Int64, compensation : Int64) : Int64
      val = if distance >= 0
        v = distance &+ compensation
        v < 0 ? 0_i64 : v
      else
        v = distance &- compensation
        v > 0 ? 0_i64 : v
      end
      val
    end

    # Round_To_Grid.
    private def round_to_grid(distance : Int64, compensation : Int64) : Int64
      if distance >= 0
        val = pix_round_long(distance &+ compensation)
        val = 0_i64 if val < 0
      else
        val = 0_i64 &- pix_round_long(compensation &- distance)
        val = 0_i64 if val > 0
      end
      val
    end

    # Round_To_Half_Grid.
    private def round_to_half_grid(distance : Int64, compensation : Int64) : Int64
      if distance >= 0
        val = pix_floor(distance &+ compensation) &+ 32
        val = 32_i64 if val < 0
      else
        val = 0_i64 &- (pix_floor(compensation &- distance) &+ 32)
        val = -32_i64 if val > 0
      end
      val
    end

    # Round_Down_To_Grid.
    private def round_down_to_grid(distance : Int64, compensation : Int64) : Int64
      if distance >= 0
        val = pix_floor(distance &+ compensation)
        val = 0_i64 if val < 0
      else
        val = 0_i64 &- pix_floor(compensation &- distance)
        val = 0_i64 if val > 0
      end
      val
    end

    # Round_Up_To_Grid.
    private def round_up_to_grid(distance : Int64, compensation : Int64) : Int64
      if distance >= 0
        val = pix_ceil_long(distance &+ compensation)
        val = 0_i64 if val < 0
      else
        val = 0_i64 &- pix_ceil_long(compensation &- distance)
        val = 0_i64 if val > 0
      end
      val
    end

    # Round_To_Double_Grid.
    private def round_to_double_grid(distance : Int64, compensation : Int64) : Int64
      if distance >= 0
        val = pad_round_long(distance &+ compensation, 32)
        val = 0_i64 if val < 0
      else
        val = 0_i64 &- pad_round_long(compensation &- distance, 32)
        val = 0_i64 if val > 0
      end
      val
    end

    # Round_Super.
    private def round_super(distance : Int64, compensation : Int64) : Int64
      if distance >= 0
        val = (distance &+ (@threshold &- @phase &+ compensation)) & (-@period)
        val = val &+ @phase
        val = @phase if val < 0
      else
        val = 0_i64 &- ((@threshold &- @phase &+ compensation) & (-@period))
        val = val &- @phase
        val = 0_i64 &- @phase if val > 0
      end
      val
    end

    # Round_Super_45.
    private def round_super_45(distance : Int64, compensation : Int64) : Int64
      if distance >= 0
        val = ((distance &+ (@threshold &- @phase &+ compensation)).tdiv(@period)) &* @period
        val = val &+ @phase
        val = @phase if val < 0
      else
        val = 0_i64 &- (((@threshold &- @phase &+ compensation) &- distance).tdiv(@period) &* @period)
        val = val &- @phase
        val = 0_i64 &- @phase if val > 0
      end
      val
    end

    # SetSuperRound.
    private def set_super_round(grid_period : Int32, selector : Int64) : Nil
      case selector & 0xC0
      when 0x00
        @period = grid_period.to_i64 // 2
      when 0x40
        @period = grid_period.to_i64
      when 0x80
        @period = grid_period.to_i64 &* 2
      else # 0xC0: reserved, but...
        @period = grid_period.to_i64
      end

      case selector & 0x30
      when 0x00
        @phase = 0
      when 0x10
        @phase = @period // 4
      when 0x20
        @phase = @period // 2
      else # 0x30
        @phase = @period &* 3 // 4
      end

      if (selector & 0x0F) == 0
        @threshold = @period &- 1
      else
        @threshold = ((selector & 0x0F).to_i32! &- 4).to_i64 &* @period // 8
      end

      # convert to F26Dot6 format
      @period = @period >> 8
      @phase = @phase >> 8
      @threshold = @threshold >> 8
    end

    # ---- projection / movement (ttinterp.c) --------------------------------

    # Project (generic dot product with projVector).
    private def project(dx : Int64, dy : Int64) : Int64
      tt_dotfix14(dx, dy, @gs.proj_vector_x.to_i16!.to_i32, @gs.proj_vector_y.to_i16!.to_i32)
    end

    # Dual_Project.
    private def dual_project(dx : Int64, dy : Int64) : Int64
      tt_dotfix14(dx, dy, @gs.dual_vector_x.to_i16!.to_i32, @gs.dual_vector_y.to_i16!.to_i32)
    end

    # func_project dispatch (Project_x / Project_y / Project).
    private def project_call(dx : Int64, dy : Int64) : Int64
      case @func_project
      when PROJECT_FUNC_X then dx
      when PROJECT_FUNC_Y then dy
      else                     project(dx, dy)
      end
    end

    # func_dualproj dispatch.
    private def dual_project_call(dx : Int64, dy : Int64) : Int64
      case @func_dualproj
      when PROJECT_FUNC_X then dx
      when PROJECT_FUNC_Y then dy
      else                     dual_project(dx, dy)
      end
    end

    # PROJECT(v1, v2) on zones.
    private def project_zone(z1 : Zone, i1 : Int32, z2 : Zone, i2 : Int32) : Int64
      project_call(z1.cur_x[i1] &- z2.cur_x[i2], z1.cur_y[i1] &- z2.cur_y[i2])
    end

    # DUALPROJ(v1, v2) on zones.
    private def dualproj_zone(z1 : Zone, i1 : Int32, z2 : Zone, i2 : Int32) : Int64
      dual_project_call(z1.org_x[i1] &- z2.org_x[i2], z1.org_y[i1] &- z2.org_y[i2])
    end

    # FAST_PROJECT(&zone.cur[i]).
    private def fast_project(z : Zone, i : Int32) : Int64
      project_call(z.cur_x[i], z.cur_y[i])
    end

    # FAST_DUALPROJ(&zone.org[i]).
    private def fast_dual_project(z : Zone, i : Int32) : Int64
      dual_project_call(z.org_x[i], z.org_y[i])
    end

    # Direct_Move.
    private def direct_move(zone : Zone, point : Int32, distance : Int64) : Nil
      v = @move_vector_x
      if v != 0
        # Exception to the post-IUP curfew: allow the x component of
        # diagonal moves, but only post-IUP.
        if @backward_compatibility == 0
          zone.cur_x[point] = zone.cur_x[point] &+ ft_mulfix(distance, v)
        end
        zone.tags[point] |= CURVE_TAG_TOUCH_X
      end

      v = @move_vector_y
      if v != 0
        if @backward_compatibility != 0x7
          zone.cur_y[point] = zone.cur_y[point] &+ ft_mulfix(distance, v)
        end
        zone.tags[point] |= CURVE_TAG_TOUCH_Y
      end
    end

    # Direct_Move_Orig.
    private def direct_move_orig(zone : Zone, point : Int32, distance : Int64) : Nil
      v = @move_vector_x
      if v != 0
        zone.org_x[point] = zone.org_x[point] &+ ft_mulfix(distance, v)
      end

      v = @move_vector_y
      if v != 0
        zone.org_y[point] = zone.org_y[point] &+ ft_mulfix(distance, v)
      end
    end

    # Direct_Move_X.
    private def direct_move_x(zone : Zone, point : Int32, distance : Int64) : Nil
      if @backward_compatibility == 0
        zone.cur_x[point] = zone.cur_x[point] &+ distance
      end
      zone.tags[point] |= CURVE_TAG_TOUCH_X
    end

    # Direct_Move_Y.
    private def direct_move_y(zone : Zone, point : Int32, distance : Int64) : Nil
      zone.cur_y[point] = zone.cur_y[point] &+ distance unless @backward_compatibility == 0x7
      zone.tags[point] |= CURVE_TAG_TOUCH_Y
    end

    # Direct_Move_Orig_X.
    private def direct_move_orig_x(zone : Zone, point : Int32, distance : Int64) : Nil
      zone.org_x[point] = zone.org_x[point] &+ distance
    end

    # Direct_Move_Orig_Y.
    private def direct_move_orig_y(zone : Zone, point : Int32, distance : Int64) : Nil
      zone.org_y[point] = zone.org_y[point] &+ distance
    end

    # func_move dispatch.
    private def move_call(zone : Zone, point : Int32, distance : Int64) : Nil
      case @func_move
      when MOVE_FUNC_X then direct_move_x(zone, point, distance)
      when MOVE_FUNC_Y then direct_move_y(zone, point, distance)
      else                  direct_move(zone, point, distance)
      end
    end

    # func_move_orig dispatch.
    private def move_orig_call(zone : Zone, point : Int32, distance : Int64) : Nil
      case @func_move_orig
      when MOVE_FUNC_X then direct_move_orig_x(zone, point, distance)
      when MOVE_FUNC_Y then direct_move_orig_y(zone, point, distance)
      else                  direct_move_orig(zone, point, distance)
      end
    end

    # SUBPIXEL_HINTING_MINIMAL: interpreter_version == 40.
    private def subpixel_hinting? : Bool
      @interpreter_version == INTERPRETER_VERSION_40
    end

    # NO_SUBPIXEL_HINTING: interpreter_version == 35.
    private def no_subpixel_hinting? : Bool
      @interpreter_version == INTERPRETER_VERSION_35
    end

    # Update_Native_ClearType_X_State.
    private def update_native_cleartype_x_state : Nil
      # `backward_compatibility' is also zero in v35, the CVT program,
      # monochrome rendering, and tricky-font execution.
      @native_cleartype_x =
        @backward_compatibility == 0 &&
        @gs.proj_vector_y == 0 &&
        @gs.free_vector_y == 0 &&
        subpixel_hinting? &&
        @ini_range == CODERANGE_GLYPH &&
        @render_mode != RENDER_MODE_MONO &&
        !@is_tricky
    end

    # Compute_Funcs.
    private def compute_funcs : Nil
      f_dot_p = (@gs.proj_vector_x.to_i64 &* @gs.free_vector_x.to_i64 &+
                 @gs.proj_vector_y.to_i64 &* @gs.free_vector_y.to_i64 &+
                 0x2000_i64) >> 14

      if f_dot_p >= 0x3FFE
        # commonly collinear
        @move_vector_x = @gs.free_vector_x.to_i64 &* 4
        @move_vector_y = @gs.free_vector_y.to_i64 &* 4
      elsif -0x1555 < f_dot_p && f_dot_p < 0x1555
        # prohibitively near-orthogonal
        @move_vector_x = 0
        @move_vector_y = 0
      else
        @move_vector_x = @gs.free_vector_x.to_i64 &* 0x10000_i64 // f_dot_p
        @move_vector_y = @gs.free_vector_y.to_i64 &* 0x10000_i64 // f_dot_p
      end

      if f_dot_p >= 0x3FFE && @gs.free_vector_x == 0x4000
        @func_move = MOVE_FUNC_X
        @func_move_orig = MOVE_FUNC_X
      elsif f_dot_p >= 0x3FFE && @gs.free_vector_y == 0x4000
        @func_move = MOVE_FUNC_Y
        @func_move_orig = MOVE_FUNC_Y
      else
        @func_move = MOVE_FUNC_GENERIC
        @func_move_orig = MOVE_FUNC_GENERIC
      end

      if @gs.proj_vector_x == 0x4000
        @func_project = PROJECT_FUNC_X
      elsif @gs.proj_vector_y == 0x4000
        @func_project = PROJECT_FUNC_Y
      else
        @func_project = PROJECT_FUNC_GENERIC
      end

      if @gs.dual_vector_x == 0x4000
        @func_dualproj = PROJECT_FUNC_X
      elsif @gs.dual_vector_y == 0x4000
        @func_dualproj = PROJECT_FUNC_Y
      else
        @func_dualproj = PROJECT_FUNC_GENERIC
      end

      # Projection/freedom-vector changes can enter or leave the
      # native ClearType direction.
      update_native_cleartype_x_state

      # Disable cached aspect ratio
      @tt_ratio = 0
    end

    # Normalize: norms a vector, returns the F2Dot14 unit vector pair.
    private def normalize(vx : Int64, vy : Int64) : {Int32, Int32}
      if vx == 0 && vy == 0
        # UNDOCUMENTED! It seems that it is possible to try
        # to normalize the vector (0,0).  Return immediately.
        return {0, 0}
      end

      nx, ny, _len = ft_vector_norm_len(vx, vy)

      {(nx // 4).to_i16!.to_i32, (ny // 4).to_i16!.to_i32}
    end

    # ---- opcode handlers (ttinterp.c, same order as the C file) -----------
    # Each handler takes `a`, the index of args[0] in @stack (exc->args).

    # Ins_MPPEM.
    private def ins_mppem(a : Int32) : Nil
      @stack[a] = current_ppem
    end

    # Ins_MPS.
    private def ins_mps(a : Int32) : Nil
      if no_subpixel_hinting?
        # Microsoft's GDI bytecode interpreter always returns value 12;
        # we return the current PPEM value instead.
        @stack[a] = current_ppem
      else
        @stack[a] = @point_size
      end
    end

    # Ins_DUP.
    private def ins_dup(a : Int32) : Nil
      @stack[a + 1] = @stack[a]
    end

    # Ins_CLEAR.
    private def ins_clear : Nil
      @new_top = 0
    end

    # Ins_SWAP.
    private def ins_swap(a : Int32) : Nil
      l = @stack[a]
      @stack[a] = @stack[a + 1]
      @stack[a + 1] = l
    end

    # Ins_DEPTH.
    private def ins_depth(a : Int32) : Nil
      @stack[a] = @top
    end

    # Ins_LT.
    private def ins_lt(a : Int32) : Nil
      @stack[a] = (@stack[a] < @stack[a + 1]) ? 1_i64 : 0_i64
    end

    # Ins_LTEQ.
    private def ins_lteq(a : Int32) : Nil
      @stack[a] = (@stack[a] <= @stack[a + 1]) ? 1_i64 : 0_i64
    end

    # Ins_GT.
    private def ins_gt(a : Int32) : Nil
      @stack[a] = (@stack[a] > @stack[a + 1]) ? 1_i64 : 0_i64
    end

    # Ins_GTEQ.
    private def ins_gteq(a : Int32) : Nil
      @stack[a] = (@stack[a] >= @stack[a + 1]) ? 1_i64 : 0_i64
    end

    # Ins_EQ.
    private def ins_eq(a : Int32) : Nil
      @stack[a] = (@stack[a] == @stack[a + 1]) ? 1_i64 : 0_i64
    end

    # Ins_NEQ.
    private def ins_neq(a : Int32) : Nil
      @stack[a] = (@stack[a] != @stack[a + 1]) ? 1_i64 : 0_i64
    end

    # Ins_ODD.
    private def ins_odd(a : Int32) : Nil
      @stack[a] = ((round_call(@stack[a], 0) & 64) == 64) ? 1_i64 : 0_i64
    end

    # Ins_EVEN.
    private def ins_even(a : Int32) : Nil
      @stack[a] = ((round_call(@stack[a], 0) & 64) == 0) ? 1_i64 : 0_i64
    end

    # Ins_AND.
    private def ins_and(a : Int32) : Nil
      @stack[a] = (@stack[a] != 0 && @stack[a + 1] != 0) ? 1_i64 : 0_i64
    end

    # Ins_OR.
    private def ins_or(a : Int32) : Nil
      @stack[a] = (@stack[a] != 0 || @stack[a + 1] != 0) ? 1_i64 : 0_i64
    end

    # Ins_NOT.
    private def ins_not(a : Int32) : Nil
      @stack[a] = @stack[a] == 0 ? 1_i64 : 0_i64
    end

    # Ins_ADD.
    private def ins_add(a : Int32) : Nil
      @stack[a] = @stack[a] &+ @stack[a + 1]
    end

    # Ins_SUB.
    private def ins_sub(a : Int32) : Nil
      @stack[a] = @stack[a] &- @stack[a + 1]
    end

    # Ins_DIV.
    private def ins_div(a : Int32) : Nil
      if @stack[a + 1] == 0
        err(ERR_DIVIDE_BY_ZERO, "Ins_DIV: divide by zero")
      else
        @stack[a] = ft_muldiv_no_round(@stack[a], 64_i64, @stack[a + 1])
      end
    end

    # Ins_MUL.
    private def ins_mul(a : Int32) : Nil
      @stack[a] = ft_muldiv(@stack[a], @stack[a + 1], 64_i64)
    end

    # Ins_ABS.
    private def ins_abs(a : Int32) : Nil
      @stack[a] = 0_i64 &- @stack[a] if @stack[a] < 0
    end

    # Ins_NEG.
    private def ins_neg(a : Int32) : Nil
      @stack[a] = 0_i64 &- @stack[a]
    end

    # Ins_FLOOR.
    private def ins_floor(a : Int32) : Nil
      @stack[a] = pix_floor(@stack[a])
    end

    # Ins_CEILING.
    private def ins_ceiling(a : Int32) : Nil
      @stack[a] = pix_ceil_long(@stack[a])
    end

    # Ins_RS.
    private def ins_rs(a : Int32) : Nil
      i = @stack[a].to_u64!
      if boundsl?(i.to_i64!, @storage_base.size)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_RS: array bound")
        else
          @stack[a] = 0
        end
      else
        @stack[a] = @storage[i]
      end
    end

    # Ins_WS.
    private def ins_ws(a : Int32) : Nil
      i = @stack[a].to_u64!
      if boundsl?(i.to_i64!, @storage_base.size)
        err(ERR_INVALID_REFERENCE, "Ins_WS: array bound") if @pedantic_hinting
      else
        if @ini_range == CODERANGE_GLYPH && !@glyf_storage
          @glyf_storage = @storage_base.dup
          @storage = @glyf_storage.not_nil!
        end

        @storage[i] = @stack[a + 1]
      end
    end

    # Ins_WCVTP.
    private def ins_wcvtp(a : Int32) : Nil
      i = @stack[a].to_u64!
      if boundsl?(i.to_i64!, @cvt_base.size)
        err(ERR_INVALID_REFERENCE, "Ins_WCVTP: array bound") if @pedantic_hinting
      else
        write_cvt(i.to_i32!, @stack[a + 1])
      end
    end

    # Ins_WCVTF.
    private def ins_wcvtf(a : Int32) : Nil
      i = @stack[a].to_u64!
      if boundsl?(i.to_i64!, @cvt_base.size)
        err(ERR_INVALID_REFERENCE, "Ins_WCVTF: array bound") if @pedantic_hinting
      else
        modify_cvt_check
        @cvt[i] = ft_mulfix(@stack[a + 1], @tt_scale)
      end
    end

    # Ins_RCVT.
    private def ins_rcvt(a : Int32) : Nil
      i = @stack[a].to_u64!
      if boundsl?(i.to_i64!, @cvt_base.size)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_RCVT: array bound")
        else
          @stack[a] = 0
        end
      else
        @stack[a] = read_cvt(i.to_i32!)
      end
    end

    # Ins_AA: intentionally no longer supported.
    private def ins_aa : Nil
    end

    # Ins_DEBUG: unsupported, always an error.
    private def ins_debug : Nil
      err(ERR_DEBUG_OPCODE, "Ins_DEBUG: debug opcode is unsupported")
    end

    # Ins_ROUND.
    private def ins_round(a : Int32) : Nil
      # Native ClearType applies ROUND to the 1/16-pixel virtual grid in
      # the ClearType direction; v40 approximates this by leaving the
      # result unrounded.
      if @native_cleartype_x
        @stack[a] = round_none(@stack[a], @gs.compensation[@opcode & 3])
      else
        @stack[a] = round_call(@stack[a], @gs.compensation[@opcode & 3])
      end
    end

    # Ins_NROUND.
    private def ins_nround(a : Int32) : Nil
      @stack[a] = round_none(@stack[a], @gs.compensation[@opcode & 3])
    end

    # Ins_MAX.
    private def ins_max(a : Int32) : Nil
      @stack[a] = @stack[a + 1] if @stack[a + 1] > @stack[a]
    end

    # Ins_MIN.
    private def ins_min(a : Int32) : Nil
      @stack[a] = @stack[a + 1] if @stack[a + 1] < @stack[a]
    end

    # Ins_MINDEX.
    private def ins_mindex(a : Int32) : Nil
      l = @stack[a]

      if l <= 0 || l > @args_base
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_MINDEX: invalid index")
        end
      else
        k = @stack[a - l.to_i32!]

        base = a - l.to_i32!
        count = l.to_i32! - 1
        # FT_ARRAY_MOVE(args - L, args - L + 1, L - 1)
        i = 0
        while i < count
          @stack[base + i] = @stack[base + i + 1]
          i += 1
        end

        @stack[a - 1] = k
      end
    end

    # Ins_CINDEX.
    private def ins_cindex(a : Int32) : Nil
      l = @stack[a]

      if l <= 0 || l > @args_base
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_CINDEX: invalid index")
        end
        @stack[a] = 0
      else
        @stack[a] = @stack[a - l.to_i32!]
      end
    end

    # Ins_ROLL.
    private def ins_roll(a : Int32) : Nil
      aa = @stack[a + 2]
      b = @stack[a + 1]
      c = @stack[a]

      @stack[a + 2] = c
      @stack[a + 1] = aa
      @stack[a] = b
    end

    # Ins_SLOOP.
    private def ins_sloop(a : Int32) : Nil
      if @stack[a] < 0
        err(ERR_BAD_ARGUMENT, "Ins_SLOOP: negative loop count")
      else
        # we heuristically limit the number of loops to 16 bits
        @gs.loop = @stack[a] > 0xFFFF ? 0xFFFF_i64 : @stack[a]
      end
    end

    # SkipCode.
    private def skip_code : Nil
      @ip &+= @length

      if @ip < @code_size
        @opcode = @code[@ip]

        @length = OPCODE_LENGTH[@opcode].to_i32
        if @length < 0
          if @ip + 1 >= @code_size
            err(ERR_CODE_OVERFLOW, "SkipCode: code overflow")
          end
          @length = 2 - @length * @code[@ip + 1]
        end
      else
        err(ERR_CODE_OVERFLOW, "SkipCode: code overflow")
      end
    end

    # Ins_IF.
    private def ins_if(a : Int32) : Nil
      return if @stack[a] != 0

      n_ifs = 1
      out = false

      loop do
        skip_code

        case @opcode
        when 0x58 # IF
          n_ifs += 1
        when 0x1B # ELSE
          out = (n_ifs == 1)
        when 0x59 # EIF
          n_ifs -= 1
          out = (n_ifs == 0)
        end

        break if out
      end
    end

    # Ins_ELSE.
    private def ins_else : Nil
      n_ifs = 1

      loop do
        skip_code

        case @opcode
        when 0x58 # IF
          n_ifs += 1
        when 0x59 # EIF
          n_ifs -= 1
        end

        break if n_ifs == 0
      end
    end

    # Ins_JMPR.
    private def ins_jmpr(a : Int32) : Nil
      if @stack[a] == 0 && @args_base == 0
        err(ERR_BAD_ARGUMENT, "Ins_JMPR: zero jump")
      end

      @ip = @ip &+ @stack[a]
      if @ip < 0 ||
         (@call_top > 0 && @ip > @call_stack[@call_top - 1].def_rec.not_nil!.end_)
        err(ERR_BAD_ARGUMENT, "Ins_JMPR: jump out of range")
      end

      @length = 0

      if @stack[a] < 0
        @neg_jump_counter &+= 1
        if @neg_jump_counter > @neg_jump_counter_max
          err(ERR_EXECUTION_TOO_LONG, "Ins_JMPR: too many backward jumps")
        end
      end
    end

    # Ins_JROT.
    private def ins_jrot(a : Int32) : Nil
      ins_jmpr(a) if @stack[a + 1] != 0
    end

    # Ins_JROF.
    private def ins_jrof(a : Int32) : Nil
      ins_jmpr(a) if @stack[a + 1] == 0
    end

    # Ins_FDEF.
    private def ins_fdef(a : Int32) : Nil
      # FDEF is only allowed in `prep' or `fpgm'
      if @ini_range == CODERANGE_GLYPH
        err(ERR_DEF_IN_GLYF_BYTECODE, "Ins_FDEF: FDEF in glyph bytecode")
      end

      # some font programs are broken enough to redefine functions!
      n = @stack[a].to_u64!

      # C compares rec->opc (FT_UInt) == n (FT_ULong).
      rec = nil
      i = 0
      while i < @num_fdefs
        if @fdefs[i].opc.to_u64! == n
          rec = @fdefs[i]
          break
        end
        i += 1
      end

      if !rec
        # check that there is enough room for new functions
        if @num_fdefs >= @max_fdefs
          err(ERR_TOO_MANY_FUNCTION_DEFS, "Ins_FDEF: too many function definitions")
        end
        rec = @fdefs[@num_fdefs]
        @num_fdefs += 1
      end

      # Although FDEF takes unsigned 32-bit integer,
      # func # must be within unsigned 16-bit integer
      if n > 0xFFFF
        err(ERR_TOO_MANY_FUNCTION_DEFS, "Ins_FDEF: function number > 0xFFFF")
      end

      rec.range = @cur_range
      rec.opc = (n & 0xFFFF).to_i32
      rec.start_ = @ip + 1
      rec.active = true

      @max_func = n.to_i32 if n > @max_func

      # Now skip the whole function definition.
      # We don't allow nested IDEFS & FDEFs.
      loop do
        skip_code

        case @opcode
        when 0x89 # IDEF
        when 0x2C # FDEF
          err(ERR_NESTED_DEFS, "Ins_FDEF: nested DEFS")
        when 0x2D # ENDF
          rec.end_ = @ip
          return
        end
      end
    end

    # Ins_ENDF.
    private def ins_endf : Nil
      if @call_top <= 0 # We encountered an ENDF without a call
        err(ERR_ENDF_IN_EXEC_STREAM, "Ins_ENDF: ENDF in exec stream")
      end

      @call_top -= 1

      p_rec = @call_stack[@call_top]

      p_rec.cur_count &-= 1

      if p_rec.cur_count > 0
        @call_top += 1
        @ip = p_rec.def_rec.not_nil!.start_
        @length = 0
      else
        # Loop through the current function
        goto_code_range(p_rec.caller_range, p_rec.caller_ip)
      end
    end

    # Common function lookup for CALL/LOOPCALL.
    private def lookup_func(f : UInt64) : DefRecord?
      return nil if boundsl?(f.to_i64!, @max_func.to_i64 + 1)

      # Except for some old Apple fonts, all functions in a TrueType font
      # are defined in increasing order, starting from 0.
      def_rec = @fdefs[f.to_i32!]
      if @max_func + 1 != @num_fdefs || def_rec.opc.to_u64! != f
        # look up the FDefs table
        def_rec = nil
        i = 0
        while i < @num_fdefs
          if @fdefs[i].opc.to_u64! == f
            def_rec = @fdefs[i]
            break
          end
          i += 1
        end
      end

      def_rec
    end

    # Ins_CALL.
    private def ins_call(a : Int32) : Nil
      f = @stack[a].to_u64!

      def_rec = lookup_func(f)
      if !def_rec || !def_rec.active
        err(ERR_INVALID_REFERENCE, "Ins_CALL: invalid function reference")
      end

      # check the call stack
      if @call_top >= @call_size
        err(ERR_STACK_OVERFLOW, "Ins_CALL: call stack overflow")
      end

      p_crec = @call_stack[@call_top]

      p_crec.caller_range = @cur_range
      p_crec.caller_ip = @ip + 1
      p_crec.cur_count = 1
      p_crec.def_rec = def_rec

      @call_top += 1

      goto_code_range(def_rec.range, def_rec.start_)
    end

    # Ins_LOOPCALL.
    private def ins_loopcall(a : Int32) : Nil
      f = @stack[a + 1].to_u64!

      def_rec = lookup_func(f)
      if !def_rec || !def_rec.active
        err(ERR_INVALID_REFERENCE, "Ins_LOOPCALL: invalid function reference")
      end

      # check stack
      if @call_top >= @call_size
        err(ERR_STACK_OVERFLOW, "Ins_LOOPCALL: call stack overflow")
      end

      if @stack[a] > 0
        p_crec = @call_stack[@call_top]

        p_crec.caller_range = @cur_range
        p_crec.caller_ip = @ip + 1
        p_crec.cur_count = @stack[a].to_i32!.to_i64
        p_crec.def_rec = def_rec

        @call_top += 1

        goto_code_range(def_rec.range, def_rec.start_)

        @loopcall_counter &+= @stack[a].to_u64!
        if @loopcall_counter > @loopcall_counter_max
          err(ERR_EXECUTION_TOO_LONG, "Ins_LOOPCALL: too many loops")
        end
      end
    end

    # Ins_IDEF.
    private def ins_idef(a : Int32) : Nil
      # we enable IDEF only in `prep' or `fpgm'
      if @ini_range == CODERANGE_GLYPH
        err(ERR_DEF_IN_GLYF_BYTECODE, "Ins_IDEF: IDEF in glyph bytecode")
      end

      # First of all, look for the same function in our table
      def_rec = nil
      i = 0
      while i < @num_idefs
        if @idefs[i].opc.to_u64! == @stack[a].to_u64!
          def_rec = @idefs[i]
          break
        end
        i += 1
      end

      if !def_rec
        # check that there is enough room for a new instruction
        if @num_idefs >= @max_idefs
          err(ERR_TOO_MANY_INSTRUCTION_DEFS, "Ins_IDEF: too many instruction definitions")
        end
        def_rec = @idefs[@num_idefs]
        @num_idefs += 1
      end

      # opcode must be unsigned 8-bit integer
      if 0 > @stack[a] || @stack[a] > 0xFF
        err(ERR_TOO_MANY_INSTRUCTION_DEFS, "Ins_IDEF: opcode out of range")
      end

      def_rec.opc = @stack[a].to_i32!
      def_rec.start_ = @ip + 1
      def_rec.range = @cur_range
      def_rec.active = true

      if @stack[a].to_u64! > @max_ins.to_u64!
        @max_ins = @stack[a].to_i32!
      end

      # Now skip the whole function definition.
      # We don't allow nested IDEFs & FDEFs.
      loop do
        skip_code

        case @opcode
        when 0x89 # IDEF
        when 0x2C # FDEF
          err(ERR_NESTED_DEFS, "Ins_IDEF: nested DEFS")
        when 0x2D # ENDF
          def_rec.end_ = @ip
          return
        end
      end
    end

    # Ins_NPUSHB.
    private def ins_npushb(a : Int32) : Nil
      ip = @ip

      ip &+= 1
      if ip >= @code_size
        err(ERR_CODE_OVERFLOW, "Ins_NPUSHB: code overflow")
      end

      l = @code[ip].to_i32

      if ip + l >= @code_size
        err(ERR_CODE_OVERFLOW, "Ins_NPUSHB: code overflow")
      end

      if bounds32?(l.to_i64, @stack_size &+ 1 &- @top)
        err(ERR_STACK_OVERFLOW, "Ins_NPUSHB: stack overflow")
      end

      k = 0
      while k < l
        ip &+= 1
        @stack[a + k] = @code[ip].to_i64
        k += 1
      end

      @new_top &+= l
      @ip = ip
    end

    # Ins_NPUSHW.
    private def ins_npushw(a : Int32) : Nil
      ip = @ip

      ip &+= 1
      if ip >= @code_size
        err(ERR_CODE_OVERFLOW, "Ins_NPUSHW: code overflow")
      end

      l = @code[ip].to_i32

      if ip + 2 * l >= @code_size
        err(ERR_CODE_OVERFLOW, "Ins_NPUSHW: code overflow")
      end

      if bounds32?(l.to_i64, @stack_size &+ 1 &- @top)
        err(ERR_STACK_OVERFLOW, "Ins_NPUSHW: stack overflow")
      end

      # note casting for sign-extension
      k = 0
      while k < l
        @stack[a + k] = ((@code[ip + 1].to_i64 << 8).to_i16!.to_i64) | @code[ip + 2]
        k += 1
        ip &+= 2
      end

      @new_top &+= l
      @ip = ip
    end

    # Ins_PUSHB.
    private def ins_pushb(a : Int32) : Nil
      ip = @ip

      l = @opcode.to_i32 - 0xB0 + 1

      if ip + l >= @code_size
        err(ERR_CODE_OVERFLOW, "Ins_PUSHB: code overflow")
      end

      if bounds32?(l.to_i64, @stack_size &+ 1 &- @top)
        err(ERR_STACK_OVERFLOW, "Ins_PUSHB: stack overflow")
      end

      k = 0
      while k < l
        ip &+= 1
        @stack[a + k] = @code[ip].to_i64
        k += 1
      end

      @ip = ip
    end

    # Ins_PUSHW.
    private def ins_pushw(a : Int32) : Nil
      ip = @ip

      l = @opcode.to_i32 - 0xB8 + 1

      if ip + 2 * l >= @code_size
        err(ERR_CODE_OVERFLOW, "Ins_PUSHW: code overflow")
      end

      if bounds32?(l.to_i64, @stack_size &+ 1 &- @top)
        err(ERR_STACK_OVERFLOW, "Ins_PUSHW: stack overflow")
      end

      # note casting for sign-extension
      k = 0
      while k < l
        @stack[a + k] = ((@code[ip + 1].to_i64 << 8).to_i16!.to_i64) | @code[ip + 2]
        k += 1
        ip &+= 2
      end

      @ip = ip
    end

    # ---- managing the graphics state ---------------------------------------

    # Ins_SxVTL.
    private def ins_sxvtl(a_idx1 : Int32, a_idx2 : Int32, opcode : UInt8) : Bool
      if bounds32?(a_idx1.to_i64, @zp2.n_points) ||
         bounds32?(a_idx2.to_i64, @zp1.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SxVTL: point out of zone")
        end
        return false
      end

      # p1 = zp1.cur + aIdx2; p2 = zp2.cur + aIdx1
      a = @zp1.cur_x[a_idx2] &- @zp2.cur_x[a_idx1]
      b = @zp1.cur_y[a_idx2] &- @zp2.cur_y[a_idx1]

      # If p1 == p2, SPvTL and SFvTL behave the same as
      # SPvTCA[X] and SFvTCA[X], respectively.
      a = a.to_i64!
      b = b.to_i64!

      if a == 0 && b == 0
        a = 0x4000_i64
        opcode = 0_u8
      end

      if (opcode & 1) != 0
        c = b # counter-clockwise rotation
        b = a
        a = 0_i64 &- c
      end

      @sxvtl_result = normalize(a, b)
      true
    end

    @sxvtl_result : {Int32, Int32} = {0, 0}

    # Ins_SxyTCA (SVTCA/SPVTCA/SFVTCA).
    private def ins_sxytca : Nil
      opcode = @opcode

      # NB: widen before shifting -- UInt8 << 14 would wrap to zero.
      aa = (((opcode.to_i32 & 1) << 14) & 0xFFFF).to_i16!
      bb = (aa ^ 0x4000).to_i16!

      if opcode < 4
        @gs.proj_vector_x = aa.to_i32
        @gs.proj_vector_y = bb.to_i32

        @gs.dual_vector_x = aa.to_i32
        @gs.dual_vector_y = bb.to_i32
      end

      if (opcode & 2) == 0
        @gs.free_vector_x = aa.to_i32
        @gs.free_vector_y = bb.to_i32
      end

      compute_funcs
    end

    # Ins_SPVTL.
    private def ins_spvtl(a : Int32) : Nil
      if ins_sxvtl(to_ushort(@stack[a + 1]), to_ushort(@stack[a]), @opcode)
        @gs.proj_vector_x, @gs.proj_vector_y = @sxvtl_result
        @gs.dual_vector_x = @gs.proj_vector_x
        @gs.dual_vector_y = @gs.proj_vector_y
        compute_funcs
      end
    end

    # Ins_SFVTL.
    private def ins_sfvtl(a : Int32) : Nil
      if ins_sxvtl(to_ushort(@stack[a + 1]), to_ushort(@stack[a]), @opcode)
        @gs.free_vector_x, @gs.free_vector_y = @sxvtl_result
        compute_funcs
      end
    end

    # Ins_SFVTPV.
    private def ins_sfvtpv : Nil
      @gs.free_vector_x = @gs.proj_vector_x
      @gs.free_vector_y = @gs.proj_vector_y
      compute_funcs
    end

    # Ins_SPVFS.
    private def ins_spvfs(a : Int32) : Nil
      # Only use low 16bits, then sign extend
      y = to_short(@stack[a + 1])
      x = to_short(@stack[a])

      @gs.proj_vector_x, @gs.proj_vector_y = normalize(x, y)

      @gs.dual_vector_x = @gs.proj_vector_x
      @gs.dual_vector_y = @gs.proj_vector_y
      compute_funcs
    end

    # Ins_SFVFS.
    private def ins_sfvfs(a : Int32) : Nil
      # Only use low 16bits, then sign extend
      y = to_short(@stack[a + 1])
      x = to_short(@stack[a])

      @gs.free_vector_x, @gs.free_vector_y = normalize(x, y)
      compute_funcs
    end

    # Ins_GPV.
    private def ins_gpv(a : Int32) : Nil
      @stack[a] = @gs.proj_vector_x.to_i64
      @stack[a + 1] = @gs.proj_vector_y.to_i64
    end

    # Ins_GFV.
    private def ins_gfv(a : Int32) : Nil
      @stack[a] = @gs.free_vector_x.to_i64
      @stack[a + 1] = @gs.free_vector_y.to_i64
    end

    # Ins_SRP0.
    private def ins_srp0(a : Int32) : Nil
      @gs.rp0 = to_ushort(@stack[a])
    end

    # Ins_SRP1.
    private def ins_srp1(a : Int32) : Nil
      @gs.rp1 = to_ushort(@stack[a])
    end

    # Ins_SRP2.
    private def ins_srp2(a : Int32) : Nil
      @gs.rp2 = to_ushort(@stack[a])
    end

    # Ins_SMD.
    private def ins_smd(a : Int32) : Nil
      @gs.minimum_distance = @stack[a]
    end

    # Ins_SCVTCI.
    private def ins_scvtci(a : Int32) : Nil
      @gs.control_value_cutin = @stack[a]
    end

    # Ins_SSWCI.
    private def ins_sswci(a : Int32) : Nil
      @gs.single_width_cutin = @stack[a]
    end

    # Ins_SSW.
    private def ins_ssw(a : Int32) : Nil
      @gs.single_width_value = ft_mulfix(@stack[a], @tt_scale)
    end

    # Ins_FLIPON.
    private def ins_flipon : Nil
      @gs.auto_flip = true
    end

    # Ins_FLIPOFF.
    private def ins_flipoff : Nil
      @gs.auto_flip = false
    end

    # Ins_SANGW: instruction not supported anymore.
    private def ins_sangw : Nil
    end

    # Ins_SDB.
    private def ins_sdb(a : Int32) : Nil
      @gs.delta_base = to_ushort(@stack[a])
    end

    # Ins_SDS.
    private def ins_sds(a : Int32) : Nil
      if @stack[a].to_u64! > 6
        err(ERR_BAD_ARGUMENT, "Ins_SDS: bad delta shift")
      else
        @gs.delta_shift = to_ushort(@stack[a])
      end
    end

    # Ins_RTHG.
    private def ins_rthg : Nil
      @gs.round_state = ROUND_TO_HALF_GRID
      @func_round = ROUND_FUNC_TO_HALF
    end

    # Ins_RTG.
    private def ins_rtg : Nil
      @gs.round_state = ROUND_TO_GRID
      @func_round = ROUND_FUNC_TO_GRID
    end

    # Ins_RTDG.
    private def ins_rtdg : Nil
      @gs.round_state = ROUND_TO_DOUBLE_GRID
      @func_round = ROUND_FUNC_TO_DOUBLE
    end

    # Ins_RUTG.
    private def ins_rutg : Nil
      @gs.round_state = ROUND_UP_TO_GRID
      @func_round = ROUND_FUNC_UP
    end

    # Ins_RDTG.
    private def ins_rdtg : Nil
      @gs.round_state = ROUND_DOWN_TO_GRID
      @func_round = ROUND_FUNC_DOWN
    end

    # Ins_ROFF.
    private def ins_roff : Nil
      @gs.round_state = ROUND_OFF
      @func_round = ROUND_FUNC_NONE
    end

    # Ins_SROUND.
    private def ins_sround(a : Int32) : Nil
      set_super_round(0x4000, @stack[a])

      @gs.round_state = ROUND_SUPER
      @func_round = ROUND_FUNC_SUPER
    end

    # Ins_S45ROUND.
    private def ins_s45round(a : Int32) : Nil
      set_super_round(0x2D41, @stack[a])

      @gs.round_state = ROUND_SUPER_45
      @func_round = ROUND_FUNC_SUPER_45
    end

    # Ins_GC.
    private def ins_gc(a : Int32) : Nil
      l = @stack[a].to_u64!

      if boundsl?(l.to_i64!, @zp2.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_GC: point out of zone")
        end
        r = 0_i64
      else
        if (@opcode & 1) != 0
          r = fast_dual_project(@zp2, l.to_i32!)
        else
          r = fast_project(@zp2, l.to_i32!)
        end
      end

      @stack[a] = r
    end

    # Ins_SCFS.
    private def ins_scfs(a : Int32) : Nil
      l = to_ushort(@stack[a])

      if bounds32?(l.to_i64, @zp2.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SCFS: point out of zone")
        end
        return
      end

      k = fast_project(@zp2, l)

      move_call(@zp2, l, @stack[a + 1] &- k)

      # UNDOCUMENTED! The MS rasterizer does that with twilight points
      if @gs.gep2 == 0
        @zp2.org_x[l] = @zp2.cur_x[l]
        @zp2.org_y[l] = @zp2.cur_y[l]
      end
    end

    # Ins_MD. XXX: UNDOCUMENTED: flags are inverted; `zp0 - zp1'.
    private def ins_md(a : Int32) : Nil
      k = to_ushort(@stack[a + 1])
      l = to_ushort(@stack[a])

      if bounds32?(l.to_i64, @zp0.n_points) ||
         bounds32?(k.to_i64, @zp1.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_MD: point out of zone")
        end
        d = 0_i64
      else
        if (@opcode & 1) != 0
          d = project_zone(@zp0, l, @zp1, k)
        else
          # XXX: UNDOCUMENTED: twilight zone special case
          if @gs.gep0 == 0 || @gs.gep1 == 0
            d = dualproj_zone(@zp0, l, @zp1, k)
          else
            if @metrics_x_scale == @metrics_y_scale
              # this should be faster
              d = dual_project_call(@zp0.orus_x[l] &- @zp1.orus_x[k],
                                    @zp0.orus_y[l] &- @zp1.orus_y[k])
              d = ft_mulfix(d, @metrics_x_scale)
            else
              vx = ft_mulfix(@zp0.orus_x[l] &- @zp1.orus_x[k], @metrics_x_scale)
              vy = ft_mulfix(@zp0.orus_y[l] &- @zp1.orus_y[k], @metrics_y_scale)
              d = dual_project_call(vx, vy)
            end
          end
        end
      end

      @stack[a] = d
    end

    # Ins_SDPVTL.
    private def ins_sdpvtl(a : Int32) : Nil
      opcode = @opcode

      p1 = to_ushort(@stack[a + 1])
      p2 = to_ushort(@stack[a])

      if bounds32?(p2.to_i64, @zp1.n_points) ||
         bounds32?(p1.to_i64, @zp2.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SDPVTL: point out of zone")
        end
        return
      end

      # dual vector from the original positions
      aa = (@zp1.org_x[p2] &- @zp2.org_x[p1]).to_i64!
      b = (@zp1.org_y[p2] &- @zp2.org_y[p1]).to_i64!

      # If v1 == v2, SDPvTL behaves the same as SVTCA[X].
      if aa == 0 && b == 0
        aa = 0x4000_i64
        opcode = 0_u8
      end

      if (opcode & 1) != 0
        c = b # counter-clockwise rotation
        b = aa
        aa = 0_i64 &- c
      end

      @gs.dual_vector_x, @gs.dual_vector_y = normalize(aa, b)

      # projection vector from the current positions
      aa = (@zp1.cur_x[p2] &- @zp2.cur_x[p1]).to_i64!
      b = (@zp1.cur_y[p2] &- @zp2.cur_y[p1]).to_i64!

      if aa == 0 && b == 0
        aa = 0x4000_i64
        opcode = 0_u8
      end

      if (opcode & 1) != 0
        c = b # counter-clockwise rotation
        b = aa
        aa = 0_i64 &- c
      end

      @gs.proj_vector_x, @gs.proj_vector_y = normalize(aa, b)
      compute_funcs
    end

    # Ins_SZP0.
    private def ins_szp0(a : Int32) : Nil
      case @stack[a].to_i32!
      when 0
        @zp0 = @twilight
      when 1
        @zp0 = @pts
      else
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SZP0: bad zone")
        end
        return
      end

      @gs.gep0 = to_ushort(@stack[a])
    end

    # Ins_SZP1.
    private def ins_szp1(a : Int32) : Nil
      case @stack[a].to_i32!
      when 0
        @zp1 = @twilight
      when 1
        @zp1 = @pts
      else
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SZP1: bad zone")
        end
        return
      end

      @gs.gep1 = to_ushort(@stack[a])
    end

    # Ins_SZP2.
    private def ins_szp2(a : Int32) : Nil
      case @stack[a].to_i32!
      when 0
        @zp2 = @twilight
      when 1
        @zp2 = @pts
      else
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SZP2: bad zone")
        end
        return
      end

      @gs.gep2 = to_ushort(@stack[a])
    end

    # Ins_SZPS.
    private def ins_szps(a : Int32) : Nil
      case @stack[a].to_i32!
      when 0
        @zp0 = @twilight
      when 1
        @zp0 = @pts
      else
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SZPS: bad zone")
        end
        return
      end

      @zp1 = @zp0
      @zp2 = @zp0

      @gs.gep0 = to_ushort(@stack[a])
      @gs.gep1 = to_ushort(@stack[a])
      @gs.gep2 = to_ushort(@stack[a])
    end

    # Ins_INSTCTRL.
    private def ins_instctrl(a : Int32) : Nil
      k = @stack[a + 1].to_u64!
      l = @stack[a].to_u64!

      # selector values cannot be `OR'ed;
      # they are indices starting with index 1, not flags
      if k < 1 || k > 3
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_INSTCTRL: bad selector")
        end
        return
      end

      # convert index to flag value
      kf = 1_u64 << (k - 1)

      if l != 0
        # arguments to selectors look like flag values
        if l != kf
          if @pedantic_hinting
            err(ERR_INVALID_REFERENCE, "Ins_INSTCTRL: bad value")
          end
          return
        end
      end

      # INSTCTRL should only be used in the CVT program
      if @ini_range == CODERANGE_CVT
        @gs.instruct_control = (@gs.instruct_control & ~(1_i64 << (k - 1))) | l.to_i64!
      elsif @ini_range == CODERANGE_GLYPH && k == 3
        # Native ClearType fonts sign a waiver that turns off all backward
        # compatibility hacks and lets them program points to the grid
        # like it's 1996.
        if subpixel_hinting?
          @backward_compatibility = ((l & 4) ^ 4).to_i32

          # A glyph can temporarily switch between backward-compatible
          # and native ClearType, so update the native-X state too.
          update_native_cleartype_x_state
        end
      elsif @pedantic_hinting
        err(ERR_INVALID_REFERENCE, "Ins_INSTCTRL: not in prep")
      end
    end

    # Ins_SCANCTRL.
    private def ins_scanctrl(a : Int32) : Nil
      # Get Threshold
      a8 = (@stack[a] & 0xFF).to_i32!

      if a8 == 0xFF
        @gs.scan_control = true
        return
      elsif a8 == 0
        @gs.scan_control = false
        return
      end

      @gs.scan_control = true if (@stack[a] & 0x100) != 0 && @tt_ppem <= a8
      @gs.scan_control = true if (@stack[a] & 0x200) != 0 && @tt_rotated
      @gs.scan_control = true if (@stack[a] & 0x400) != 0 && @tt_stretched
      @gs.scan_control = false if (@stack[a] & 0x800) != 0 && @tt_ppem > a8
      @gs.scan_control = false if (@stack[a] & 0x1000) != 0 && @tt_rotated
      @gs.scan_control = false if (@stack[a] & 0x2000) != 0 && @tt_stretched
    end

    # Ins_SCANTYPE.
    private def ins_scantype(a : Int32) : Nil
      @gs.scan_type = @stack[a].to_i32! & 0xFFFF if @stack[a] >= 0
    end

    # ---- managing outlines ---------------------------------------------------

    # Ins_FLIPPT.
    private def ins_flippt(a : Int32) : Nil
      loop_count = @gs.loop

      if @new_top < loop_count
        if @pedantic_hinting
          err(ERR_TOO_FEW_ARGUMENTS, "Ins_FLIPPT: too few arguments")
        end
        @gs.loop = 1
        return
      end

      @new_top &-= loop_count

      # See `ttinterp.h' for details on backward compatibility mode.
      if @backward_compatibility == 0x7
        @gs.loop = 1
        return
      end

      # C reads the point list downwards from `args' (*(--args)).
      idx = a
      while loop_count > 0
        loop_count &-= 1
        idx &-= 1
        point = to_ushort(@stack[idx])

        if bounds32?(point.to_i64, @pts.n_points)
          if @pedantic_hinting
            err(ERR_INVALID_REFERENCE, "Ins_FLIPPT: point out of zone")
          end
        else
          @pts.tags[point] ^= CURVE_TAG_ON
        end
      end

      @gs.loop = 1
    end

    # Ins_FLIPRGON.
    private def ins_fliprgon(a : Int32) : Nil
      # See `ttinterp.h' for details on backward compatibility mode.
      return if @backward_compatibility == 0x7

      k = to_ushort(@stack[a + 1])
      l = to_ushort(@stack[a])

      if bounds32?(k.to_i64, @pts.n_points) ||
         bounds32?(l.to_i64, @pts.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_FLIPRGON: point out of zone")
        end
        return
      end

      i = l
      while i <= k
        @pts.tags[i] |= CURVE_TAG_ON
        i += 1
      end
    end

    # Ins_FLIPRGOFF.
    private def ins_fliprgoff(a : Int32) : Nil
      # See `ttinterp.h' for details on backward compatibility mode.
      return if @backward_compatibility == 0x7

      k = to_ushort(@stack[a + 1])
      l = to_ushort(@stack[a])

      if bounds32?(k.to_i64, @pts.n_points) ||
         bounds32?(l.to_i64, @pts.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_FLIPRGOFF: point out of zone")
        end
        return
      end

      i = l
      while i <= k
        @pts.tags[i] &= ~CURVE_TAG_ON
        i += 1
      end
    end

    # Compute_Point_Displacement. `ref_zone' is the C `cur' pointer argument
    # (NULL for SHP). Returns {dx, dy, refp} or nil on FAILURE.
    private def compute_point_displacement(ref_zone : Zone?) : {Int64, Int64, Int64}?
      if (@opcode & 1) != 0
        zp = @zp0
        p = @gs.rp1
      else
        zp = @zp1
        p = @gs.rp2
      end

      if bounds32?(p.to_i64, zp.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Compute_Point_Displacement: point out of zone")
        end
        return nil
      end

      # return reference if zones match
      refp = ref_zone.same?(zp) ? p.to_i64 : 0xFFFFFFFF_i64 # ~0U

      # d = PROJECT( zp->cur + p, zp->org + p )
      d = project_call(zp.cur_x[p] &- zp.org_x[p], zp.cur_y[p] &- zp.org_y[p])

      {ft_mulfix(d, @move_vector_x), ft_mulfix(d, @move_vector_y), refp}
    end

    # Move_Zp2_Point.
    private def move_zp2_point(point : Int32, dx : Int64, dy : Int64) : Nil
      if @gs.free_vector_x != 0
        # See `ttinterp.h' for details on backward compatibility mode.
        if @backward_compatibility == 0
          @zp2.cur_x[point] = @zp2.cur_x[point] &+ dx
        end

        @zp2.tags[point] |= CURVE_TAG_TOUCH_X
      end

      if @gs.free_vector_y != 0
        if @backward_compatibility != 0x7
          @zp2.cur_y[point] = @zp2.cur_y[point] &+ dy
        end

        @zp2.tags[point] |= CURVE_TAG_TOUCH_Y
      end
    end

    # Ins_SHP.
    private def ins_shp(a : Int32) : Nil
      loop_count = @gs.loop

      if @new_top < loop_count
        if @pedantic_hinting
          err(ERR_TOO_FEW_ARGUMENTS, "Ins_SHP: too few arguments")
        end
        @gs.loop = 1
        return
      end

      @new_top &-= loop_count

      disp = compute_point_displacement(nil)
      if disp
        dx, dy, _refp = disp

        idx = a
        while loop_count > 0
          loop_count &-= 1
          idx &-= 1
          point = @stack[idx].to_u32!

          if point >= @zp2.n_points.to_u32!
            if @pedantic_hinting
              err(ERR_INVALID_REFERENCE, "Ins_SHP: point out of zone")
            end
          else
            move_zp2_point(point.to_i32!, dx, dy)
          end
        end
      end

      @gs.loop = 1
    end

    # Ins_SHC.
    private def ins_shc(a : Int32) : Nil
      contour = to_ushort(@stack[a])
      bounds = @gs.gep2 == 0 ? 1 : @zp2.n_contours

      if bounds32?(contour.to_i64, bounds)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SHC: bad contour")
        end
        return
      end

      disp = compute_point_displacement(@zp2)
      return unless disp
      dx, dy, refp = disp

      start_pt = contour == 0 ? 0 : @zp2.contours[contour - 1] + 1 - @zp2.first_point

      # we use the number of points if in the twilight zone
      limit = @gs.gep2 == 0 ? @zp2.n_points : @zp2.contours[contour] + 1 - @zp2.first_point

      i = start_pt
      while i < limit
        move_zp2_point(i, dx, dy) if refp != i
        i += 1
      end
    end

    # Ins_SHZ.
    private def ins_shz(a : Int32) : Nil
      # XXX: UNDOCUMENTED! SHZ doesn't move the phantom points,
      #      which must be subtracted.
      case @stack[a].to_i32!
      when 0
        cur = @twilight
        limit = @twilight.n_points
      when 1
        cur = @pts
        limit = @pts.n_points > 4 ? @pts.n_points - 4 : 0
      else
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_SHZ: bad zone")
        end
        return
      end

      disp = compute_point_displacement(cur)
      return unless disp
      dx, dy, refp = disp

      # XXX: UNDOCUMENTED! SHZ doesn't touch the points.
      if dx != 0
        # See `ttinterp.h' for details on backward compatibility mode.
        if @backward_compatibility == 0
          i = 0
          while i < limit
            cur.cur_x[i] = cur.cur_x[i] &+ dx if refp != i
            i += 1
          end
        end
      end

      if dy != 0
        if @backward_compatibility != 0x7
          i = 0
          while i < limit
            cur.cur_y[i] = cur.cur_y[i] &+ dy if refp != i
            i += 1
          end
        end
      end
    end

    # Ins_SHPIX.
    private def ins_shpix(a : Int32) : Nil
      loop_count = @gs.loop

      in_twilight = @gs.gep0 == 0 || @gs.gep1 == 0 || @gs.gep2 == 0

      if @new_top < loop_count
        if @pedantic_hinting
          err(ERR_TOO_FEW_ARGUMENTS, "Ins_SHPIX: too few arguments")
        end
        @gs.loop = 1
        return
      end

      @new_top &-= loop_count

      dx = tt_mulfix14(@stack[a], @gs.free_vector_x.to_i16!.to_i32)
      dy = tt_mulfix14(@stack[a], @gs.free_vector_y.to_i16!.to_i32)

      idx = a
      while loop_count > 0
        loop_count &-= 1
        idx &-= 1
        point = to_ushort(@stack[idx])

        if bounds32?(point.to_i64, @zp2.n_points)
          if @pedantic_hinting
            err(ERR_INVALID_REFERENCE, "Ins_SHPIX: point out of zone")
          end
        else
          if @backward_compatibility != 0
            # Special case: allow SHPIX to move points in the twilight
            # zone.  Otherwise, treat SHPIX the same as DELTAP.
            if in_twilight ||
               (@backward_compatibility != 0x7 &&
                ((@is_composite && @gs.free_vector_y != 0) ||
                 (@zp2.tags[point] & CURVE_TAG_TOUCH_Y) != 0))
              move_zp2_point(point, 0, dy)
            end
          else
            move_zp2_point(point, dx, dy)
          end
        end
      end

      @gs.loop = 1
    end

    # Ins_MSIRP.
    private def ins_msirp(a : Int32) : Nil
      point = to_ushort(@stack[a])

      if bounds32?(point.to_i64, @zp1.n_points) ||
         bounds32?(@gs.rp0.to_i64, @zp0.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_MSIRP: point out of zone")
        end
        return
      end

      # UNDOCUMENTED! The MS rasterizer does that with twilight points
      if @gs.gep1 == 0
        @zp1.org_x[point] = @zp0.org_x[@gs.rp0]
        @zp1.org_y[point] = @zp0.org_y[@gs.rp0]
        move_orig_call(@zp1, point, @stack[a + 1])
        @zp1.cur_x[point] = @zp1.org_x[point]
        @zp1.cur_y[point] = @zp1.org_y[point]
      end

      distance = project_zone(@zp1, point, @zp0, @gs.rp0)

      move_call(@zp1, point, @stack[a + 1] &- distance)

      @gs.rp1 = @gs.rp0
      @gs.rp2 = point

      @gs.rp0 = point if (@opcode & 1) != 0
    end

    # Ins_MDAP.
    private def ins_mdap(a : Int32) : Nil
      point = to_ushort(@stack[a])

      if bounds32?(point.to_i64, @zp0.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_MDAP: point out of zone")
        end
        return
      end

      if (@opcode & 1) != 0
        cur_dist = fast_project(@zp0, point)
        if @native_cleartype_x
          distance = 0_i64
        else
          distance = round_call(cur_dist, 0) &- cur_dist
        end
      else
        distance = 0_i64
      end

      move_call(@zp0, point, distance)

      @gs.rp0 = point
      @gs.rp1 = point
    end

    # Ins_MIAP.
    private def ins_miap(a : Int32) : Nil
      cvt_entry = @stack[a + 1].to_u64!
      point = to_ushort(@stack[a])

      if bounds32?(point.to_i64, @zp0.n_points) ||
         boundsl?(cvt_entry.to_i64!, @cvt_base.size)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_MIAP: out of bounds")
        end
        @gs.rp0 = point
        @gs.rp1 = point
        return
      end

      # UNDOCUMENTED! The behaviour of an MIAP instruction is quite
      # different when used in the twilight zone: the original point is
      # set to the absolute, unrounded distance found in the CVT.
      distance = read_cvt(cvt_entry.to_i32!)

      if @gs.gep0 == 0 # If in twilight zone
        @zp0.org_x[point] = tt_mulfix14(distance, @gs.free_vector_x.to_i16!.to_i32)
        @zp0.org_y[point] = tt_mulfix14(distance, @gs.free_vector_y.to_i16!.to_i32)
        @zp0.cur_x[point] = @zp0.org_x[point]
        @zp0.cur_y[point] = @zp0.org_y[point]
      end

      org_dist = fast_project(@zp0, point)

      if (@opcode & 1) != 0 # rounding and control cut-in flag
        control_value_cutin = @gs.control_value_cutin

        # Native ClearType reduces CVT cut-in to 1/16 in the
        # ClearType direction.
        control_value_cutin >>= 4 if @native_cleartype_x

        delta = distance &- org_dist
        delta = 0_i64 &- delta if delta < 0

        distance = org_dist if delta > control_value_cutin

        distance = round_call(distance, 0) unless @native_cleartype_x
      end

      move_call(@zp0, point, distance &- org_dist)

      @gs.rp0 = point
      @gs.rp1 = point
    end

    # Ins_MDRP.
    private def ins_mdrp(a : Int32) : Nil
      point = to_ushort(@stack[a])

      if bounds32?(point.to_i64, @zp1.n_points) ||
         bounds32?(@gs.rp0.to_i64, @zp0.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_MDRP: point out of zone")
        end
        @gs.rp1 = @gs.rp0
        @gs.rp2 = point
        @gs.rp0 = point if (@opcode & 16) != 0
        return
      end

      # XXX: UNDOCUMENTED: twilight zone special case
      if @gs.gep0 == 0 || @gs.gep1 == 0
        org_dist = dualproj_zone(@zp1, point, @zp0, @gs.rp0)
      else
        if @metrics_x_scale == @metrics_y_scale
          # this should be faster
          org_dist = dual_project_call(@zp1.orus_x[point] &- @zp0.orus_x[@gs.rp0],
                                       @zp1.orus_y[point] &- @zp0.orus_y[@gs.rp0])
          org_dist = ft_mulfix(org_dist, @metrics_x_scale)
        else
          vx = ft_mulfix(@zp1.orus_x[point] &- @zp0.orus_x[@gs.rp0], @metrics_x_scale)
          vy = ft_mulfix(@zp1.orus_y[point] &- @zp0.orus_y[@gs.rp0], @metrics_y_scale)
          org_dist = dual_project_call(vx, vy)
        end
      end

      # single width cut-in test:
      # |org_dist - single_width_value| < single_width_cutin
      if @gs.single_width_cutin > 0 &&
         org_dist < (@gs.single_width_value &+ @gs.single_width_cutin) &&
         org_dist > (@gs.single_width_value &- @gs.single_width_cutin)
        org_dist = org_dist >= 0 ? @gs.single_width_value : (0_i64 &- @gs.single_width_value)
      end

      # round flag
      compensation = @gs.compensation[@opcode & 3]

      if (@opcode & 4) != 0
        if @native_cleartype_x
          distance = round_none(org_dist, compensation)
        else
          distance = round_call(org_dist, compensation)
        end
      else
        distance = round_none(org_dist, compensation)
      end

      # minimum distance flag
      if (@opcode & 8) != 0
        minimum_distance = @gs.minimum_distance

        # Native ClearType reduces minimum distance to 1/2 in the
        # ClearType direction.
        minimum_distance >>= 1 if @native_cleartype_x

        if org_dist >= 0
          distance = minimum_distance if distance < minimum_distance
        else
          distance = 0_i64 &- minimum_distance if distance > (0_i64 &- minimum_distance)
        end
      end

      # now move the point
      org_dist = project_zone(@zp1, point, @zp0, @gs.rp0)

      move_call(@zp1, point, distance &- org_dist)

      @gs.rp1 = @gs.rp0
      @gs.rp2 = point

      @gs.rp0 = point if (@opcode & 16) != 0
    end

    # Ins_MIRP.
    private def ins_mirp(a : Int32) : Nil
      point = to_ushort(@stack[a])
      cvt_entry = (@stack[a + 1] &+ 1).to_u64!

      # XXX: UNDOCUMENTED! cvt[-1] = 0 always
      if bounds32?(point.to_i64, @zp1.n_points) ||
         boundsl?(cvt_entry.to_i64!, @cvt_base.size.to_i64 + 1) ||
         bounds32?(@gs.rp0.to_i64, @zp0.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_MIRP: out of bounds")
        end
        @gs.rp1 = @gs.rp0
        @gs.rp2 = point
        @gs.rp0 = point if (@opcode & 16) != 0
        return
      end

      cvt_dist = cvt_entry == 0 ? 0_i64 : read_cvt(cvt_entry.to_i32! - 1)

      # single width test
      delta = cvt_dist &- @gs.single_width_value
      delta = 0_i64 &- delta if delta < 0

      if delta < @gs.single_width_cutin
        cvt_dist = cvt_dist >= 0 ? @gs.single_width_value : (0_i64 &- @gs.single_width_value)
      end

      # UNDOCUMENTED! The MS rasterizer does that with twilight points
      if @gs.gep1 == 0
        @zp1.org_x[point] = @zp0.org_x[@gs.rp0] &+
                             tt_mulfix14(cvt_dist, @gs.free_vector_x.to_i16!.to_i32)
        @zp1.org_y[point] = @zp0.org_y[@gs.rp0] &+
                             tt_mulfix14(cvt_dist, @gs.free_vector_y.to_i16!.to_i32)
        @zp1.cur_x[point] = @zp1.org_x[point]
        @zp1.cur_y[point] = @zp1.org_y[point]
      end

      org_dist = dual_project_call(@zp1.org_x[point] &- @zp0.org_x[@gs.rp0],
                                   @zp1.org_y[point] &- @zp0.org_y[@gs.rp0])
      cur_dist = project_zone(@zp1, point, @zp0, @gs.rp0)

      # auto-flip test
      if @gs.auto_flip
        cvt_dist = 0_i64 &- cvt_dist if (org_dist ^ cvt_dist) < 0
      end

      # control value cut-in and round
      compensation = @gs.compensation[@opcode & 3]

      if (@opcode & 4) != 0
        # XXX: UNDOCUMENTED! Only perform cut-in test when both points
        #      refer to the same zone.
        if @gs.gep0 == @gs.gep1
          control_value_cutin = @gs.control_value_cutin

          # Native ClearType reduces CVT cut-in to 1/16 in the
          # ClearType direction.
          control_value_cutin >>= 4 if @native_cleartype_x

          delta = cvt_dist &- org_dist
          delta = 0_i64 &- delta if delta < 0

          cvt_dist = org_dist if delta > control_value_cutin
        end

        if @native_cleartype_x
          distance = round_none(cvt_dist, compensation)
        else
          distance = round_call(cvt_dist, compensation)
        end
      else
        distance = round_none(cvt_dist, compensation)
      end

      # minimum distance test
      if (@opcode & 8) != 0
        minimum_distance = @gs.minimum_distance

        minimum_distance >>= 1 if @native_cleartype_x

        if org_dist >= 0
          distance = minimum_distance if distance < minimum_distance
        else
          distance = 0_i64 &- minimum_distance if distance > (0_i64 &- minimum_distance)
        end
      end

      move_call(@zp1, point, distance &- cur_dist)

      @gs.rp1 = @gs.rp0
      @gs.rp2 = point

      @gs.rp0 = point if (@opcode & 16) != 0
    end

    # Ins_ALIGNRP.
    private def ins_alignrp(a : Int32) : Nil
      loop_count = @gs.loop

      if @new_top < loop_count
        if @pedantic_hinting
          err(ERR_TOO_FEW_ARGUMENTS, "Ins_ALIGNRP: too few arguments")
        end
        @gs.loop = 1
        return
      end

      @new_top &-= loop_count

      if bounds32?(@gs.rp0.to_i64, @zp0.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_ALIGNRP: rp0 out of zone")
        end
        @gs.loop = 1
        return
      end

      idx = a
      while loop_count > 0
        loop_count &-= 1
        idx &-= 1
        point = to_ushort(@stack[idx])

        if bounds32?(point.to_i64, @zp1.n_points)
          if @pedantic_hinting
            err(ERR_INVALID_REFERENCE, "Ins_ALIGNRP: point out of zone")
          end
        else
          distance = project_zone(@zp1, point, @zp0, @gs.rp0)

          move_call(@zp1, point, 0_i64 &- distance)
        end
      end

      @gs.loop = 1
    end

    # Ins_ISECT.
    private def ins_isect(a : Int32) : Nil
      point = to_ushort(@stack[a])
      a0 = to_ushort(@stack[a + 1])
      a1 = to_ushort(@stack[a + 2])
      b0 = to_ushort(@stack[a + 3])
      b1 = to_ushort(@stack[a + 4])

      if bounds32?(b0.to_i64, @zp0.n_points) ||
         bounds32?(b1.to_i64, @zp0.n_points) ||
         bounds32?(a0.to_i64, @zp1.n_points) ||
         bounds32?(a1.to_i64, @zp1.n_points) ||
         bounds32?(point.to_i64, @zp2.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_ISECT: point out of zone")
        end
        return
      end

      # Cramer's rule
      dbx = @zp0.cur_x[b1] &- @zp0.cur_x[b0]
      dby = @zp0.cur_y[b1] &- @zp0.cur_y[b0]

      dax = @zp1.cur_x[a1] &- @zp1.cur_x[a0]
      day = @zp1.cur_y[a1] &- @zp1.cur_y[a0]

      dx = @zp0.cur_x[b0] &- @zp1.cur_x[a0]
      dy = @zp0.cur_y[b0] &- @zp1.cur_y[a0]

      discriminant = ft_muldiv(dax, 0_i64 &- dby, 0x40) &+
                     ft_muldiv(day, dbx, 0x40)
      dotproduct = ft_muldiv(dax, dbx, 0x40) &+
                   ft_muldiv(day, dby, 0x40)

      # reject grazing intersections by thresholding abs(tan(angle)) at
      # 1/19, corresponding to 3 degrees
      if (19_i64 &* ft_abs64(discriminant)) > ft_abs64(dotproduct)
        val = ft_muldiv(dx, 0_i64 &- dby, 0x40) &+
              ft_muldiv(dy, dbx, 0x40)

        rx = ft_muldiv(val, dax, discriminant)
        ry = ft_muldiv(val, day, discriminant)

        @zp2.cur_x[point] = @zp1.cur_x[a0] &+ rx
        @zp2.cur_y[point] = @zp1.cur_y[a0] &+ ry
      else
        # else, take the middle of the middles of A and B
        @zp2.cur_x[point] =
          ((@zp1.cur_x[a0] &+ @zp1.cur_x[a1]) &+
           (@zp0.cur_x[b0] &+ @zp0.cur_x[b1])).tdiv(4)
        @zp2.cur_y[point] =
          ((@zp1.cur_y[a0] &+ @zp1.cur_y[a1]) &+
           (@zp0.cur_y[b0] &+ @zp0.cur_y[b1])).tdiv(4)
      end

      @zp2.tags[point] |= CURVE_TAG_TOUCH_BOTH
    end

    # Ins_ALIGNPTS.
    private def ins_alignpts(a : Int32) : Nil
      p1 = to_ushort(@stack[a])
      p2 = to_ushort(@stack[a + 1])

      if bounds32?(p1.to_i64, @zp1.n_points) ||
         bounds32?(p2.to_i64, @zp0.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_ALIGNPTS: point out of zone")
        end
        return
      end

      distance = project_zone(@zp0, p2, @zp1, p1).tdiv(2)

      move_call(@zp1, p1, distance)
      move_call(@zp0, p2, 0_i64 &- distance)
    end

    # Ins_IP.
    private def ins_ip(a : Int32) : Nil
      loop_count = @gs.loop

      if @new_top < loop_count
        if @pedantic_hinting
          err(ERR_TOO_FEW_ARGUMENTS, "Ins_IP: too few arguments")
        end
        @gs.loop = 1
        return
      end

      @new_top &-= loop_count

      if bounds32?(@gs.rp1.to_i64, @zp0.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_IP: rp1 out of zone")
        end
        @gs.loop = 1
        return
      end

      # We need to deal in a special way with the twilight zone.
      twilight = @gs.gep0 == 0 || @gs.gep1 == 0 || @gs.gep2 == 0

      # orus_base / cur_base = zp0.[orus|org|cur] + rp1
      if bounds32?(@gs.rp2.to_i64, @zp1.n_points)
        # Do something sane when this odd thing happens.
        old_range = 0_i64
        cur_range = 0_i64
      else
        if twilight
          old_range = dual_project_call(@zp1.org_x[@gs.rp2] &- @zp0.org_x[@gs.rp1],
                                        @zp1.org_y[@gs.rp2] &- @zp0.org_y[@gs.rp1])
        elsif @metrics_x_scale == @metrics_y_scale
          old_range = dual_project_call(@zp1.orus_x[@gs.rp2] &- @zp0.orus_x[@gs.rp1],
                                        @zp1.orus_y[@gs.rp2] &- @zp0.orus_y[@gs.rp1])
        else
          vx = ft_mulfix(@zp1.orus_x[@gs.rp2] &- @zp0.orus_x[@gs.rp1], @metrics_x_scale)
          vy = ft_mulfix(@zp1.orus_y[@gs.rp2] &- @zp0.orus_y[@gs.rp1], @metrics_y_scale)
          old_range = dual_project_call(vx, vy)
        end

        cur_range = project_zone(@zp1, @gs.rp2, @zp0, @gs.rp1)
      end

      idx = a
      while loop_count > 0
        loop_count &-= 1
        idx &-= 1
        point = @stack[idx].to_u32!

        # check point bounds
        if point >= @zp2.n_points.to_u32!
          if @pedantic_hinting
            err(ERR_INVALID_REFERENCE, "Ins_IP: point out of zone")
          end
          next
        end

        pt = point.to_i32!

        if twilight
          org_dist = dual_project_call(@zp2.org_x[pt] &- @zp0.org_x[@gs.rp1],
                                       @zp2.org_y[pt] &- @zp0.org_y[@gs.rp1])
        elsif @metrics_x_scale == @metrics_y_scale
          org_dist = dual_project_call(@zp2.orus_x[pt] &- @zp0.orus_x[@gs.rp1],
                                       @zp2.orus_y[pt] &- @zp0.orus_y[@gs.rp1])
        else
          vx = ft_mulfix(@zp2.orus_x[pt] &- @zp0.orus_x[@gs.rp1], @metrics_x_scale)
          vy = ft_mulfix(@zp2.orus_y[pt] &- @zp0.orus_y[@gs.rp1], @metrics_y_scale)
          org_dist = dual_project_call(vx, vy)
        end

        cur_dist = project_zone(@zp2, pt, @zp0, @gs.rp1)

        if org_dist != 0
          if old_range != 0
            new_dist = ft_muldiv(org_dist, cur_range, old_range)
          else
            # This is the same as what MS does for the invalid case.
            new_dist = org_dist
          end
        else
          new_dist = 0_i64
        end

        move_call(@zp2, pt, new_dist &- cur_dist)
      end

      @gs.loop = 1
    end

    # Ins_UTP.
    private def ins_utp(a : Int32) : Nil
      point = to_ushort(@stack[a])

      if bounds32?(point.to_i64, @zp0.n_points)
        if @pedantic_hinting
          err(ERR_INVALID_REFERENCE, "Ins_UTP: point out of zone")
        end
        return
      end

      mask = 0xFF_u8

      mask &= ~CURVE_TAG_TOUCH_X if @gs.free_vector_x != 0
      mask &= ~CURVE_TAG_TOUCH_Y if @gs.free_vector_y != 0

      @zp0.tags[point] &= mask
    end

    # iup_worker_shift_.
    private def iup_worker_shift(curs : Array(Int64), orgs : Array(Int64),
                                 p1 : Int32, p2 : Int32, p : Int32) : Nil
      dx = curs[p] &- orgs[p]
      if dx != 0
        i = p1
        while i < p
          curs[i] = curs[i] &+ dx
          i += 1
        end

        i = p + 1
        while i <= p2
          curs[i] = curs[i] &+ dx
          i += 1
        end
      end
    end

    # iup_worker_interpolate_.
    private def iup_worker_interpolate(curs : Array(Int64), orgs : Array(Int64),
                                       orus : Array(Int64), max_points : Int32,
                                       p1 : Int32, p2 : Int32,
                                       ref1 : Int32, ref2 : Int32) : Nil
      return if p1 > p2

      return if ref1 >= max_points || ref1 < 0 || ref2 >= max_points || ref2 < 0

      orus1 = orus[ref1]
      orus2 = orus[ref2]

      if orus1 > orus2
        tmp_o = orus1
        orus1 = orus2
        orus2 = tmp_o

        tmp_r = ref1
        ref1 = ref2
        ref2 = tmp_r
      end

      org1 = orgs[ref1]
      org2 = orgs[ref2]
      cur1 = curs[ref1]
      cur2 = curs[ref2]
      delta1 = cur1 &- org1
      delta2 = cur2 &- org2

      if cur1 == cur2 || orus1 == orus2
        # trivial snap or shift of untouched points
        i = p1
        while i <= p2
          x = orgs[i]

          if x <= org1
            x = x &+ delta1
          elsif x >= org2
            x = x &+ delta2
          else
            x = cur1
          end

          curs[i] = x
          i += 1
        end
      else
        scale = 0_i64
        scale_valid = false

        # interpolation
        i = p1
        while i <= p2
          x = orgs[i]

          if x <= org1
            x = x &+ delta1
          elsif x >= org2
            x = x &+ delta2
          else
            unless scale_valid
              scale_valid = true
              scale = ft_divfix(cur2 &- cur1, orus2 &- orus1)
            end

            x = cur1 &+ ft_mulfix(orus[i] &- orus1, scale)
          end
          curs[i] = x
          i += 1
        end
      end
    end

    # Ins_IUP.
    private def ins_iup : Nil
      # See `ttinterp.h' for details on backward compatibility mode.
      # Allow IUP until it has been called on both axes. Immediately
      # return on subsequent ones.
      if @backward_compatibility == 0x7
        return
      elsif @backward_compatibility != 0
        @backward_compatibility |= 1 << (@opcode & 1)
      end

      # ignore empty outlines
      return if @pts.n_contours == 0

      if (@opcode & 1) != 0
        mask = CURVE_TAG_TOUCH_X
        orgs = @pts.org_x
        curs = @pts.cur_x
        orus = @pts.orus_x
      else
        mask = CURVE_TAG_TOUCH_Y
        orgs = @pts.org_y
        curs = @pts.cur_y
        orus = @pts.orus_y
      end
      max_points = @pts.n_points

      contour = 0
      point = 0

      loop do
        end_point = @pts.contours[contour] - @pts.first_point
        first_point = point

        end_point = @pts.n_points - 1 if end_point >= @pts.n_points || end_point < 0

        while point <= end_point && (@pts.tags[point] & mask) == 0
          point += 1
        end

        if point <= end_point
          first_touched = point
          cur_touched = point

          point += 1

          while point <= end_point
            if (@pts.tags[point] & mask) != 0
              iup_worker_interpolate(curs, orgs, orus, max_points,
                cur_touched + 1, point - 1, cur_touched, point)
              cur_touched = point
            end

            point += 1
          end

          if cur_touched == first_touched
            iup_worker_shift(curs, orgs, first_point, end_point, cur_touched)
          else
            iup_worker_interpolate(curs, orgs, orus, max_points,
              cur_touched + 1, end_point, cur_touched, first_touched)

            if first_touched > 0
              iup_worker_interpolate(curs, orgs, orus, max_points,
                first_point, first_touched - 1, cur_touched, first_touched)
            end
          end
        end
        contour += 1
        break if contour >= @pts.n_contours
      end
    end

    # Ins_DELTAP.
    private def ins_deltap(a : Int32) : Nil
      nump = @stack[a] # signed value for convenience

      if nump < 0 || nump > @new_top.tdiv(2)
        if @pedantic_hinting
          err(ERR_TOO_FEW_ARGUMENTS, "Ins_DELTAP: too few arguments")
        end

        nump = @new_top.tdiv(2)
      end

      @new_top &-= 2 &* nump

      p = current_ppem &- @gs.delta_base.to_i64

      case @opcode
      when 0x5D
        # nothing
      when 0x71
        p &-= 16
      else # 0x72
        p &-= 32
      end

      # check applicable range of adjusted ppem
      return if (p & -16) != 0 # P < 0 || P > 15

      p <<= 4
      f = 1_i64 << (6 - @gs.delta_shift)

      idx = a
      while nump > 0
        nump &-= 1
        idx -= 1
        a_pt = to_ushort(@stack[idx])
        idx -= 1
        b = @stack[idx]

        # Because some popular fonts contain some invalid DeltaP
        # instructions, we simply ignore them when the stacked point
        # reference is off limit, rather than returning an error.
        if bounds32?(a_pt.to_i64, @zp0.n_points)
          if @pedantic_hinting
            err(ERR_INVALID_REFERENCE, "Ins_DELTAP: point out of zone")
          end
        else
          if (b & 0xF0) == p
            b = (b & 0xF) &- 8
            b &+= 1 if b >= 0
            b = b &* f

            # See `ttinterp.h' for details on backward compatibility mode.
            if @backward_compatibility != 0
              if @backward_compatibility != 0x7 &&
                 ((@is_composite && @gs.free_vector_y != 0) ||
                  (@zp0.tags[a_pt] & CURVE_TAG_TOUCH_Y) != 0)
                move_call(@zp0, a_pt, b)
              end
            else
              move_call(@zp0, a_pt, b)
            end
          end
        end
      end
    end

    # Ins_DELTAC.
    private def ins_deltac(a : Int32) : Nil
      nump = @stack[a] # signed value for convenience

      if nump < 0 || nump > @new_top.tdiv(2)
        if @pedantic_hinting
          err(ERR_TOO_FEW_ARGUMENTS, "Ins_DELTAC: too few arguments")
        end

        nump = @new_top.tdiv(2)
      end

      @new_top &-= 2 &* nump

      p = current_ppem &- @gs.delta_base.to_i64

      case @opcode
      when 0x73
        # nothing
      when 0x74
        p &-= 16
      else # 0x75
        p &-= 32
      end

      # check applicable range of adjusted ppem
      return if (p & -16) != 0 # P < 0 || P > 15

      p <<= 4
      f = 1_i64 << (6 - @gs.delta_shift)

      idx = a
      while nump > 0
        nump &-= 1
        idx -= 1
        a_cvt = @stack[idx].to_u64!
        idx -= 1
        b = @stack[idx]

        if boundsl?(a_cvt.to_i64!, @cvt_base.size)
          if @pedantic_hinting
            err(ERR_INVALID_REFERENCE, "Ins_DELTAC: cvt out of range")
          end
        else
          if (b & 0xF0) == p
            b = (b & 0xF) &- 8
            b &+= 1 if b >= 0
            b = b &* f

            move_cvt(a_cvt.to_i32!, b)
          end
        end
      end
    end

    # tt_face_get_cleartype_policy (ttobjs.c), reduced to its inputs.
    private def cleartype_symmetric_smoothing?(ppem : Int32) : Bool
      fit = @max_size_of_instructions != 0

      symmetric = !fit || ppem > 20

      # A valid version-1 `gasp' range explicitly controls the two
      # independent ClearType properties.
      if @gasp_version >= 1
        @gasp_ranges.each do |max_ppem, flags|
          if ppem <= max_ppem
            symmetric = (flags & FT_GASP_SYMMETRIC_SMOOTHING) != 0
            break
          end
        end
      end

      symmetric
    end

    # Ins_GETINFO.
    private def ins_getinfo(a : Int32) : Nil
      k = 0_i64

      k = @interpreter_version.to_i64 if (@stack[a] & 1) != 0

      # GLYPH ROTATED: Selector Bit 1, Return Bit(s) 8
      k |= 1_i64 << 8 if (@stack[a] & 2) != 0 && @tt_rotated

      # GLYPH STRETCHED: Selector Bit 2, Return Bit(s) 9
      k |= 1_i64 << 9 if (@stack[a] & 4) != 0 && @tt_stretched

      # VARIATION GLYPH: Selector Bit 3, Return Bit(s) 10
      k |= 1_i64 << 10 if (@stack[a] & 8) != 0 && @variation_coords

      # BI-LEVEL HINTING AND GRAYSCALE RENDERING:
      # Selector Bit 5, Return Bit(s) 12
      k |= 1_i64 << 12 if (@stack[a] & 32) != 0 && @grayscale

      # Toggle the following flags only outside of monochrome mode.
      if subpixel_hinting? && @render_mode != RENDER_MODE_MONO
        # HINTING FOR SUBPIXEL: Selector Bit 6, Return Bit(s) 13
        # v40 does subpixel hinting by default.
        k |= 1_i64 << 13 if (@stack[a] & 64) != 0

        # VERTICAL LCD SUBPIXELS? Selector Bit 8, Return Bit(s) 15
        k |= 1_i64 << 15 if (@stack[a] & 256) != 0 && @render_mode == RENDER_MODE_LCD_V

        # SUBPIXEL POSITIONED? Selector Bit 10, Return Bit(s) 17
        k |= 1_i64 << 17 if (@stack[a] & 1024) != 0

        # SYMMETRICAL SMOOTHING: Selector Bit 11, Return Bit(s) 18
        if (@stack[a] & 2048) != 0 && @render_mode != RENDER_MODE_MONO
          k |= 1_i64 << 18 if cleartype_symmetric_smoothing?(@metrics_y_ppem)
        end

        # CLEARTYPE HINTING AND GRAYSCALE RENDERING:
        # Selector Bit 12, Return Bit(s) 19
        if (@stack[a] & 4096) != 0 &&
           @render_mode != RENDER_MODE_MONO &&
           @render_mode != RENDER_MODE_LCD &&
           @render_mode != RENDER_MODE_LCD_V
          k |= 1_i64 << 19
        end
      end

      @stack[a] = k
    end

    # Ins_GETVARIATION.
    private def ins_getvariation(a : Int32) : Nil
      coords = @variation_coords.not_nil!
      num_axes = coords.size

      if bounds32?(num_axes.to_i64, @stack_size &+ 1 &- @top)
        err(ERR_STACK_OVERFLOW, "Ins_GETVARIATION: stack overflow")
      end

      i = 0
      while i < num_axes
        @stack[a + i] = coords[i] >> 2 # convert 16.16 to 2.14 format
        i += 1
      end

      @new_top &+= num_axes
    end

    # Ins_GETDATA.
    private def ins_getdata(a : Int32) : Nil
      @stack[a] = 17
    end

    # Ins_UNKNOWN.
    private def ins_unknown : Nil
      i = 0
      while i < @num_idefs
        def_rec = @idefs[i]
        if def_rec.opc.to_u8! == @opcode && def_rec.active
          if @call_top >= @call_size
            err(ERR_STACK_OVERFLOW, "Ins_UNKNOWN: call stack overflow")
          end

          call = @call_stack[@call_top]
          @call_top += 1

          call.caller_range = @cur_range
          call.caller_ip = @ip + 1
          call.cur_count = 1
          call.def_rec = def_rec

          goto_code_range(def_rec.range, def_rec.start_)

          return
        end
        i += 1
      end

      err(ERR_INVALID_OPCODE, "Ins_UNKNOWN: invalid opcode 0x%02X" % @opcode)
    end

    # ---- THE INTERPRETER'S MAIN LOOP (TT_RunIns) ---------------------------

    private def exec_opcode(a : Int32) : Nil
      case @opcode
      when 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 # SVTCA/SPVTCA/SFVTCA
        ins_sxytca
      when 0x06, 0x07 # SPvTL
        ins_spvtl(a)
      when 0x08, 0x09 # SFvTL
        ins_sfvtl(a)
      when 0x0A # SPvFS
        ins_spvfs(a)
      when 0x0B # SFvFS
        ins_sfvfs(a)
      when 0x0C # GPv
        ins_gpv(a)
      when 0x0D # GFv
        ins_gfv(a)
      when 0x0E # SFvTPv
        ins_sfvtpv
      when 0x0F # ISECT
        ins_isect(a)
      when 0x10 # SRP0
        ins_srp0(a)
      when 0x11 # SRP1
        ins_srp1(a)
      when 0x12 # SRP2
        ins_srp2(a)
      when 0x13 # SZP0
        ins_szp0(a)
      when 0x14 # SZP1
        ins_szp1(a)
      when 0x15 # SZP2
        ins_szp2(a)
      when 0x16 # SZPS
        ins_szps(a)
      when 0x17 # SLOOP
        ins_sloop(a)
      when 0x18 # RTG
        ins_rtg
      when 0x19 # RTHG
        ins_rthg
      when 0x1A # SMD
        ins_smd(a)
      when 0x1B # ELSE
        ins_else
      when 0x1C # JMPR
        ins_jmpr(a)
      when 0x1D # SCVTCI
        ins_scvtci(a)
      when 0x1E # SSWCI
        ins_sswci(a)
      when 0x1F # SSW
        ins_ssw(a)
      when 0x20 # DUP
        ins_dup(a)
      when 0x21 # POP
        # nothing to do
      when 0x22 # CLEAR
        ins_clear
      when 0x23 # SWAP
        ins_swap(a)
      when 0x24 # DEPTH
        ins_depth(a)
      when 0x25 # CINDEX
        ins_cindex(a)
      when 0x26 # MINDEX
        ins_mindex(a)
      when 0x27 # ALIGNPTS
        ins_alignpts(a)
      when 0x28 # RAW
        ins_unknown
      when 0x29 # UTP
        ins_utp(a)
      when 0x2A # LOOPCALL
        ins_loopcall(a)
      when 0x2B # CALL
        ins_call(a)
      when 0x2C # FDEF
        ins_fdef(a)
      when 0x2D # ENDF
        ins_endf
      when 0x2E, 0x2F # MDAP
        ins_mdap(a)
      when 0x30, 0x31 # IUP
        ins_iup
      when 0x32, 0x33 # SHP
        ins_shp(a)
      when 0x34, 0x35 # SHC
        ins_shc(a)
      when 0x36, 0x37 # SHZ
        ins_shz(a)
      when 0x38 # SHPIX
        ins_shpix(a)
      when 0x39 # IP
        ins_ip(a)
      when 0x3A, 0x3B # MSIRP
        ins_msirp(a)
      when 0x3C # AlignRP
        ins_alignrp(a)
      when 0x3D # RTDG
        ins_rtdg
      when 0x3E, 0x3F # MIAP
        ins_miap(a)
      when 0x40 # NPUSHB
        ins_npushb(a)
      when 0x41 # NPUSHW
        ins_npushw(a)
      when 0x42 # WS
        ins_ws(a)
      when 0x43 # RS
        ins_rs(a)
      when 0x44 # WCVTP
        ins_wcvtp(a)
      when 0x45 # RCVT
        ins_rcvt(a)
      when 0x46, 0x47 # GC
        ins_gc(a)
      when 0x48 # SCFS
        ins_scfs(a)
      when 0x49, 0x4A # MD
        ins_md(a)
      when 0x4B # MPPEM
        ins_mppem(a)
      when 0x4C # MPS
        ins_mps(a)
      when 0x4D # FLIPON
        ins_flipon
      when 0x4E # FLIPOFF
        ins_flipoff
      when 0x4F # DEBUG
        ins_debug
      when 0x50 # LT
        ins_lt(a)
      when 0x51 # LTEQ
        ins_lteq(a)
      when 0x52 # GT
        ins_gt(a)
      when 0x53 # GTEQ
        ins_gteq(a)
      when 0x54 # EQ
        ins_eq(a)
      when 0x55 # NEQ
        ins_neq(a)
      when 0x56 # ODD
        ins_odd(a)
      when 0x57 # EVEN
        ins_even(a)
      when 0x58 # IF
        ins_if(a)
      when 0x59 # EIF
        # nothing to do
      when 0x5A # AND
        ins_and(a)
      when 0x5B # OR
        ins_or(a)
      when 0x5C # NOT
        ins_not(a)
      when 0x5D # DELTAP1
        ins_deltap(a)
      when 0x5E # SDB
        ins_sdb(a)
      when 0x5F # SDS
        ins_sds(a)
      when 0x60 # ADD
        ins_add(a)
      when 0x61 # SUB
        ins_sub(a)
      when 0x62 # DIV
        ins_div(a)
      when 0x63 # MUL
        ins_mul(a)
      when 0x64 # ABS
        ins_abs(a)
      when 0x65 # NEG
        ins_neg(a)
      when 0x66 # FLOOR
        ins_floor(a)
      when 0x67 # CEILING
        ins_ceiling(a)
      when 0x68, 0x69, 0x6A, 0x6B # ROUND
        ins_round(a)
      when 0x6C, 0x6D, 0x6E, 0x6F # NROUND
        ins_nround(a)
      when 0x70 # WCVTF
        ins_wcvtf(a)
      when 0x71, 0x72 # DELTAP2, DELTAP3
        ins_deltap(a)
      when 0x73, 0x74, 0x75 # DELTAC1, DELTAC2, DELTAC3
        ins_deltac(a)
      when 0x76 # SROUND
        ins_sround(a)
      when 0x77 # S45Round
        ins_s45round(a)
      when 0x78 # JROT
        ins_jrot(a)
      when 0x79 # JROF
        ins_jrof(a)
      when 0x7A # ROFF
        ins_roff
      when 0x7B # ????
        ins_unknown
      when 0x7C # RUTG
        ins_rutg
      when 0x7D # RDTG
        ins_rdtg
      when 0x7E # SANGW
        ins_sangw
      when 0x7F # AA
        ins_aa
      when 0x80 # FLIPPT
        ins_flippt(a)
      when 0x81 # FLIPRGON
        ins_fliprgon(a)
      when 0x82 # FLIPRGOFF
        ins_fliprgoff(a)
      when 0x83, 0x84 # UNKNOWN
        ins_unknown
      when 0x85 # SCANCTRL
        ins_scanctrl(a)
      when 0x86, 0x87 # SDPvTL
        ins_sdpvtl(a)
      when 0x88 # GETINFO
        ins_getinfo(a)
      when 0x89 # IDEF
        ins_idef(a)
      when 0x8A # ROLL
        ins_roll(a)
      when 0x8B # MAX
        ins_max(a)
      when 0x8C # MIN
        ins_min(a)
      when 0x8D # SCANTYPE
        ins_scantype(a)
      when 0x8E # INSTCTRL
        ins_instctrl(a)
      when 0x8F, 0x90 # ADJUST
        ins_unknown
      when 0x91
        # It is the job of the application to `activate' GX handling;
        # variation_coords non-nil stands for face->blend.
        if @variation_coords
          ins_getvariation(a)
        else
          ins_unknown
        end
      when 0x92
        # GETDATA is active for GX fonts only, similar to GETVARIATION.
        if @variation_coords
          ins_getdata(a)
        else
          ins_unknown
        end
      else
        if @opcode >= 0xE0
          ins_mirp(a)
        elsif @opcode >= 0xC0
          ins_mdrp(a)
        elsif @opcode >= 0xB8
          ins_pushw(a)
        elsif @opcode >= 0xB0
          ins_pushb(a)
        else
          ins_unknown
        end
      end
    end

    # TT_RunIns.
    private def run_ins : Nil
      @ins_counter = 0

      loop do
        # increment instruction counter and check if we didn't
        # run this program for too long (e.g. infinite loops).
        @ins_counter &+= 1
        if @ins_counter > TT_CONFIG_OPTION_MAX_RUNNABLE_OPCODES
          err(ERR_EXECUTION_TOO_LONG, "TT_RunIns: execution too long")
        end

        @opcode = @code[@ip]
        @length = 1

        if TRACE_ENABLED
          cnt = {8_i64, @top}.min
          buf = String.build do |b|
            b.printf("%06d op=%02x m%d p%d f(%x,%x) p(%x,%x) #", @ip, @opcode,
                     @func_move, @func_project,
                     @gs.free_vector_x & 0xFFFF, @gs.free_vector_y & 0xFFFF,
                     @gs.proj_vector_x & 0xFFFF, @gs.proj_vector_y & 0xFFFF)
            (1..cnt).each { |n| b.print ' ', @stack[@top - n] }
          end
          STDERR.puts buf
          if @cur_range == CODERANGE_GLYPH && @pts.n_points > 0
            zbuf = String.build do |b|
              b.printf("  Z %06d", @ip)
              @pts.n_points.times do |n|
                tag = @pts.tags[n + @pts.first_point]
                b.print ' ', @pts.cur_x[n + @pts.first_point], ',',
                        @pts.cur_y[n + @pts.first_point], '/',
                        (tag < 16 ? "0" : ""), tag.to_s(16)
              end
              b << '\n'
            end
            STDERR.puts zbuf
          end
        end

        # First, let's check for empty stack and overflow
        @args_base = @top - (POP_PUSH_COUNT[@opcode] >> 4).to_i64

        # `args' is the top of the stack once arguments have been popped.
        if @args_base < 0
          if @pedantic_hinting
            err(ERR_TOO_FEW_ARGUMENTS, "TT_RunIns: too few arguments")
          end

          # push zeroes onto the stack
          i = 0
          pops = (POP_PUSH_COUNT[@opcode] >> 4)
          while i < pops
            @stack[i] = 0
            i += 1
          end
          @args_base = 0
        end

        @new_top = @args_base + (POP_PUSH_COUNT[@opcode] & 15).to_i64

        # `new_top' is the new top of the stack, after the instruction's
        # execution.
        if @new_top > @stack_size
          err(ERR_STACK_OVERFLOW, "TT_RunIns: stack overflow")
        end

        exec_opcode(@args_base.to_i32!)

        @top = @new_top
        @ip &+= @length

        if @ip >= @code_size
          if @call_top > 0
            err(ERR_CODE_OVERFLOW, "TT_RunIns: code overflow")
          else
            return
          end
        end

        break if @instruction_trap
      end
    end

    # TT_Run_Context: per-run setup, then TT_RunIns.
    private def run_context : Nil
      @zp0 = @pts
      @zp1 = @pts
      @zp2 = @pts

      # We restrict the number of twilight points to a reasonable,
      # heuristic value to avoid slow execution of malformed bytecode.
      num_twilight_points = {30_i64, 2_i64 &* (@pts.n_points.to_i64 &+ @cvt_base.size.to_i64)}.max
      if @twilight.n_points.to_i64 > num_twilight_points
        num_twilight_points = 0xFFFF_i64 if num_twilight_points > 0xFFFF

        # C semantics: exec->twilight is a struct *copy* of size->twilight,
        # so the clamp does not touch the caller's zone. Share the arrays
        # through a shallow clone.
        clamped = Zone.new(num_twilight_points.to_i32!, @twilight.n_contours,
          @twilight.cur_x, @twilight.cur_y, @twilight.org_x, @twilight.org_y,
          @twilight.orus_x, @twilight.orus_y, @twilight.tags,
          @twilight.contours, @twilight.first_point)
        @twilight = clamped
      end

      # Set up loop detectors.
      @loopcall_counter = 0
      @neg_jump_counter = 0

      if @pts.n_points != 0
        @loopcall_counter_max = ({50_i64, 10_i64 &* @pts.n_points}.max &+
                                 {50_i64, @cvt_base.size.to_i64 // 10}.max).to_u64!
      else
        @loopcall_counter_max = (300_u64 &+ 22_u64 &* @cvt_base.size.to_u64!).to_u64!
      end

      # as a protection against an unreasonable number of CVT entries
      # we assume at most 100 control values per glyph for the counter
      cap = 100_u64 &* @num_glyphs.to_u64!
      @loopcall_counter_max = cap if @loopcall_counter_max > cap

      @neg_jump_counter_max = @loopcall_counter_max

      # set PPEM and CVT functions
      if @metrics_x_ppem != @metrics_y_ppem
        # non-square pixels, use the stretched routines
        @func_cur_ppem_stretched = true
        @func_cvt_stretched = true
      else
        # square pixels, use normal routines
        @func_cur_ppem_stretched = false
        @func_cvt_stretched = false
      end

      # reset graphics state
      @gs.assign(@saved_gs)
      @func_round = ROUND_FUNC_TO_GRID
      compute_funcs

      # Reset IUP tracking bits in the backward compatibility mode.
      @backward_compatibility &= ~0x3

      # some glyphs leave something on the stack,
      # so we clean it before a new execution.
      @top = 0
      @call_top = 0

      @instruction_trap = false

      run_ins
    end

    # ---- public entry points ------------------------------------------------

    # Execute a glyph program. The caller is responsible for the full
    # ttgload.c TT_Hint_Glyph/tt_loader_init context:
    #   * pts = the loaded/scaled zone, with org copied from cur, orus set,
    #     phantom points already FT_PIX_ROUNDed;
    #   * is_composite, backward_compatibility (from instruct_control & 4,
    #     only when interpreter_version == 40 && render_mode != MONO &&
    #     !is_tricky), metrics, ppem, scales set;
    #   * code ranges FONT/CVT already registered via run_fpgm/run_prep.
    def run(code : Bytes) : Nil
      load_context
      set_code_range(CODERANGE_GLYPH, code)
      run_context
    end

    # Glue helper (loader.cr protocol): install the glyph zone from
    # parallel arrays. `org_x`/`org_y` default to copies of `cur` (the
    # TT_Hint_Glyph "save original point positions in `org'" step).
    def set_zone(cur_x : Array(Int64), cur_y : Array(Int64),
                 org_x : Array(Int64)?, org_y : Array(Int64)?,
                 orus_x : Array(Int64), orus_y : Array(Int64),
                 tags : Array(UInt8), contours : Array(Int32),
                 n_points : Int32) : Nil
      @pts = Zone.new(n_points, contours.size,
        cur_x, cur_y,
        org_x || cur_x.dup, org_y || cur_y.dup,
        orus_x, orus_y, tags, contours, 0)
    end

    # Glue helper (loader.cr protocol): tt_size_run_prep zeroes all
    # twilight points (org and cur); tags, like in C, are NOT cleared.
    # n_points goes back to the allocated capacity.
    def reset_twilight : Nil
      @twilight.org_x.fill(0_i64)
      @twilight.org_y.fill(0_i64)
      @twilight.cur_x.fill(0_i64)
      @twilight.cur_y.fill(0_i64)
      @twilight.n_points = @twilight.cur_x.size
    end

    # tt_size_run_fpgm (ttobjs.c): context reset, run the `fpgm' table.
    def run_fpgm(code : Bytes) : Nil
      load_context

      # disable CVT and glyph programs coderange
      clear_code_range(CODERANGE_CVT)
      clear_code_range(CODERANGE_GLYPH)

      if code.size > 0
        # allow font program execution
        set_code_range(CODERANGE_FONT, code)

        @pts.n_points = 0
        @pts.n_contours = 0

        run_context

        save_context
      end
    end

    # tt_size_run_prep (ttobjs.c): reset GS/twilight/storage, scale the CVT,
    # run the `prep' table.
    def run_prep(code : Bytes) : Nil
      # set default GS, twilight points, and storage
      # before CV program can modify them.
      @saved_gs = GraphicsState.default

      # all twilight points are originally zero
      @twilight.org_x.fill(0_i64)
      @twilight.org_y.fill(0_i64)
      @twilight.cur_x.fill(0_i64)
      @twilight.cur_y.fill(0_i64)

      load_context

      # clear storage area
      @storage_base.fill(0_i64)

      # Scale the cvt values to the new ppem.
      # By default, we use the y ppem value for scaling.
      i = 0
      while i < @cvt_base.size
        # Unscaled CVT values are already stored in 26.6 format. The
        # integer division by 64 must be applied to the first argument.
        @cvt_base[i] = ft_mulfix(@cvt_raw[i].to_i32! // 64, @tt_scale)
        i += 1
      end

      clear_code_range(CODERANGE_GLYPH)

      if code.size > 0
        # allow CV program execution
        set_code_range(CODERANGE_CVT, code)

        @pts.n_points = 0
        @pts.n_contours = 0

        run_context

        save_context
      end
    end
  end
end

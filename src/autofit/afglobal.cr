# afglobal.cr — a port of FreeType's `src/autofit/afglobal.c': assigns a
# style to every glyph of a face (af_face_globals_compute_style_coverage)
# and lazily creates per-style metrics. The style table mirrors the order
# of `af_style_classes' (afstyles.h) — the scan order defines which
# script wins on (rare) overlapping Unicode ranges. Unicode ranges are
# from `afranges.c'. Blue stringsets exist for the latin writing system
# (latn/cyrl/grek fully ported); other scripts keep their ranges so the
# style assignment matches, but activating one raises (not needed for
# the latin/cyrillic/greek corpora).
require "./afhints"
require "./afblue_data"
require "./afranges_data"
require "./aflatin"
require "./afcjk"

module Autofit
  # glyph_styles bits (afglobal.h: AF_STYLE_MASK 0x3FFF, AF_NONBASE
  # 0x4000, AF_DIGIT 0x8000; unassigned == the style mask itself)
  STYLE_UNASSIGNED = 0x3FFF_u16
  STYLE_MASK       = 0x3FFF_u16
  NONBASE          = 0x4000_u16
  DIGIT            = 0x8000_u16

  module Ws
    Latin = 1
    Dummy = 2
    Cjk   = 3
  end

  class StyleClass
    getter name : Symbol
    getter writing_system : Int32
    getter stringset : Symbol?    # blue stringset (nil: no blue zones)
    getter ranges : Array({Int32, Int32})
    getter nonbase_ranges : Array({Int32, Int32})

    def initialize(@name, @writing_system, @stringset,
                   @ranges, @nonbase_ranges)
    end
  end

  R0 = [] of {Int32, Int32}

  # af_style_classes in afstyles.h order (DEFAULT-coverage styles only;
  # the feature-based styles (smcp, sups, ...) never get coverage without
  # harfbuzz and are skipped at scan time anyway).
  STYLE_CLASSES = [
    StyleClass.new(:adlm, Ws::Latin, :adlm, RANGES_ADLM, NONBASE_ADLM),
    StyleClass.new(:arab, Ws::Latin, :arab, RANGES_ARAB, NONBASE_ARAB),
    StyleClass.new(:armn, Ws::Latin, :armn, RANGES_ARMN, NONBASE_ARMN),
    StyleClass.new(:avst, Ws::Latin, :avst, RANGES_AVST, NONBASE_AVST),
    StyleClass.new(:bamu, Ws::Latin, :bamu, RANGES_BAMU, NONBASE_BAMU),
    StyleClass.new(:beng, Ws::Latin, :beng, RANGES_BENG, NONBASE_BENG),
    StyleClass.new(:buhd, Ws::Latin, :buhd, RANGES_BUHD, NONBASE_BUHD),
    StyleClass.new(:cakm, Ws::Latin, :cakm, RANGES_CAKM, NONBASE_CAKM),
    StyleClass.new(:cans, Ws::Latin, :cans, RANGES_CANS, NONBASE_CANS),
    StyleClass.new(:cari, Ws::Latin, :cari, RANGES_CARI, NONBASE_CARI),
    StyleClass.new(:cher, Ws::Latin, :cher, RANGES_CHER, NONBASE_CHER),
    StyleClass.new(:copt, Ws::Latin, :copt, RANGES_COPT, NONBASE_COPT),
    StyleClass.new(:cprt, Ws::Latin, :cprt, RANGES_CPRT, NONBASE_CPRT),
    StyleClass.new(:cyrl, Ws::Latin, :cyrl, RANGES_CYRL, NONBASE_CYRL),
    StyleClass.new(:deva, Ws::Latin, :deva, RANGES_DEVA, NONBASE_DEVA),
    StyleClass.new(:dsrt, Ws::Latin, :dsrt, RANGES_DSRT, NONBASE_DSRT),
    StyleClass.new(:ethi, Ws::Latin, :ethi, RANGES_ETHI, NONBASE_ETHI),
    StyleClass.new(:geor, Ws::Latin, :geor, RANGES_GEOR, NONBASE_GEOR),
    StyleClass.new(:geok, Ws::Latin, :geok, RANGES_GEOK, NONBASE_GEOK),
    StyleClass.new(:glag, Ws::Latin, :glag, RANGES_GLAG, NONBASE_GLAG),
    StyleClass.new(:goth, Ws::Latin, :goth, RANGES_GOTH, NONBASE_GOTH),
    StyleClass.new(:grek, Ws::Latin, :grek, RANGES_GREK, NONBASE_GREK),
    StyleClass.new(:gujr, Ws::Latin, :gujr, RANGES_GUJR, NONBASE_GUJR),
    StyleClass.new(:guru, Ws::Latin, :guru, RANGES_GURU, NONBASE_GURU),
    StyleClass.new(:hebr, Ws::Latin, :hebr, RANGES_HEBR, NONBASE_HEBR),
    StyleClass.new(:kali, Ws::Latin, :kali, RANGES_KALI, NONBASE_KALI),
    StyleClass.new(:khmr, Ws::Latin, :khmr, RANGES_KHMR, NONBASE_KHMR),
    StyleClass.new(:khms, Ws::Latin, :khms, RANGES_KHMS, NONBASE_KHMS),
    StyleClass.new(:knda, Ws::Latin, :knda, RANGES_KNDA, NONBASE_KNDA),
    StyleClass.new(:lao, Ws::Latin, :lao, RANGES_LAO, NONBASE_LAO),
    StyleClass.new(:latn, Ws::Latin, :latn, RANGES_LATN, NONBASE_LATN),
    StyleClass.new(:latb, Ws::Latin, :latb, RANGES_LATB, NONBASE_LATB),
    StyleClass.new(:latp, Ws::Latin, :latp, RANGES_LATP, NONBASE_LATP),
    StyleClass.new(:lisu, Ws::Latin, :lisu, RANGES_LISU, NONBASE_LISU),
    StyleClass.new(:mlym, Ws::Latin, :mlym, RANGES_MLYM, NONBASE_MLYM),
    StyleClass.new(:medf, Ws::Latin, :medf, RANGES_MEDF, NONBASE_MEDF),
    StyleClass.new(:mong, Ws::Latin, :mong, RANGES_MONG, NONBASE_MONG),
    StyleClass.new(:mymr, Ws::Latin, :mymr, RANGES_MYMR, NONBASE_MYMR),
    StyleClass.new(:nkoo, Ws::Latin, :nkoo, RANGES_NKOO, NONBASE_NKOO),
    StyleClass.new(:none, Ws::Dummy, nil, R0, R0),
    StyleClass.new(:olck, Ws::Latin, :olck, RANGES_OLCK, NONBASE_OLCK),
    StyleClass.new(:orkh, Ws::Latin, :orkh, RANGES_ORKH, NONBASE_ORKH),
    StyleClass.new(:osge, Ws::Latin, :osge, RANGES_OSGE, NONBASE_OSGE),
    StyleClass.new(:osma, Ws::Latin, :osma, RANGES_OSMA, NONBASE_OSMA),
    StyleClass.new(:rohg, Ws::Latin, :rohg, RANGES_ROHG, NONBASE_ROHG),
    StyleClass.new(:saur, Ws::Latin, :saur, RANGES_SAUR, NONBASE_SAUR),
    StyleClass.new(:shaw, Ws::Latin, :shaw, RANGES_SHAW, NONBASE_SHAW),
    StyleClass.new(:sinh, Ws::Latin, :sinh, RANGES_SINH, NONBASE_SINH),
    StyleClass.new(:sund, Ws::Latin, :sund, RANGES_SUND, NONBASE_SUND),
    StyleClass.new(:taml, Ws::Latin, :taml, RANGES_TAML, NONBASE_TAML),
    StyleClass.new(:tavt, Ws::Latin, :tavt, RANGES_TAVT, NONBASE_TAVT),
    StyleClass.new(:telu, Ws::Latin, :telu, RANGES_TELU, NONBASE_TELU),
    StyleClass.new(:tfng, Ws::Latin, :tfng, RANGES_TFNG, NONBASE_TFNG),
    StyleClass.new(:thai, Ws::Latin, :thai, RANGES_THAI, NONBASE_THAI),
    StyleClass.new(:vaii, Ws::Latin, :vaii, RANGES_VAII, NONBASE_VAII),
    StyleClass.new(:limb, Ws::Latin, nil, RANGES_LIMB, NONBASE_LIMB),
    StyleClass.new(:orya, Ws::Latin, nil, RANGES_ORYA, NONBASE_ORYA),
    StyleClass.new(:sylo, Ws::Latin, nil, RANGES_SYLO, NONBASE_SYLO),
    StyleClass.new(:tibt, Ws::Latin, nil, RANGES_TIBT, NONBASE_TIBT),
    StyleClass.new(:hani, Ws::Cjk, :hani, RANGES_HANI, NONBASE_HANI),
  ] of StyleClass

  # module->default_script = AF_SCRIPT_LATN; with the CJK writing
  # system ported, the fallback style is HANI_DFLT (afglobal.h:
  # AF_STYLE_FALLBACK == AF_STYLE_HANI_DFLT when AF_CONFIG_OPTION_CJK
  # is defined — the default of distribution builds), otherwise
  # NONE_DFLT.
  DEFAULT_STYLE = STYLE_CLASSES.index { |s| s.name == :latn }.not_nil!
  FALLBACK_STYLE = STYLE_CLASSES.index { |s| s.name == :hani }.not_nil!

  # AF_FaceGlobals: style per glyph + lazily built metrics.
  class FaceGlobals
    getter glyph_styles : Array(UInt16)
    getter metrics : Array(LatinMetrics | CjkMetrics | Nil)
    getter units_per_em : Int32
    getter adapter : FontFaceAdapter

    def initialize(@adapter : FontFaceAdapter, num_glyphs : Int32,
                   @units_per_em : Int32)
      @glyph_styles = Array(UInt16).new(num_glyphs, STYLE_UNASSIGNED)
      @metrics = Array(LatinMetrics | CjkMetrics | Nil).new(STYLE_CLASSES.size, nil)

      compute_style_coverage(num_glyphs)
    end

    private def compute_style_coverage(num_glyphs : Int32) : Nil
      # scan each style in order; DEFAULT-coverage styles assign the
      # style to still-uncovered glyphs in their Unicode ranges
      STYLE_CLASSES.each_with_index do |style, ss|
        style.ranges.each do |first, last|
          charcode = first
          while charcode <= last
            gindex = @adapter.glyph_index(charcode)
            if gindex != 0 && gindex < num_glyphs &&
               (@glyph_styles[gindex] & STYLE_MASK) == STYLE_UNASSIGNED
              @glyph_styles[gindex] = ss.to_u16!
            end
            charcode += 1
          end
        end

        # the script's non-base characters
        style.nonbase_ranges.each do |first, last|
          charcode = first
          while charcode <= last
            gindex = @adapter.glyph_index(charcode)
            if gindex != 0 && gindex < num_glyphs &&
               (@glyph_styles[gindex] & STYLE_MASK) == ss
              @glyph_styles[gindex] |= NONBASE
            end
            charcode += 1
          end
        end
      end

      # mark ASCII digits
      (0x30..0x39).each do |i|
        gindex = @adapter.glyph_index(i)
        @glyph_styles[gindex] |= DIGIT if gindex != 0 && gindex < num_glyphs
      end

      # uncovered glyphs take the fallback style
      (0...num_glyphs).each do |nn|
        if (@glyph_styles[nn] & STYLE_MASK) == STYLE_UNASSIGNED
          @glyph_styles[nn] &= ~STYLE_MASK
          @glyph_styles[nn] |= FALLBACK_STYLE.to_u16!
        end
      end
    end

    # af_face_globals_get_metrics (lazily creates the style metrics; a
    # latin style without blue zones is disabled and its glyphs fall
    # back to the fallback style, exactly as FreeType's internal error
    # -1 handling; a CJK style is never disabled).
    def get_metrics(gindex : Int32) : LatinMetrics | CjkMetrics
      loop do
        style = (@glyph_styles[gindex] & STYLE_MASK).to_i32
        m = @metrics[style]
        return m if m

        style_class = STYLE_CLASSES[style]
        if !style_class.stringset.nil? &&
           (style_class.writing_system == Ws::Latin ||
            style_class.writing_system == Ws::Cjk)
          m = if style_class.writing_system == Ws::Cjk
            CjkMetrics.new(style_class, @units_per_em)
          else
            LatinMetrics.new(style_class, @units_per_em)
          end
          if m.is_a?(CjkMetrics)
            m.init(@adapter)
          elsif !m.init(@adapter)
            # no blue zones: disable this style for the whole face —
            # its glyphs go to `none_dflt' (the dummy writing system),
            # exactly as af_latin_metrics_init_blues's `gstyles[i] =
            # AF_STYLE_NONE_DFLT' (NOT the module fallback style)
            none_style = STYLE_CLASSES.index { |s| s.name == :none }.not_nil!
            (0...@glyph_styles.size).each do |i|
              if (@glyph_styles[i] & STYLE_MASK).to_i32 == style
                @glyph_styles[i] = none_style.to_u16!
              end
            end
            next
          end
        else
          # the dummy writing system (Ws::Dummy; unreachable now that
          # the fallback style is hani, kept for completeness)
          m = LatinMetrics.new(STYLE_CLASSES[FALLBACK_STYLE], @units_per_em,
                               dummy: true)
        end
        @metrics[style] = m
        return m
      end
    end

    def is_digit?(gindex : Int32) : Bool
      gindex < @glyph_styles.size && (@glyph_styles[gindex] & DIGIT) != 0
    end
  end
end

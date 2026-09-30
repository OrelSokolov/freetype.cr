# Probe the system FreeType's TrueType interpreter version and related
# runtime properties — decides which bytecode behavior the port must replicate.
# Run: crystal run --release spec/interp_probe.cr
@[Link("freetype")]
lib LibFT2
  fun init_free_type = FT_Init_FreeType(a_library : Void**) : Int32
  fun property_get = FT_Property_Get(library : Void*, module_name : UInt8*,
                                     property_name : UInt8*, value : Void*) : Int32
  fun done_free_type = FT_Done_FreeType(library : Void*) : Int32
end

lib_ptr = uninitialized Void*
raise "init" if LibFT2.init_free_type(pointerof(lib_ptr)) != 0

{"interpreter-version", "hinting-engine", "no-stem-darkening"}.each do |prop|
  val = uninitialized Int32
  err = LibFT2.property_get(lib_ptr, "truetype".to_unsafe, prop.to_unsafe,
                            pointerof(val).as(Void*))
  puts prop.inspect + " -> " + (err == 0 ? val.to_s : "err #{err}")
end

# also the CFF module's hinting engine, out of curiosity
val = uninitialized Int32
err = LibFT2.property_get(lib_ptr, "cff".to_unsafe, "hinting-engine".to_unsafe,
                          pointerof(val).as(Void*))
puts "cff hinting-engine -> " + (err == 0 ? val.to_s : "err #{err}")

LibFT2.done_free_type(lib_ptr)

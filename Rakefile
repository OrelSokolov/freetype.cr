SRC = "src/freetype-cr.cr"
OUT_DEV = "build/freetype-cr_dev"
OUT_RELEASE = "build/freetype-cr_release"

# The shard is a library — "building" it is a full compile check of
# src/freetype-cr.cr (the same smoke build CI runs), the binaries are
# throwaway. build:dev for iteration (fast, parallel codegen), release
# for checking the --release path end to end.
task default: :"build:dev"

namespace :build do
  desc "Compile-check the shard without --release (fast iteration)"
  task :dev do
    mkdir_p File.dirname(OUT_DEV)
    sh "crystal build -o #{OUT_DEV} #{SRC}"
  end

  desc "Compile-check the shard with --release"
  task :release do
    mkdir_p File.dirname(OUT_RELEASE)
    sh "crystal build --release -o #{OUT_RELEASE} #{SRC}"
  end
end

desc "Remove build artifacts"
task :clean do
  rm_rf "build"
end

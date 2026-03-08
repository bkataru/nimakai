# Package
version       = "0.1.0"
author        = "bkataru"
description   = "NVIDIA NIM model latency benchmarker"
license       = "MIT"
srcDir        = "src"
bin           = @["nimakai"]

# Dependencies
requires "nim >= 2.0.0"
requires "malebolgia >= 0.1.0"

# Build config
task build, "Build nimakai":
  exec "nim c -d:ssl -d:release --opt:size -o:nimakai src/nimakai.nim"

#!/bin/bash
# scripts/vendor-whisper-cpp.sh — refresh the vendored whisper.cpp/ggml
# CPU-only sources. Re-run this and commit the result to update the pin;
# never hand-edit files under swift/Sources/whisper_cpp/.
set -euo pipefail

PIN_COMMIT="080bbbe85230f624f0b52127f1ae1218247989f9"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/swift/Sources/whisper_cpp"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

git clone --quiet https://github.com/ggml-org/whisper.cpp.git "$WORK_DIR/src"
git -C "$WORK_DIR/src" checkout --quiet "$PIN_COMMIT"

rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/ggml-cpu"

# whisper.cpp core (no Parakeet, no CoreML/OpenVINO glue)
cp "$WORK_DIR/src/src/whisper.cpp"       "$DEST/whisper.cpp"
cp "$WORK_DIR/src/src/whisper-arch.h"    "$DEST/whisper-arch.h"
cp "$WORK_DIR/src/include/whisper.h"     "$DEST/include/whisper.h"

# ggml core (backend-agnostic)
for f in ggml.c ggml.cpp ggml-alloc.c ggml-backend.cpp ggml-backend-reg.cpp \
         ggml-backend-impl.h ggml-common.h ggml-impl.h ggml-opt.cpp \
         ggml-quants.c ggml-quants.h ggml-threading.cpp ggml-threading.h \
         gguf.cpp; do
    cp "$WORK_DIR/src/ggml/src/$f" "$DEST/$f"
done
cp "$WORK_DIR/src/ggml/include/"*.h "$DEST/include/"

# ggml CPU backend only — no metal/cuda/vulkan/etc.
cp -R "$WORK_DIR/src/ggml/src/ggml-cpu/." "$DEST/ggml-cpu/"

# Strip anything that would drag in non-CPU backends or build tooling.
rm -rf "$DEST/ggml-cpu/kleidiai" "$DEST/ggml-cpu/cmake" "$DEST/ggml-cpu/CMakeLists.txt"

echo "Vendored whisper.cpp/ggml @ $PIN_COMMIT into $DEST"

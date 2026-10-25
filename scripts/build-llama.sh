#!/bin/bash
# Separate static process: whisper and llama never link their GGML symbols together.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=b11869
COMMIT=d327bf1f0780f87b8c01b367b61853b0c291d7c4
# SHA256 of GitHub's immutable commit archive, fetched and checked 2026-10-25.
SHA256=f808461a7a07acf0b60c0fa08c5bc65bb7641a377d63b758569c941c12ad8a0c
CACHE="$PWD/vendor/cache"
ARCHIVE="$CACHE/llama.cpp-$VERSION.tar.gz"
SOURCE="$CACHE/llama.cpp-$COMMIT"
BUILD="$PWD/vendor/build-llama"
OUTPUT="$PWD/vendor/llama"
[[ $(uname -s) == Darwin ]] || { printf 'Build llama on macOS with Xcode command line tools.\n' >&2; exit 1; }
command -v cmake >/dev/null || { printf 'CMake is required.\n' >&2; exit 1; }
mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" ]]; then
    trap 'rm -f "$ARCHIVE.download"' EXIT
    curl --fail --location --retry 3 "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$COMMIT" -o "$ARCHIVE.download"
    mv "$ARCHIVE.download" "$ARCHIVE"
    trap - EXIT
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 --check
rm -rf "$SOURCE" "$BUILD" "$OUTPUT"
tar -xzf "$ARCHIVE" -C "$CACHE"
export GIT_CEILING_DIRECTORIES="$CACHE"
cmake -S scripts/llama -B "$BUILD" -G 'Unix Makefiles' \
    -DLLAMA_SOURCE="$SOURCE" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_BACKEND_DL=OFF \
    -DLLAMA_BUILD_IS_DEV=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple \
    -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod \
    -DLLAMA_BUILD_NUMBER=11869 -DLLAMA_BUILD_COMMIT="$COMMIT"
cmake --build "$BUILD" --config Release --target nosy-llama --parallel "$(sysctl -n hw.ncpu)"
mkdir -p "$OUTPUT"
install -m 755 "$BUILD/nosy-llama" "$OUTPUT/nosy-llama"
strip -x "$OUTPUT/nosy-llama"
cp "$SOURCE/LICENSE" "$OUTPUT/LICENSE"
printf 'llama.cpp %s (%s)\nsource sha256: %s\narm64; macOS 14.0; static GGML; embedded Metal shaders\n' "$VERSION" "$COMMIT" "$SHA256" > "$OUTPUT/BUILD-INFO.txt"
otool -L "$OUTPUT/nosy-llama"
otool -L "$OUTPUT/nosy-llama" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 } END { exit bad }'
[[ $(lipo -archs "$OUTPUT/nosy-llama") == arm64 ]]
printf 'LLAMA BUILD PASS: %s (%s bytes)\n' "$OUTPUT/nosy-llama" "$(stat -f %z "$OUTPUT/nosy-llama")"

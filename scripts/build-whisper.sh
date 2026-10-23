#!/bin/bash
# Rebuild the only engine executable shipped in Nosy (Apple Silicon, macOS 14+).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.9.5
# Matches the v1.9.5 source archive checksum published by Homebrew.
SHA256=ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720
VENDOR="$PWD/vendor"
CACHE="$VENDOR/cache"
ARCHIVE="$CACHE/whisper.cpp-v$VERSION.tar.gz"
SOURCE="$CACHE/whisper.cpp-$VERSION"
BUILD="$VENDOR/build-whisper"
OUTPUT="$VENDOR/whisper"

[[ $(uname -s) == Darwin ]] || { printf 'Build whisper on macOS with Xcode command line tools.\n' >&2; exit 1; }
command -v cmake >/dev/null || { printf 'CMake is required: brew install cmake\n' >&2; exit 1; }
mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" ]]; then
    trap 'rm -f "$ARCHIVE.download"' EXIT
    curl --fail --location --retry 3 \
        "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v$VERSION" \
        -o "$ARCHIVE.download"
    mv "$ARCHIVE.download" "$ARCHIVE"
    trap - EXIT
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 --check
# Always extract/build from the verified archive; don't trust an old source/cache.
rm -rf "$SOURCE" "$BUILD" "$OUTPUT"
tar -xzf "$ARCHIVE" -C "$CACHE"

# Prevent upstream build metadata from accidentally using Nosy's parent git repo.
export GIT_CEILING_DIRECTORIES="$CACHE"
# Pin Apple tools, not any Homebrew compiler or OpenMP runtime. M1 is the baseline;
# GGML_NATIVE must stay off so building on a newer Mac doesn't require its ISA.
cmake -S "$SOURCE" -B "$BUILD" -G 'Unix Makefiles' \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
    -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_BACKEND_DL=OFF \
    -DWHISPER_USE_SYSTEM_GGML=OFF -DWHISPER_USE_SYSTEM_LLAMA=OFF \
    -DWHISPER_BUILD_IS_DEV=OFF -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF -DWHISPER_COREML=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple \
    -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod
# Don't build/install the other example executables or libraries.
cmake --build "$BUILD" --config Release --target whisper-cli --parallel "$(sysctl -n hw.ncpu)"
mkdir -p "$OUTPUT"
install -m 755 "$BUILD/bin/whisper-cli" "$OUTPUT/whisper-cli"
strip -x "$OUTPUT/whisper-cli"
cp "$SOURCE/LICENSE" "$OUTPUT/LICENSE"
printf 'whisper.cpp v%s\nsource sha256: %s\narm64; macOS 14.0; static GGML; embedded Metal shaders\n' \
    "$VERSION" "$SHA256" > "$OUTPUT/BUILD-INFO.txt"

# Fail the build if a non-system library slipped in (including @rpath libraries).
otool -L "$OUTPUT/whisper-cli"
otool -L "$OUTPUT/whisper-cli" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 } END { exit bad }'
[[ $(lipo -archs "$OUTPUT/whisper-cli") == arm64 ]]
printf 'WHISPER BUILD PASS: %s (%s bytes)\n' "$OUTPUT/whisper-cli" "$(stat -f %z "$OUTPUT/whisper-cli")"

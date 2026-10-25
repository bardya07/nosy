# Source from the repository root after scripts/paths.sh.
mkdir -p "$BUILD_DIR"
clang -O2 -fobjc-arc -fmodules -target arm64-apple-macos14.0 -c Native/AudioExceptions.m -o "$BUILD_DIR/AudioExceptions.o"
AUDIO_SHIM=(-I Native "$BUILD_DIR/AudioExceptions.o")

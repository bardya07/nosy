# Nosy developer notes

Nosy is a native SwiftUI macOS app for Apple Silicon, built with `build.sh` rather than an Xcode project. See the [README](README.md) for current requirements, features, and build instructions. The source is authoritative for implementation details.

The app bundles whisper.cpp for transcription, a separate llama.cpp-based helper for optional local AI, a read-only MCP connector, and Sparkle for updates. Third-party licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

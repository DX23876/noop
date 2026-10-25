#!/usr/bin/env bash
# Builds the shared Swift core for Android (Android plan D-5): libNoopCore.so from Packages/NoopCoreJNI with
# every shared library it needs at runtime, into the jniLibs directory given as the only argument
# (<out>/arm64-v8a/*.so). Gradle's buildSwiftCore task runs it.
#
# Needs a swift.org toolchain matching the Swift SDK for Android (6.4.1), that SDK installed with
# `swift sdk install`, and NDK r30 (ANDROID_NDK_HOME, or $ANDROID_HOME/ndk/30.0.16248370). NOOP_SWIFT points at
# the swift binary; by default the toolchain under ~/Library/Developer/Toolchains on macOS, `swift` on Linux.
set -euo pipefail

OUT="${1:?usage: build-swift-core.sh <jniLibs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$ROOT/android/app/build/swift-core"
SDK_ID="swift-6.4.1-RELEASE_android"
TRIPLE="aarch64-unknown-linux-android28"
SQLITE_ZIP_URL="https://sqlite.org/2026/sqlite-amalgamation-3530400.zip"
SQLITE_C_SHA256="b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189"

case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64"
          SWIFT="${NOOP_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain/usr/bin/swift}" ;;
  *)      HOST_TAG="linux-x86_64"; SWIFT="${NOOP_SWIFT:-swift}" ;;
esac
NDK="${ANDROID_NDK_HOME:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/ndk/30.0.16248370}"
export ANDROID_NDK_HOME="$NDK"
LLVM="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
[ -x "$LLVM/clang" ] || { echo "build-swift-core: NDK r30 not found at $NDK" >&2; exit 1; }
"$SWIFT" sdk list 2>/dev/null | grep -qx "$SDK_ID" || { echo "build-swift-core: Swift SDK $SDK_ID is not installed for $SWIFT" >&2; exit 1; }

# SQLite with the snapshot API GRDB uses, pinned by checksum (the same file as docs/BUILD.md).
SQLITE="$BUILD/sqlite"
mkdir -p "$SQLITE"
if [ ! -f "$SQLITE/libsqlite3.so" ]; then
  curl -fsSLo "$SQLITE/sqlite.zip" "$SQLITE_ZIP_URL"
  unzip -p "$SQLITE/sqlite.zip" sqlite-amalgamation-3530400/sqlite3.c > "$SQLITE/sqlite3.c"
  unzip -p "$SQLITE/sqlite.zip" sqlite-amalgamation-3530400/sqlite3.h > "$SQLITE/sqlite3.h"
  echo "$SQLITE_C_SHA256  $SQLITE/sqlite3.c" | shasum -a 256 -c - >/dev/null
  "$LLVM/aarch64-linux-android28-clang" -shared -fPIC -O2 -DSQLITE_ENABLE_SNAPSHOT=1 \
    -Wl,-z,max-page-size=16384 -o "$SQLITE/libsqlite3.so" "$SQLITE/sqlite3.c"
fi

PKG="$ROOT/Packages/NoopCoreJNI"
SCRATCH="$BUILD/swiftpm"
"$SWIFT" package resolve --package-path "$PKG" --scratch-path "$SCRATCH" >/dev/null
python3 "$HERE/patch_dependencies.py" "$SCRATCH"
EXTRA=()
# On a macOS host the ZIPFoundation manifest picks Apple's Compression, so zlib's module map is passed by hand.
if [ "$(uname -s)" = Darwin ]; then
  Z="$SCRATCH/checkouts/ZIPFoundation/Sources/CZLib"
  EXTRA=(-Xcc "-fmodule-map-file=$Z/module.modulemap" -Xcc "-I$Z")
fi
FLAGS=(--package-path "$PKG" --scratch-path "$SCRATCH" -c release --swift-sdk "$SDK_ID" --triple "$TRIPLE"
       -Xcc "-I$SQLITE" -Xlinker "-L$SQLITE" -Xlinker -z -Xlinker max-page-size=16384 "${EXTRA[@]}")
"$SWIFT" build "${FLAGS[@]}" --product NoopCore
BIN="$("$SWIFT" build "${FLAGS[@]}" --show-bin-path)"

# Copy libNoopCore.so and, transitively, every shared library it needs that Android does not provide.
RUNTIME=""
for bundle in "$HOME/Library/org.swift.swiftpm/swift-sdks" "$HOME/.swiftpm/swift-sdks" "$HOME/.config/swiftpm/swift-sdks"; do
  candidate="$bundle/$SDK_ID.artifactbundle/swift-android/swift-resources/usr/lib/swift-aarch64/android"
  [ -f "$candidate/libswiftCore.so" ] && { RUNTIME="$candidate"; break; }
done
[ -n "$RUNTIME" ] || { echo "build-swift-core: the Swift runtime for Android was not found in the SDK bundle" >&2; exit 1; }
CXX="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/sysroot/usr/lib/aarch64-linux-android"
DEST="$OUT/arm64-v8a"
rm -rf "$DEST"; mkdir -p "$DEST"
SYSTEM=" libc.so libm.so libdl.so liblog.so libz.so libandroid.so "
queue=("libNoopCore.so"); done_list=" "
while [ ${#queue[@]} -gt 0 ]; do
  lib="${queue[0]}"; queue=("${queue[@]:1}")
  case "$done_list" in *" $lib "*) continue ;; esac
  done_list="$done_list$lib "
  case "$SYSTEM" in *" $lib "*) continue ;; esac
  src=""
  for dir in "$BIN" "$RUNTIME" "$CXX" "$SQLITE"; do [ -f "$dir/$lib" ] && { src="$dir/$lib"; break; }; done
  [ -n "$src" ] || { echo "build-swift-core: $lib is needed but was not found" >&2; exit 1; }
  cp "$src" "$DEST/"
  # Debug sections would make the APK several times larger; crashes are read from the Swift error, not symbols.
  "$LLVM/llvm-strip" --strip-unneeded "$DEST/$lib"
  while read -r needed; do queue+=("$needed"); done < <("$LLVM/llvm-readelf" -d "$src" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
done
echo "build-swift-core: $(ls "$DEST" | wc -l | tr -d ' ') libraries, $(du -sh "$DEST" | cut -f1), in $DEST"

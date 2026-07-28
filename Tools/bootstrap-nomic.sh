#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VENDOR_DIR="$REPO_DIR/Vendor/Nomic"
RESOURCE_DIR="$VENDOR_DIR/Resources"

LLAMA_TAG="b9623"
LLAMA_ARCHIVE="llama-${LLAMA_TAG}-xcframework.zip"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/${LLAMA_ARCHIVE}"
LLAMA_SHA256="8857832e4699bc8483f038d0c8ac6927de11ce8c6772f79b2a99db8a48ab2d83"
LLAMA_FRAMEWORK="$VENDOR_DIR/llama.xcframework"

NOMIC_REVISION="ffbcf4c99e5d617dda10ec8c0e9f75754b0cbb80"
NOMIC_FILE="nomic-embed-text-v2-moe.Q4_K_M.gguf"
NOMIC_URL="https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe-GGUF/resolve/${NOMIC_REVISION}/${NOMIC_FILE}"
NOMIC_SHA256="b5fb2811647b8ef461519a68a3bf67014a84a66a130c8a2af9413ff9f06d3f22"
NOMIC_MODEL="$RESOURCE_DIR/$NOMIC_FILE"

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

verify_file() {
    path=$1
    expected=$2
    label=$3
    if [ ! -f "$path" ]; then
        echo "$label is missing: $path" >&2
        return 1
    fi
    actual=$(sha256_of "$path")
    if [ "$actual" != "$expected" ]; then
        echo "$label checksum mismatch: expected $expected, got $actual" >&2
        return 1
    fi
}

verify_framework() {
    if [ ! -d "$LLAMA_FRAMEWORK" ] \
        || [ ! -f "$LLAMA_FRAMEWORK/Info.plist" ] \
        || [ ! -d "$LLAMA_FRAMEWORK/ios-arm64/llama.framework" ] \
        || [ ! -d "$LLAMA_FRAMEWORK/ios-arm64_x86_64-simulator/llama.framework" ]; then
        echo "llama.xcframework is missing or incomplete: $LLAMA_FRAMEWORK" >&2
        return 1
    fi
}

mkdir -p "$VENDOR_DIR" "$RESOURCE_DIR"

if [ "${1:-}" = "--check" ]; then
    verify_framework
    verify_file "$NOMIC_MODEL" "$NOMIC_SHA256" "Nomic model"
    echo "Nomic build inputs are present and verified."
    exit 0
fi

if ! verify_framework 2>/dev/null; then
    archive_path="$VENDOR_DIR/$LLAMA_ARCHIVE"
    if [ ! -f "$archive_path" ] || [ "$(sha256_of "$archive_path")" != "$LLAMA_SHA256" ]; then
        temp_archive="$archive_path.download"
        rm -f "$temp_archive"
        curl -L --fail --show-error --progress-bar "$LLAMA_URL" -o "$temp_archive"
        verify_file "$temp_archive" "$LLAMA_SHA256" "llama.cpp XCFramework archive"
        mv "$temp_archive" "$archive_path"
    fi
    extract_dir=$(mktemp -d "${TMPDIR:-/tmp}/noop-llama.XXXXXX")
    trap 'rm -rf "$extract_dir"' EXIT HUP INT TERM
    unzip -q "$archive_path" -d "$extract_dir"
    extracted=$(find "$extract_dir" -type d -name llama.xcframework -print -quit)
    if [ -z "$extracted" ]; then
        echo "The pinned llama.cpp archive did not contain llama.xcframework." >&2
        exit 1
    fi
    # The official archive also carries macOS, tvOS and visionOS slices. NOOP ships this runtime only
    # in NOOPiOS, so rebuild an iOS-only XCFramework from the two exact pinned slices. This keeps the
    # local checkout roughly 450 MB smaller without changing the device or simulator binary.
    rm -rf "$LLAMA_FRAMEWORK"
    xcodebuild -create-xcframework \
        -framework "$extracted/ios-arm64/llama.framework" \
        -framework "$extracted/ios-arm64_x86_64-simulator/llama.framework" \
        -output "$LLAMA_FRAMEWORK"
    rm -f "$archive_path"
    rm -rf "$extract_dir"
    trap - EXIT HUP INT TERM
fi

if ! verify_file "$NOMIC_MODEL" "$NOMIC_SHA256" "Nomic model" 2>/dev/null; then
    temp_model="$NOMIC_MODEL.download"
    rm -f "$temp_model"
    curl -L --fail --show-error --progress-bar "$NOMIC_URL" -o "$temp_model"
    verify_file "$temp_model" "$NOMIC_SHA256" "Nomic model"
    mv "$temp_model" "$NOMIC_MODEL"
fi

verify_framework
verify_file "$NOMIC_MODEL" "$NOMIC_SHA256" "Nomic model"
echo "Nomic build inputs are installed and verified."

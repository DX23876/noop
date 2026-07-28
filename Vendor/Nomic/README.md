# Local Nomic runtime

`Tools/bootstrap-nomic.sh` installs two pinned, checksum-verified build inputs here:

- `llama.xcframework` from llama.cpp release `b9623`;
- `Resources/nomic-embed-text-v2-moe.Q4_K_M.gguf` from the official Nomic repository.

The binaries are intentionally ignored by Git. Run the bootstrap script **before**
`xcodegen generate`; XcodeGen then copies the GGUF into `NOOPiOS.app` and links the iOS
XCFramework. The bootstrap rebuilds the official archive as an iOS-only XCFramework (device
and simulator slices); unrelated macOS/tvOS/visionOS binaries are discarded to save local disk
space. The app never downloads a model at runtime.

Use `Tools/bootstrap-nomic.sh --check` to verify an existing installation without network access.

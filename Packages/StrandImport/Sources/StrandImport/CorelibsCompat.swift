import Foundation

// Small corelibs shims so the package builds on Linux as well as Darwin. Each one exists because a
// Foundation facility this package uses is Objective-C-runtime-backed on Apple platforms and simply
// absent elsewhere — never because behaviour should differ.

#if !canImport(ObjectiveC)
/// No-op stand-in for Apple's `autoreleasepool`.
///
/// Without an Objective-C runtime there are no autoreleased temporaries to drain, so running the body
/// directly is the exact equivalent rather than an approximation. The Darwin call sites keep their real
/// pool, which is load-bearing there: the Apple Health importer drains per XML element because a
/// multi-year `export.xml` bridges tens of millions of attribute dictionaries.
///
/// Mirrors the shim GRDB already ships for the same reason, so the two agree on the spelling.
@inlinable func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

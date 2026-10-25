#!/usr/bin/env python3
"""Android conditionals for GRDB 6.29.3 and ZIPFoundation 0.9.20 (Android plan D22), applied to a resolved
SwiftPM checkout: patch_dependencies.py <scratch-path>. Idempotent: each file is restored from git first.

GRDB 7.10 and later ship the GRDB part upstream (groue/GRDB.swift PR 1850); moving to it is its own step.
"""
import os
import pathlib
import re
import stat
import subprocess
import sys

scratch = pathlib.Path(sys.argv[1])


def write(p: pathlib.Path, text: str) -> None:
    """SwiftPM leaves checkouts read-only; make the one file writable before patching it."""
    if text != p.read_text():
        os.chmod(p, os.stat(p).st_mode | stat.S_IWUSR)
        p.write_text(text)


def restore(repo: pathlib.Path, *paths: str) -> None:
    subprocess.run(["git", "checkout", "-q", "--", *paths], cwd=repo, check=True)


def patch_grdb(repo: pathlib.Path) -> None:
    restore(repo, "GRDB")
    p = repo / "GRDB/Core/StatementAuthorizer.swift"
    s = p.read_text()
    s = re.sub(r"^#elseif os\(Linux\)$", "#elseif os(Linux)\nimport Glibc\n#elseif os(Android)\nimport Android\n#elseif false",
               s, count=1, flags=re.M)
    write(p, s)
    for p in (repo / "GRDB/Core/Support/Foundation").glob("*.swift"):
        write(p, re.sub(r"^#if !os\(Linux\)$", "#if !os(Linux) && !os(Android)", p.read_text(), flags=re.M))


def patch_zip(repo: pathlib.Path) -> None:
    restore(repo, "Sources")
    for p in (repo / "Sources/ZIPFoundation").glob("*.swift"):
        s = p.read_text()
        s = re.sub(r"^import Foundation$", "import Foundation\n#if canImport(Android)\nimport Android\n#endif", s, flags=re.M)
        s = re.sub(r"#if os\(Linux\)$", "#if os(Linux) || os(Android)", s, flags=re.M)
        s = s.replace("fwrite(buffer.baseAddress,", "fwrite(buffer.baseAddress!,")
        write(p, s)
    # Bionic declares funopen's callbacks with non-optional pointers; closures adapt the optional-taking stubs.
    p = repo / "Sources/ZIPFoundation/Archive+MemoryFile.swift"
    s = p.read_text()
    s = s.replace("funopen(cookie.toOpaque(), readStub, writeStub, seekStub, closeStub)",
                  "funopen(cookie.toOpaque(), { readStub($0, $1, $2) }, { writeStub($0, $1, $2) }, "
                  "{ seekStub($0, $1, $2) }, { closeStub($0) })")
    s = s.replace("funopen(cookie.toOpaque(), readStub, nil, seekStub, closeStub)",
                  "funopen(cookie.toOpaque(), { readStub($0, $1, $2) }, nil, { seekStub($0, $1, $2) }, { closeStub($0) })")
    write(p, s)
    # lchmod exists from Android 36 on; symlink permissions never occur in the archives NOOP reads or writes.
    p = repo / "Sources/ZIPFoundation/FileManager+ZIP.swift"
    s = p.read_text()
    old = ("        guard lchmod(fileSystemRepresentation, mode_t(modeT)) == 0 else {\n"
           "            throw POSIXError(errno, path: url.path)\n        }\n")
    assert old in s, "ZIPFoundation's lchmod call moved; update this patch"
    write(p, s.replace(old, "#if os(Android)\n        _ = (fileSystemRepresentation, modeT)\n#else\n" + old + "#endif\n"))


patch_grdb(scratch / "checkouts/GRDB.swift")
patch_zip(scratch / "checkouts/ZIPFoundation")
print("patched GRDB and ZIPFoundation for Android")

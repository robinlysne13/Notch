#!/bin/bash
# Exercises the verification-code extraction against realistic message samples.
#
# Not a SwiftPM test target: the package is a single executable target, and testing one would mean
# splitting the app into a library plus a shim. These heuristics are the part worth pinning down,
# and compiling the handful of files they touch is enough to do that.
set -e
cd "$(dirname "$0")/.."

SRC="Sources/NotchApp"
OUT="$(mktemp -d)/codefinder-tests"

swiftc -o "$OUT" \
    Tests/CodeFinderTests/main.swift \
    "$SRC/VerificationCodeFinder.swift" \
    "$SRC/MIME.swift" \
    "$SRC/IMAPMailReader.swift" \
    "$SRC/MailAccount.swift" \
    "$SRC/Keychain.swift"

"$OUT"

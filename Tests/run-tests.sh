#!/bin/bash
# Exercises the pure logic that is worth pinning down: verification-code extraction against
# realistic message samples, the LRC lyric parsing behind the lyrics panel, and the playhead that
# panel follows.
#
# Not a SwiftPM test target: the package is a single executable target, and testing one would mean
# splitting the app into a library plus a shim. Compiling the handful of files each suite touches
# is enough to do that.
set -e
cd "$(dirname "$0")/.."

SRC="Sources/NotchApp"
BUILD="$(mktemp -d)"
status=0

run_suite() {
    local name="$1"
    shift
    echo "== $name"
    swiftc -o "$BUILD/$name" "$@"
    "$BUILD/$name" || status=1
    echo
}

run_suite codefinder \
    Tests/CodeFinderTests/main.swift \
    "$SRC/VerificationCodeFinder.swift" \
    "$SRC/MIME.swift" \
    "$SRC/IMAPMailReader.swift" \
    "$SRC/MailAccount.swift" \
    "$SRC/Keychain.swift"

run_suite lyrics \
    Tests/LyricsTests/main.swift \
    "$SRC/LyricsProvider.swift" \
    "$SRC/LyricsLayout.swift"

run_suite playhead \
    Tests/PlayheadTests/main.swift \
    "$SRC/Playhead.swift"

run_suite hover \
    Tests/HoverTests/main.swift \
    "$SRC/NotchHover.swift"

run_suite spotify \
    Tests/SpotifyTests/main.swift \
    "$SRC/SpotifyAuth.swift" \
    "$SRC/Keychain.swift"

exit $status

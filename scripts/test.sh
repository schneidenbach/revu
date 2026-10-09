#!/bin/sh
# Runs `swift test`. With only the Command Line Tools selected (no Xcode), SwiftPM does not find
# the Swift Testing framework on its own, and silently runs zero tests; pass its location explicitly.
set -e
cd "$(dirname "$0")/.."

CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F"$CLT_FRAMEWORKS" \
        -Xlinker -F"$CLT_FRAMEWORKS" -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" "$@"
fi
exec swift test "$@"

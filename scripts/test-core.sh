#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Run only hardware-independent state tests with Apple's Command Line Tools.
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
frameworks="$DEVELOPER_DIR/Library/Developer/Frameworks"
testing_libs="$DEVELOPER_DIR/Library/Developer/usr/lib"
swift test -Xswiftc -F -Xswiftc "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$testing_libs"

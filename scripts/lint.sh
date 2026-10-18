#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export XCODE_DEFAULT_TOOLCHAIN_OVERRIDE="${XCODE_DEFAULT_TOOLCHAIN_OVERRIDE:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain}"
swiftlint lint --strict --no-cache

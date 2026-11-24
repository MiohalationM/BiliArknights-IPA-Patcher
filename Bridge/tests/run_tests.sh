#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -t bridge_core_test)"
trap 'rm -f "$OUT"' EXIT

clang -fobjc-arc -Wall -Wextra -Werror \
  "$ROOT/Sources/ABPolicy.c" \
  "$ROOT/Sources/ABLoginResult.m" \
  "$ROOT/tests/test_bridge_core.m" \
  -framework Foundation -framework CoreFoundation \
  -o "$OUT"

"$OUT"

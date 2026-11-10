#!/usr/bin/env bash
# Stage the extracted mod folder MOMI installs and build a convenience ZIP.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mkdir -p "${1:-$REPO/dist}" && cd "${1:-$REPO/dist}" && pwd)"
rm -rf "$OUT/mt"
cp -R "$REPO/mod/mt" "$OUT/mt"
rm -f "$OUT/MistriaTogether-mod.zip"
PY="$(command -v python3 || command -v python)"
( cd "$REPO/mod" && "$PY" -m zipfile -c "$OUT/MistriaTogether-mod.zip" mt )
echo "$OUT/MistriaTogether-mod.zip"

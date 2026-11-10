#!/usr/bin/env bash
# Build the mod archive MOMI installs: a zip whose top-level folder is `mt`
# (the folder name is the mod's function prefix, see mod/mt/gml/MtBoot.gml).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mkdir -p "${1:-$REPO/dist}" && cd "${1:-$REPO/dist}" && pwd)"
rm -f "$OUT/MistriaTogether-mod.zip"
( cd "$REPO/mod" && python3 -m zipfile -c "$OUT/MistriaTogether-mod.zip" mt )
echo "$OUT/MistriaTogether-mod.zip"

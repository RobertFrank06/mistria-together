#!/usr/bin/env bash
# Compile every mod script as one unit with MOMI's own GML checker: catches
# syntax errors and duplicate top-level functions that the in-game compiler
# would otherwise reject at boot.
#
#   tools/check-gml.sh
#
# The checker (momi-gml-check) ships inside MOMI. It is found via
# $MOMI_GML_CHECK, or in MOMI's extraction folders under ~/.net. In CI, set
# MOMI_GML_CHECK to a checker built from the MOMI repository
# (tools/checker, tag named by `minInstallerVersion` in the manifest).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="${MOMI_GML_CHECK:-}"
if [ -z "$CHECK" ]; then
    CHECK="$(find "$HOME/.net" -maxdepth 4 -name momi-gml-check -type f 2>/dev/null | head -n1 || true)"
fi
if [ -z "$CHECK" ] || [ ! -x "$CHECK" ]; then
    echo "momi-gml-check not found. Set MOMI_GML_CHECK, or run MOMI once so it extracts its tools." >&2
    exit 2
fi
"$CHECK" unit "$REPO"/mod/mt/gml/*.gml
echo "check-gml: all mod scripts compile as one unit"

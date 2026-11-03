#!/usr/bin/env bash
# Lint every shell script: `bash -n` for syntax, then shellcheck (settings in .shellcheckrc).
set -euo pipefail

cd "$(dirname "$0")/.."

command -v shellcheck >/dev/null || {
  echo "lint: shellcheck not found (pip install shellcheck-py==0.11.0.1, or use your package manager)" >&2
  exit 127
}

files=(bin/* tests/*.sh)
for f in "${files[@]}"; do
  bash -n "$f" || { echo "lint: bash -n failed: $f" >&2; exit 1; }
done
shellcheck "${files[@]}"
echo "lint: ${#files[@]} files clean"

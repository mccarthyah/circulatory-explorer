#!/bin/sh
# Usage: GODOT=/path/to/godot ./tests/run.sh
set -eu
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export XDG_DATA_HOME="$tmp/data" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
"$GODOT" --headless --path . --editor --import
"$GODOT" --headless --path . --check-only --script res://tests/benchmark.gd
for quality in performance balanced high; do
    "$GODOT" --headless --path . --script res://tests/run.gd -- "$quality"
done

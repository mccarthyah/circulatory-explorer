#!/bin/sh
# Usage: GODOT=/path/to/godot ./tests/benchmark.sh [quality] [Godot options...]
set -eu
cd "$(dirname "$0")/.."
quality=${1:-performance}
if [ "$#" -gt 0 ]; then shift; fi
GODOT=${GODOT:-godot}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export XDG_DATA_HOME="$tmp/data" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache"
export EXPLORER_SETTINGS_PATH="$tmp/settings.cfg"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
"$GODOT" --path . "$@" --script res://tests/benchmark.gd -- "$quality"

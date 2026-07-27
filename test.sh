#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$ROOT/scripts/dependencies.sh" check
odin test "$ROOT" -collection:match_sorter="$ROOT/../hw_odin_matchSorter"

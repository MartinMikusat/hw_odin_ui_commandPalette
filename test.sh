#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$ROOT/scripts/dependencies.sh" check
hw-odin test "$ROOT" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -collection:match_sorter="$ROOT/../hw_odin_matchSorter"

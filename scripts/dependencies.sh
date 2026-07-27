#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOCK_FILE="$ROOT/dependencies.lock"
REPOSITORY="$ROOT/../hw_odin_matchSorter"

check_dependency() {
  if [ ! -f "$LOCK_FILE" ]; then
    echo "[command-palette] missing dependency lock: $LOCK_FILE" >&2
    return 1
  fi

  seen=0
  while read -r name expected_url expected_revision extra; do
    case "$name" in
      ""|\#*) continue ;;
    esac
    if [ "$name" != "hw_odin_matchSorter" ] ||
       [ -n "${extra:-}" ] ||
       [ -z "${expected_url:-}" ] ||
       [ -z "${expected_revision:-}" ] ||
       [ "$seen" -ne 0 ]; then
      echo "[command-palette] invalid dependency lock entry: $name" >&2
      return 1
    fi
    seen=1

    if ! git -C "$REPOSITORY" rev-parse --git-dir >/dev/null 2>&1; then
      echo "[command-palette] missing sibling repository: $REPOSITORY" >&2
      return 1
    fi
    actual_url=$(git -C "$REPOSITORY" remote get-url origin 2>/dev/null || true)
    actual_revision=$(git -C "$REPOSITORY" rev-parse HEAD)
    if [ "$actual_url" != "$expected_url" ]; then
      echo "[command-palette] dependency origin mismatch" >&2
      return 1
    fi
    if [ "$actual_revision" != "$expected_revision" ]; then
      echo "[command-palette] dependency revision mismatch" >&2
      return 1
    fi
    if [ -n "$(git -C "$REPOSITORY" status --porcelain)" ]; then
      echo "[command-palette] dependency has uncommitted changes" >&2
      return 1
    fi
  done < "$LOCK_FILE"

  if [ "$seen" -ne 1 ]; then
    echo "[command-palette] dependency lock is incomplete" >&2
    return 1
  fi
}

update_dependency() {
  if ! git -C "$REPOSITORY" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[command-palette] missing sibling repository: $REPOSITORY" >&2
    return 1
  fi
  temporary=$(mktemp "${TMPDIR:-/tmp}/command-palette-dependencies.XXXXXX")
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
  url=$(git -C "$REPOSITORY" remote get-url origin)
  revision=$(git -C "$REPOSITORY" rev-parse HEAD)
  printf '# Sibling repository, origin URL, and tested commit.\n' > "$temporary"
  printf 'hw_odin_matchSorter %s %s\n' "$url" "$revision" >> "$temporary"
  mv "$temporary" "$LOCK_FILE"
  trap - EXIT HUP INT TERM
  echo "[command-palette] updated dependencies.lock"
}

case "${1:-check}" in
  check) check_dependency ;;
  update) update_dependency ;;
  *)
    echo "usage: ./scripts/dependencies.sh [check|update]" >&2
    exit 2
    ;;
esac

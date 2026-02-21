#!/usr/bin/env bash
set -euo pipefail

script="${1:-}"
a="${2:-}"
b="${3:-}"
rest="${4:-}"
json="${5:-}"

echo "script=$script"
echo "a=$a"
echo "b=$b"
echo "rest=$rest"
echo "json=$json"

# here you decide what is allowed/ not allowed:
case "$script" in
  echo)
    echo "OK: echo-mode"
    ;;
  *)
    echo "Unknown script: $script" >&2
    exit 2
    ;;
esac
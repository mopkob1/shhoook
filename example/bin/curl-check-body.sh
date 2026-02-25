#!/bin/sh
set -eu

url="${1:?url required}"
header="${2:?header required}"

tmp="$(mktemp)"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT INT TERM

set +e
code="$(curl -sS -H "$header" -o "$tmp" -w '%{http_code}' "$url")"
rc="$?"
set -e

cat "$tmp"

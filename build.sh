#!/usr/bin/env sh
set -e

SRC_DIR="${SRC_DIR:-/src}"
OUT_DIR="${OUT_DIR:-/out}"
OUTPUT="${OUTPUT:-shhoook}"
MAIN="${MAIN:-.}"

GOOS="${GOOS:-linux}"
GOARCH="${GOARCH:-amd64}"
GOARM="${GOARM:-}"
CGO_ENABLED="${CGO_ENABLED:-0}"

HOST_UID="${HOST_UID:-}"
HOST_GID="${HOST_GID:-}"

mkdir -p "$OUT_DIR"
rm -rf /work/src && mkdir -p /work/src
cp -a "${SRC_DIR}/." /work/src || true
cd /work/src

if [ ! -f go.mod ]; then
  printf "module buildtmp\n\ngo 1.22\n" > go.mod
fi

go mod tidy || true

echo "==> Building $OUTPUT ($GOOS/$GOARCH${GOARM:+/v$GOARM}) from $MAIN"

# We form the env carefully so that the GOARM is not passed empty.
ENV_VARS="GOOS=$GOOS GOARCH=$GOARCH CGO_ENABLED=$CGO_ENABLED"
[ -n "$GOARM" ] && ENV_VARS="$ENV_VARS GOARM=$GOARM"

# shellcheck disable=SC2086
env $ENV_VARS \
  go build -trimpath \
    -ldflags="-s -w -extldflags '-static'" \
    -o "${OUT_DIR}/${OUTPUT}" "${MAIN}"

chmod +x "${OUT_DIR}/${OUTPUT}"

if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
  chown "$HOST_UID:$HOST_GID" "${OUT_DIR}/${OUTPUT}" || true
fi

echo "==> Done: ${OUT_DIR}/${OUTPUT}"

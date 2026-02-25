#!/usr/bin/env bash
set -euo pipefail

# install-ubuntu.sh
# Installs shhoook on Ubuntu via docker compose build, sets up systemd autostart
# for a specific interface (default: tailscale0), and writes default endpoints
# into /etc/shhoook/conf by default.

REPO_URL="https://github.com/mopkob1/shhoook.git"

TOKEN=""
IFACE="tailscale0"
BASE="/etc/shhoook"          # default base path (as requested)
PORT="8080"                  # default port

usage() {
  cat <<'USAGE'
Usage:
  sudo ./install-ubuntu.sh --token <TOKEN> [--iface <IFACE>] [--path </etc/shhoook>] [--port <PORT>]

Defaults:
  --iface tailscale0
  --path  /etc/shhoook
  --port  8080

Requirements (no fallbacks):
  - git
  - docker
  - docker compose (plugin)
  - systemd
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2;;
    --iface) IFACE="${2:-}"; shift 2;;
    --path)  BASE="${2:-}"; shift 2;;
    --port)  PORT="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [ -z "$TOKEN" ]; then
  echo "ERROR: --token is required" >&2
  usage
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (use sudo)" >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || { echo "ERROR: git not found" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose not available (docker compose plugin required)" >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "ERROR: systemctl not found (systemd required)" >&2; exit 1; }

BASE="${BASE%/}"
CONF_DIR="${BASE}"

# Default prefix for tailscale interface (helps choose the right IP if multiple)
WAIT_V4_PREFIX=""
if [ "$IFACE" = "tailscale0" ]; then
  WAIT_V4_PREFIX="100.64."
fi

# Detect GOARCH for docker build env (build.sh reads GOARCH)
uname_m="$(uname -m)"
GOARCH="amd64"
case "$uname_m" in
  x86_64|amd64) GOARCH="amd64" ;;
  aarch64|arm64) GOARCH="arm64" ;;
  i386|i686) GOARCH="386" ;;
esac

echo "==> shhoook Ubuntu installer"
echo "    repo:      $REPO_URL"
echo "    iface:     $IFACE"
echo "    base path: $BASE"
echo "    conf dir:  $CONF_DIR"
echo "    port:      $PORT"
echo "    goarch:    $GOARCH"
echo "    token:     (hidden)"

tmp="$(mktemp -d)"
cleanup(){ rm -rf "$tmp"; }
trap cleanup EXIT

echo "==> Cloning..."
git clone --depth 1 "$REPO_URL" "$tmp/shhoook"
cd "$tmp/shhoook"

# Ensure example scripts exist (no fallbacks)
WRAPPER_SRC="./example/autostart/ubuntu/usr/local/bin/shhoook-wrapper"
CATALOG_SRC="./example/bin/shhoook-catalog.sh"

if [ ! -f "$WRAPPER_SRC" ]; then
  echo "ERROR: wrapper not found in repo: $WRAPPER_SRC" >&2
  exit 1
fi
if [ ! -f "$CATALOG_SRC" ]; then
  echo "ERROR: shhoook-catalog.sh not found in repo: $CATALOG_SRC" >&2
  exit 1
fi

echo "==> Building (docker compose)..."
# build.sh writes to ./dist (mounted from /out)
GOARCH="$GOARCH" OUTPUT="shhoook" docker compose run --rm \
  -e GOARCH="$GOARCH" \
  -e OUTPUT="shhoook" \
  gobuild

if [ ! -x "./dist/shhoook" ]; then
  echo "ERROR: build succeeded but ./dist/shhoook not found/executable" >&2
  ls -la ./dist || true
  exit 1
fi

echo "==> Installing binaries..."
install -m 0755 ./dist/shhoook /usr/local/bin/shhoook
install -m 0755 "$WRAPPER_SRC" /usr/local/bin/shhoook-wrapper
install -m 0755 "$CATALOG_SRC" /usr/local/bin/shhoook-catalog.sh

echo "==> Creating conf dir..."
mkdir -p "$CONF_DIR"

echo "==> Writing default endpoints..."
cat > "$CONF_DIR/_catalog.json" <<EOF
{
  "about": "List configured endpoints",
  "uri": "/catalog",
  "method": "GET",
  "auth": "X-Token:${TOKEN}",
  "ttl": "5s",
  "error": 500,
  "script": ["/usr/local/bin/shhoook-catalog.sh"]
}
EOF

cat > "$CONF_DIR/uptime.json" <<EOF
{
  "about": "Show system uptime",
  "uri": "/uptime",
  "method": "GET",
  "auth": "X-Token:${TOKEN}",
  "ttl": "5s",
  "error": 500,
  "script": ["bash","-lc","uptime"]
}
EOF

cat > "$CONF_DIR/tail-log.json" <<EOF
{
  "about": "Tail a log file (query: file, n)",
  "uri": "/tail-log",
  "method": "GET",
  "auth": "X-Token:${TOKEN}",
  "ttl": "8s",
  "error": 500,
  "query": { "file": "/var/log/syslog", "n": "50" },
  "script": ["bash","-lc","tail -n {n} {file}"]
}
EOF

cat > "$CONF_DIR/poweroff.json" <<EOF
{
  "about": "Power off the machine (DANGEROUS)",
  "uri": "/poweroff",
  "method": "POST",
  "auth": "X-Token:${TOKEN}",
  "ttl": "10s",
  "error": 500,
  "script": ["bash","-lc","/sbin/poweroff"]
}
EOF

echo "==> Writing systemd unit..."
cat > /etc/systemd/system/shhoook.service <<'EOF'
[Unit]
Description=shhoook — impress the server (HTTP → shell hooks)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/shhoook
ExecStart=/usr/local/bin/shhoook-wrapper
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

echo "==> Writing /etc/default/shhoook..."
cat > /etc/default/shhoook <<EOF
# shhoook service configuration
CONFIG_DIR="${CONF_DIR}"
WAIT_IFACE="${IFACE}"
PORT="${PORT}"
WAIT_V4_PREFIX="${WAIT_V4_PREFIX}"
MAX_WAIT="60"
EOF

echo "==> Enabling + starting service..."
systemctl daemon-reload
systemctl enable --now shhoook.service

echo
echo "==> Installed."
echo "Status:"
echo "  systemctl status shhoook.service"
echo "Logs:"
echo "  journalctl -u shhoook -n 50 --no-pager"
echo
echo "Next:"
echo "  1) Find the IP on interface '$IFACE': ip -4 addr show dev '$IFACE'"
echo "  2) Test:"
echo "     curl -sS -H 'X-Token: ${TOKEN}' http://<IP>:${PORT}/uptime"
echo "     curl -sS -H 'X-Token: ${TOKEN}' http://<IP>:${PORT}/_catalog"

# shhoook — impress the server (HTTP → shell hooks)

`shhoook` is a tiny HTTP server designed for quickly building minimal HTTP-based control layers around **bash / CLI scripts**.

The idea is simple: you describe an endpoint in a single JSON file (URI, method, auth, TTL, argv), and the server:

- listens **strictly on an interface IP** (`LISTEN_ADDR` must be `IP:port`);
- matches requests by HTTP method + URI template;
- collects parameters from path / query / JSON body;
- substitutes `{placeholders}` into command argv;
- executes the command with a timeout;
- returns stdout/stderr as `text/plain`.

It is suitable for micro-admin panels, orchestration of local operations, admin hooks, healthcheck/exec endpoints, and integrations (including n8n), where a full-featured service would be overkill.

---

## Quick start

### Build using Docker Compose

```bash
docker compose run --rm gobuild
# the binary will appear at ./dist/shhoook

LISTEN_ADDR="10.8.0.1:8080" CONFIG_DIR="./conf" ./dist/shhoook
curl -sS http://10.8.0.1:8080/health
# ok
```

---

## Environment variables

| Variable | Purpose | Default |
|--------|---------|---------|
| LISTEN_ADDR | IP:port to listen on | 10.8.0.1:8080 |
| CONFIG_DIR | Directory with *.json endpoints | ./conf |

⚠️ `LISTEN_ADDR` must be exactly `IP:port`. Hostnames are not allowed.

---

## Build configuration for different architectures

The build is controlled via environment variables read by `build.sh`:

- `GOOS` (default: linux)
- `GOARCH` (default: amd64)
- `CGO_ENABLED` (default: 0, static build)
- `OUTPUT` (default: shhoook)
- `MAIN` (default: .)
- `SRC_DIR` (default: /src)
- `OUT_DIR` (default: /out)

### Build examples (via Docker Compose)

#### Linux amd64 (default)
```bash
GOARCH=amd64 docker compose run --rm gobuild
```

#### Linux arm64
```bash
docker compose run --rm -e GOARCH=arm64 gobuild
```

#### Linux arm (e.g. v7)
```bash
docker compose run --rm -e GOARCH=arm -e GOARM=7 gobuild
```

#### ARMv7 (Raspberry Pi 3, legacy ARM)
```bash
docker compose run --rm   -e GOARCH=arm   -e GOARM=7   gobuild
```

#### ARMv6 (older Raspberry Pi)
```bash
docker compose run --rm   -e GOARCH=arm   -e GOARM=6   gobuild
```

---

## Configuration

### Micro-configuration language (conf/*.json)

Each endpoint is defined in a separate JSON file.

The server loads all `*.json` files from `CONFIG_DIR` (default: `./conf`) and builds the endpoint list.

#### Endpoint config format

File: `example/conf/run-hello.json`

```json
{
  "uri": "/run/:name",
  "method": "POST",
  "auth": "X-Token:SECRET",
  "ttl": "8s",
  "error": 500,

  "query": {
    "who": "world"
  },
  "body": {
    "msg": "hi"
  },

  "script": ["bash", "-lc", "echo name={name}; echo who={who}; echo msg={msg}"]
}
```

### Configuration fields

| Field | Required | Description |
|-----|----------|-------------|
| uri | yes | URI template |
| method | yes | HTTP method |
| auth | yes | Header:Token |
| script | yes | Command argv |
| ttl | no | Execution timeout (8s default) |
| error | no | HTTP status code on error |
| query | no | Default query parameters |
| body | no | Default body parameters |

---

### URI templates

- `:name` — a single path segment
- `*rest` — path tail (must be the last segment)

Examples:
- `/run/:id`
- `/run/:id/*rest`

---

### Parameters and precedence

Parameters are merged in the following order:

1. query defaults
2. body defaults
3. path variables
4. URL query parameters
5. JSON body parameters

The last value always wins.

---

### Template substitution

You can use `{placeholder}` in `script` arguments:

```json
"script": ["bash", "-lc", "echo user={user} id={id}"]
```

If a parameter is missing, an empty string is substituted.

---

## Security

- Binds strictly to an IP address
- Minimal PATH
- Empty environment
- Execution timeouts
- stdout + stderr returned to the client

---

## Examples structure

```text
example/
  conf/
    run-hello.json
    run-with-rest.json
  autostart/
    alpine/
    ubuntu/
```

---

## Autostart

Autostart examples are provided in:

- `example/autostart/alpine`
- `example/autostart/ubuntu`

### Autostart after boot and interface availability

Goal: start `shhoook` after the required IP (e.g. `10.8.0.1`) appears on a network interface.

The example directories mirror full system paths from the filesystem root.

Assumptions in examples:

- binary: `/usr/local/bin/shhoook`
- configs: `/etc/shhoook/conf`
- listen address: `10.8.0.1:8080`

---

### Alpine Linux (OpenRC)

Supports waiting for an interface/IP before starting the service.

After copying and configuring the files, run:

```bash
chmod +x /etc/init.d/shhoook
rc-update add shhoook default
rc-service shhoook start
```

---

### Ubuntu 24.xx (systemd)

Uses `ExecStartPre` to wait for the interface/IP and applies systemd hardening.

After copying and configuring the files, run:

```bash
systemctl daemon-reload
systemctl enable --now shhoook.service
systemctl status shhoook.service
```

Check where it is listening:

```bash
sudo journalctl -u shhoook -n 50 --no-pager
ss -lntp | grep shhoook || true
```

---

## Service diagnostics & health checks

### Ubuntu 24.xx (systemd)

**Show recent service logs**
```bash
sudo journalctl -u shhoook -n 50 --no-pager
```

**Check listening sockets**
```bash
ss -lntp | grep shhoook || true
```

**Service status**
```bash
sudo systemctl status shhoook.service
```

**Quick health check**
```bash
curl -sS http://<LISTEN_IP>:<PORT>/health
```

---

### Alpine Linux (OpenRC)

**Show recent service logs (syslog)**
```bash
sudo logread -e shhoook | tail -n 50
```

**If logs are written to a file**
```bash
sudo tail -n 50 /var/log/messages | grep -i shhoook || true
```

**Service status**
```bash
sudo rc-service shhoook status
```

**Check listening sockets (preferred)**
```bash
sudo ss -lntp | grep shhoook || true
```

**If ss is not available**
```bash
sudo netstat -lntp 2>/dev/null | grep shhoook || true
```

**Check by port only**
```bash
sudo ss -lnt | grep ':8080' || true
```

**Quick health check**
```bash
curl -sS http://<LISTEN_IP>:<PORT>/health
```

---

### Notes

On Alpine, `ss` is provided by `iproute2`:

```bash
sudo apk add --no-cache iproute2
```

`netstat` comes from `net-tools` (legacy):

```bash
sudo apk add --no-cache net-tools
```

If the service does not start, check:

- network interface name (`WAIT_IFACE`)
- assigned IPv4 address / prefix
- `LISTEN_ADDR` resolved from the interface

---

## Project purpose

`shhoook` is a tool for engineers who need a:

- deterministic,
- minimalistic,
- easily auditable

HTTP layer on top of shell scripts and CLI tools.

No frameworks. No magic. No runtime dependencies.

---

## License

MIT

#!/bin/bash
# xray-setup.sh — standalone Xray VLESS + TCP + REALITY + Vision installer
#
# Design (same rules as the Hy2 / AnyTLS standalone packages):
#   - One job only: one Xray REALITY+Vision inbound, its own systemd service
#     (xray-reality) and its own directory (/usr/local/etc/xray-reality).
#     It never touches existing sing-box / Xray installs or their configs.
#   - Xray-core is pinned to a fixed version and the release zip is verified
#     against the official .dgst SHA2-256 before anything is installed.
#   - UUID / REALITY keypair / shortId are generated on first run, saved to
#     state.env (0600), and reused on re-runs — re-running never rotates
#     credentials, so already-imported clients keep working.
#   - Three dest modes:
#       external (default): dest = files.pythonhosted.org:443 (Fastly, not in
#         any known script default pool), SNI = files.pythonhosted.org
#       self: your own domain (Cloudflare DNS-only / grey cloud is fine).
#         A local fallback HTTPS site (127.0.0.1:10443, python3) serves your
#         domain's real certificate; dest = 127.0.0.1:10443, SNI = domain.
#       both: install BOTH inbounds in the same Xray process — external on
#         XRAY_PORT (default 443) and self on XRAY_SELF_PORT (default 8443),
#         sharing one UUID / keypair / shortId; two client links are printed.
#         (One REALITY inbound carries exactly one dest, so "combined" means
#         two inbounds side by side, like v2ray-agent's combined install.)
#   - Certificate handling (self/both): existing certs are auto-detected
#     (XRAY_CERT/XRAY_KEY, ~/.acme.sh incl. _ecc, /etc/letsencrypt). If none
#     is found, one is issued automatically (Let's Encrypt, standalone
#     HTTP-01, ECC) — including installing acme.sh itself first when it is
#     missing. Disable all of that with XRAY_AUTO_CERT=0. For acme.sh-managed
#     certs the script also registers --install-cert into its own config dir
#     with a reload hook, so renewals land in place and restart the fallback
#     site automatically.
#   - One-shot like v2ray-agent: missing tools (curl/unzip/python3) are
#     installed via apt-get when possible, and if ufw is active the listen
#     port(s) are allowed through it. Cloud-panel security groups are the
#     one thing no script can open for you.
#   - minClientVer defaults to 26.0.0 (strict): only current-generation
#     Xray-core clients are accepted. sing-box based clients (Karing etc.,
#     which report an old hardcoded version) are rejected — that is the
#     point: old-shaped ClientHellos are statistically rarer and easier to
#     profile. If you still need Karing/sing-box clients, run with
#     XRAY_MIN_CLIENT_VER=1.0.0 to let them back in (a camouflage tradeoff,
#     not a crypto one: authentication still requires the REALITY keys).
#     Note: on Xray 26.10.31, omitting the field entirely enforces nothing,
#     so strictness has to be an explicit version, not an empty value.
#
# Usage:
#   sudo bash xray-setup.sh                      # external dest mode
#   sudo XRAY_DEST_MODE=self XRAY_DOMAIN=node.example.com bash xray-setup.sh
#   sudo XRAY_DEST_MODE=both XRAY_DOMAIN=node.example.com bash xray-setup.sh
#   sudo bash xray-setup.sh --print-link         # re-print client link only
#   sudo bash xray-setup.sh --uninstall          # remove this package only
#
# Env knobs:
#   XRAY_VERSION       pinned core version        (default 26.10.31)
#   XRAY_PORT          listen port                (default 443; in both mode
#                      this is the external inbound's port)
#   XRAY_SELF_PORT     self inbound port in both mode (default 8443)
#   XRAY_DEST_MODE     external | self | both     (default external)
#   XRAY_DEST_HOST     external dest host         (default files.pythonhosted.org)
#   XRAY_DOMAIN        your domain (self mode, required there)
#   XRAY_CERT/XRAY_KEY explicit cert paths (self mode; else auto-detected)
#   XRAY_AUTO_CERT     1 = auto-issue via acme.sh when no cert is found
#                      (default 1); 0 = error out instead
#   XRAY_ADDR          host written into the client link (default: domain in
#                      self mode, else auto-detected public IPv4)
#   XRAY_MIN_CLIENT_VER default 26.0.0 (strict); 1.0.0 = allow sing-box
#                      clients (Karing); "" = omit the field (no check)

set -u

XRAY_VERSION="${XRAY_VERSION:-26.10.31}"
XRAY_PORT="${XRAY_PORT:-443}"
XRAY_SELF_PORT="${XRAY_SELF_PORT:-8443}"
XRAY_DEST_MODE="${XRAY_DEST_MODE:-external}"
XRAY_DEST_HOST="${XRAY_DEST_HOST:-files.pythonhosted.org}"
XRAY_DOMAIN="${XRAY_DOMAIN:-}"
XRAY_CERT="${XRAY_CERT:-}"
XRAY_KEY="${XRAY_KEY:-}"
XRAY_AUTO_CERT="${XRAY_AUTO_CERT:-1}"
XRAY_ADDR="${XRAY_ADDR:-}"
XRAY_MIN_CLIENT_VER="${XRAY_MIN_CLIENT_VER:-26.0.0}"
FALLBACK_PORT=10443

# Testing hooks (not needed on a real VPS):
#   XRAY_ROOT_PREFIX  prefix all install paths (dry local runs)
#   XRAY_BIN          use this xray binary instead of downloading
PREFIX="${XRAY_ROOT_PREFIX:-}"
BIN_DIR="${PREFIX}/usr/local/bin"
CONF_DIR="${PREFIX}/usr/local/etc/xray-reality"
BIN="${XRAY_BIN:-${BIN_DIR}/xray}"
CONF="${CONF_DIR}/config.json"
STATE="${CONF_DIR}/state.env"
UNIT_DIR="${PREFIX}/etc/systemd/system"
SERVICE="xray-reality"
FALLBACK_SERVICE="xray-fallback"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
  [ -n "$PREFIX" ] && return 0
  [ "$(id -u)" = "0" ] || die "run as root: sudo bash xray-setup.sh"
}

valid_port() { case "$1" in ''|*[!0-9]*) return 1;; *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ];; esac; }

# ---------------------------------------------------------------- state ----
load_state() { [ -f "$STATE" ] && . "$STATE" || true; }

save_state() {
  umask 077
  cat > "$STATE" <<EOF
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
PORT=${PORT_SAVED}
MODE=${MODE_SAVED}
SNI=${SNI_SAVED}
LINK_HOST=${LINK_HOST_SAVED}
SELF_PORT=${SELF_PORT_SAVED:-}
SELF_SNI=${SELF_SNI_SAVED:-}
EOF
  chmod 600 "$STATE"
}

gen_credentials() {
  UUID="$("$BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  local kp priv pub
  kp="$("$BIN" x25519)" || die "xray x25519 failed"
  priv="$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey: //p')"
  pub="$(printf '%s\n' "$kp" | sed -n 's/^Password (PublicKey): //p')"
  [ -n "$priv" ] && [ -n "$pub" ] || die "cannot parse xray x25519 output: $kp"
  PRIVATE_KEY="$priv"; PUBLIC_KEY="$pub"
  if command -v openssl >/dev/null 2>&1; then
    SHORT_ID="$(openssl rand -hex 8)"
  else
    SHORT_ID="$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
  fi
}

# ---------------------------------------------------------------- deps -----
ensure_deps() {
  local missing=""
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  command -v unzip >/dev/null 2>&1 || missing="$missing unzip"
  if [ "$XRAY_DEST_MODE" != "external" ]; then
    command -v python3 >/dev/null 2>&1 || missing="$missing python3"
  fi
  [ -z "$missing" ] && return 0
  [ -n "$PREFIX" ] && die "missing tools:$missing (dry run: install them first)"
  if command -v apt-get >/dev/null 2>&1; then
    say "Installing missing tools:$missing"
    apt-get install -y $missing >/dev/null 2>&1 \
      || { apt-get update -qq && apt-get install -y $missing >/dev/null 2>&1; } \
      || die "failed to install:$missing"
  else
    die "missing tools:$missing — install them first"
  fi
}

open_firewall() { # port... — only when ufw exists and is active
  [ -n "$PREFIX" ] && return 0
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -qi '^Status: active' || return 0
  local p
  for p in "$@"; do
    ufw allow "${p}/tcp" >/dev/null 2>&1 && say "ufw: allowed ${p}/tcp (it was active)."
  done
}

# ------------------------------------------------------------- download ----
arch_asset() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7l)        echo "Xray-linux-arm32-v7a.zip" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

fetch() { # url dest
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1";
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1";
  else die "need curl or wget to download Xray-core"; fi
}

install_xray() {
  if [ -x "$BIN" ] && [ -z "${XRAY_BIN:-}" ]; then
    local cur
    cur="$("$BIN" version 2>/dev/null | sed -n 's/^Xray \([0-9.]*\).*/\1/p')"
    if [ "$cur" = "$XRAY_VERSION" ]; then
      say "Xray $XRAY_VERSION already installed at $BIN — skipping download."
      return 0
    fi
    say "Replacing Xray ${cur:-unknown} at $BIN with pinned $XRAY_VERSION."
  fi
  [ -n "${XRAY_BIN:-}" ] && { say "Using provided xray binary: $BIN"; return 0; }

  local asset tmp expected actual
  asset="$(arch_asset)"
  tmp="$(mktemp -d)"
  say "Downloading Xray-core v$XRAY_VERSION ($asset) from GitHub (XTLS)..."
  fetch "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${asset}" "$tmp/xray.zip" \
    || die "download failed: $asset"
  fetch "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${asset}.dgst" "$tmp/xray.dgst" \
    || die "download failed: ${asset}.dgst"
  expected="$(sed -n 's/^SHA2-256= //p' "$tmp/xray.dgst" | tr -d ' \r')"
  actual="$(sha256sum "$tmp/xray.zip" | awk '{print $1}')"
  [ -n "$expected" ] || die "no SHA2-256 line in official .dgst file"
  [ "$expected" = "$actual" ] || die "SHA256 mismatch! expected $expected got $actual — aborting."
  say "SHA256 verified against official .dgst: $actual"

  mkdir -p "$BIN_DIR"
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -q "$tmp/xray.zip" xray -d "$tmp/unz"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract("xray", sys.argv[2])' "$tmp/xray.zip" "$tmp/unz"
  else
    die "need unzip or python3 to extract Xray-core"
  fi
  install -m 0755 "$tmp/unz/xray" "$BIN"
  rm -rf "$tmp"
  "$BIN" version >/dev/null || die "installed xray binary does not run"
  say "Installed: $("$BIN" version | head -n1)"
}

# ---------------------------------------------------------------- cert -----
find_cert() { # domain -> echoes "cert key" or nothing
  local d="$1" base
  if [ -n "$XRAY_CERT" ] && [ -n "$XRAY_KEY" ]; then
    [ -f "$XRAY_CERT" ] && [ -f "$XRAY_KEY" ] && { echo "$XRAY_CERT $XRAY_KEY"; return 0; }
    die "XRAY_CERT/XRAY_KEY given but file missing: $XRAY_CERT / $XRAY_KEY"
  fi
  for base in "${HOME:-/root}/.acme.sh/${d}_ecc" "${HOME:-/root}/.acme.sh/${d}" \
              "/etc/letsencrypt/live/${d}"; do
    if [ -f "$base/fullchain.pem" ] && [ -f "$base/privkey.pem" ]; then
      echo "$base/fullchain.pem $base/privkey.pem"; return 0
    fi
    if [ -f "$base/fullchain.cer" ] && [ -f "$base/${d}.key" ]; then
      echo "$base/fullchain.cer $base/${d}.key"; return 0
    fi
  done
  return 1
}

install_acme() { # installs acme.sh (official installer) if missing
  local acme="${HOME:-/root}/.acme.sh/acme.sh" tmp
  [ -x "$acme" ] && return 0
  say "acme.sh not found — installing it (official installer from get.acme.sh)..."
  tmp="$(mktemp -d)"
  if ! curl -fsSL https://get.acme.sh -o "${tmp}/acme-install.sh"; then
    rm -rf "$tmp"; warn "cannot download the acme.sh installer"; return 1
  fi
  ( cd "$tmp" && sh acme-install.sh >/dev/null 2>&1 ) || { rm -rf "$tmp"; warn "acme.sh installer failed"; return 1; }
  rm -rf "$tmp"
  [ -x "$acme" ] || { warn "acme.sh still missing after install"; return 1; }
  say "acme.sh installed."
}

issue_cert() { # domain — issue via acme.sh standalone (Let's Encrypt, ECC)
  local acme="${HOME:-/root}/.acme.sh/acme.sh"
  install_acme || { warn "cannot auto-issue without acme.sh"; return 1; }
  if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE '[:.]80[[:space:]]'; then
    warn "port 80 is already in use — acme.sh standalone needs it for the HTTP-01 challenge"
    return 1
  fi
  say "No certificate found for $1 — issuing one with acme.sh (Let's Encrypt, standalone)..."
  "$acme" --issue -d "$1" --standalone --server letsencrypt --keylength ec-256
}

# ------------------------------------------------------------- fallback ----
write_fallback() { # cert key domain
  local cert="$1" key="$2" domain="$3"
  command -v python3 >/dev/null 2>&1 || die "self mode needs python3 for the local fallback HTTPS site"
  mkdir -p "${CONF_DIR}/webroot"
  if [ ! -f "${CONF_DIR}/webroot/index.html" ]; then
    cat > "${CONF_DIR}/webroot/index.html" <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>${domain}</title></head>
<body><h1>Welcome to ${domain}</h1><p>This site is under construction.</p></body></html>
HTML
  fi
  cat > "${CONF_DIR}/fallback.py" <<'PY'
import ssl, sys, http.server, threading
cert, key, root, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
ctx.set_alpn_protocols(["h2", "http/1.1"])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=root, **kw)
    def log_message(self, *a):
        pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
  cat > "${UNIT_DIR}/${FALLBACK_SERVICE}.service" <<EOF
[Unit]
Description=Xray REALITY fallback HTTPS site (self dest mode)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${CONF_DIR}/fallback.py ${cert} ${key} ${CONF_DIR}/webroot ${FALLBACK_PORT}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  say "Fallback site unit written (${FALLBACK_SERVICE}, 127.0.0.1:${FALLBACK_PORT})."
}

# --------------------------------------------------------------- config ----
MINLINE=""
if [ -n "$XRAY_MIN_CLIENT_VER" ]; then
  MINLINE="          \"minClientVer\": \"${XRAY_MIN_CLIENT_VER}\","
fi

inbound_json() { # port dest sni — prints one inbound object
  cat <<EOF
    {
      "listen": "0.0.0.0",
      "port": $1,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$2",
          "xver": 0,
          "serverNames": [ "$3" ],
          "privateKey": "${PRIVATE_KEY}",
${MINLINE}
          "shortIds": [ "${SHORT_ID}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    }
EOF
}

write_config() {
  local inbounds=""
  case "$XRAY_DEST_MODE" in
    external)
      inbounds="$(inbound_json "$XRAY_PORT" "${XRAY_DEST_HOST}:443" "$XRAY_DEST_HOST")" ;;
    self)
      inbounds="$(inbound_json "$XRAY_PORT" "127.0.0.1:${FALLBACK_PORT}" "$XRAY_DOMAIN")" ;;
    both)
      inbounds="$(inbound_json "$XRAY_PORT" "${XRAY_DEST_HOST}:443" "$XRAY_DEST_HOST"),
$(inbound_json "$XRAY_SELF_PORT" "127.0.0.1:${FALLBACK_PORT}" "$XRAY_DOMAIN")" ;;
  esac
  mkdir -p "$CONF_DIR"
  # NOTE: the temp name must end in .json — xray detects the config format
  # from the file extension and refuses ".tmp".
  cat > "${CONF_DIR}/.config.tmp.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
  "$BIN" run -test -config "${CONF_DIR}/.config.tmp.json" >/dev/null 2>&1 \
    || { "$BIN" run -test -config "${CONF_DIR}/.config.tmp.json"; die "generated config failed xray run -test"; }
  if [ -f "$CONF" ]; then
    cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  mv "${CONF_DIR}/.config.tmp.json" "$CONF"
  chmod 600 "$CONF"
  say "Config written and validated: $CONF"
}

write_service() {
  mkdir -p "$UNIT_DIR" "${UNIT_DIR}/${SERVICE}.service.d"
  cat > "${UNIT_DIR}/${SERVICE}.service" <<EOF
[Unit]
Description=Xray VLESS REALITY Vision (standalone)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${BIN} run -config ${CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  # Same memory cap as the fleet tuning (2026-11-05): Xray is a Go binary.
  cat > "${UNIT_DIR}/${SERVICE}.service.d/memlimit.conf" <<'EOF'
[Service]
Environment=GOMEMLIMIT=80MiB
Environment=GOGC=50
EOF
  say "Service unit written: ${SERVICE}"
}

public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null || true)"
  case "$ip" in *[!0-9.]*|'') ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)";; esac
  case "$ip" in *[!0-9.]*|'') echo "";; *) echo "$ip";; esac
}

make_link() { # host port sni tag
  echo "vless://${UUID}@$1:$2?encryption=none&security=reality&sni=$3&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=tcp&flow=xtls-rprx-vision#$4"
}

print_link() {
  local links="" info_blocks=""
  case "$MODE_SAVED" in
    external)
      local l1; l1="$(make_link "$LINK_HOST_SAVED" "$PORT_SAVED" "$SNI_SAVED" "xray-reality")"
      links="$l1"
      info_blocks="Address      : ${LINK_HOST_SAVED}
Port         : ${PORT_SAVED}
SNI / dest   : ${SNI_SAVED} (external)

Share link:
${l1}" ;;
    self)
      local l2; l2="$(make_link "$LINK_HOST_SAVED" "$PORT_SAVED" "$SNI_SAVED" "xray-reality")"
      links="$l2"
      info_blocks="Address      : ${LINK_HOST_SAVED}
Port         : ${PORT_SAVED}
SNI / dest   : ${SNI_SAVED} (self, local fallback)

Share link:
${l2}" ;;
    both)
      local lb1 lb2
      lb1="$(make_link "$LINK_HOST_SAVED" "$PORT_SAVED" "$SNI_SAVED" "xray-reality-external")"
      lb2="$(make_link "$SELF_SNI_SAVED" "$SELF_PORT_SAVED" "$SELF_SNI_SAVED" "xray-reality-self")"
      links="${lb1}
${lb2}"
      info_blocks="[external inbound]
Address      : ${LINK_HOST_SAVED}
Port         : ${PORT_SAVED}
SNI / dest   : ${SNI_SAVED} (external)
Share link:
${lb1}

[self inbound]
Address      : ${SELF_SNI_SAVED}
Port         : ${SELF_PORT_SAVED}
SNI / dest   : ${SELF_SNI_SAVED} (self, local fallback)
Share link:
${lb2}" ;;
  esac
  cat > "${CONF_DIR}/client-info.txt" <<EOF
Xray VLESS + TCP + REALITY + Vision (standalone)
================================================
Mode         : ${MODE_SAVED}
UUID         : ${UUID}
Flow         : xtls-rprx-vision
Security     : reality
Fingerprint  : chrome
Public key   : ${PUBLIC_KEY}
Short ID     : ${SHORT_ID}
minClientVer : ${XRAY_MIN_CLIENT_VER:-(omitted / no version check)}

${info_blocks}

Notes:
- Import the link(s) into v2rayN / v2rayNG (Xray core) as-is.
- minClientVer default 26.0.0 rejects sing-box based clients (Karing);
  re-run with XRAY_MIN_CLIENT_VER=1.0.0 on the server if you need them.
- The link(s) contain full credentials. Do not post them publicly.
EOF
  chmod 600 "${CONF_DIR}/client-info.txt"
  say ""
  say "================ client link(s) ================"
  say "$links"
  say "================================================"
  say "Saved to ${CONF_DIR}/client-info.txt (0600)."
}

smoke_test() { # port sni
  local port="$1" sni="$2"
  command -v openssl >/dev/null 2>&1 || { warn "openssl not found, skipping smoke test"; return 0; }
  sleep 2
  local out
  out="$(echo | openssl s_client -connect "127.0.0.1:${port}" -servername "$sni" -tls1_3 2>/dev/null | grep -E 'subject=|Protocol' | head -n 3 || true)"
  if printf '%s' "$out" | grep -qi "$sni"; then
    say "Smoke test OK (port ${port}): unauthenticated handshake returns the dest certificate for ${sni}."
  else
    warn "smoke test could not confirm the dest certificate for ${sni} on port ${port} (dest reachability?)."
    warn "Check: journalctl -u ${SERVICE} -n 50"
  fi
}

# ------------------------------------------------------------ uninstall ----
do_uninstall() {
  need_root
  if [ -z "$PREFIX" ]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    systemctl disable --now "$FALLBACK_SERVICE" 2>/dev/null || true
  fi
  rm -f "${UNIT_DIR}/${SERVICE}.service" "${UNIT_DIR}/${FALLBACK_SERVICE}.service"
  rm -rf "${UNIT_DIR}/${SERVICE}.service.d"
  rm -rf "$CONF_DIR"
  [ -z "${XRAY_BIN:-}" ] && rm -f "${BIN_DIR}/xray"
  [ -z "$PREFIX" ] && systemctl daemon-reload 2>/dev/null || true
  say "Removed ${SERVICE} (+ fallback if any), its config dir and the managed xray binary."
  say "Nothing else on this machine was touched."
  exit 0
}

# ----------------------------------------------------------------- main ----
case "${1:-}" in
  --uninstall) do_uninstall ;;
  --print-link)
    load_state
    [ -n "${UUID:-}" ] || die "no state found at $STATE — run the installer first"
    PORT_SAVED="${PORT:-$XRAY_PORT}"; MODE_SAVED="${MODE:-$XRAY_DEST_MODE}"
    SNI_SAVED="${SNI:-}"; LINK_HOST_SAVED="${LINK_HOST:-}"
    SELF_PORT_SAVED="${SELF_PORT:-}"; SELF_SNI_SAVED="${SELF_SNI:-}"
    print_link
    exit 0 ;;
esac

need_root
valid_port "$XRAY_PORT" || die "invalid XRAY_PORT: $XRAY_PORT"
case "$XRAY_DEST_MODE" in external|self|both) ;; *) die "XRAY_DEST_MODE must be external, self or both";; esac
if [ "$XRAY_DEST_MODE" = "both" ]; then
  valid_port "$XRAY_SELF_PORT" || die "invalid XRAY_SELF_PORT: $XRAY_SELF_PORT"
  [ "$XRAY_SELF_PORT" != "$XRAY_PORT" ] || die "both mode needs XRAY_PORT != XRAY_SELF_PORT"
fi

# Port occupancy: refuse to stomp on someone else's listener.
check_port_free() {
  if [ -z "$PREFIX" ] && command -v ss >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -qE "[:.]$1[[:space:]]"; then
      if ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        die "port $1 is already in use by something else — change the port or free it first"
      fi
    fi
  fi
}
check_port_free "$XRAY_PORT"
[ "$XRAY_DEST_MODE" = "both" ] && check_port_free "$XRAY_SELF_PORT"

ensure_deps
install_xray
mkdir -p "$CONF_DIR" "$UNIT_DIR"

# ---- resolve mode parameters
SELF_PORT_SAVED=""; SELF_SNI_SAVED=""
if [ "$XRAY_DEST_MODE" != "external" ]; then
  [ -n "$XRAY_DOMAIN" ] || die "self/both mode needs XRAY_DOMAIN=<your domain, DNS pointing to this server>"
  CERT_SRC=""
  if certpair="$(find_cert "$XRAY_DOMAIN")"; then
    :
  elif [ "$XRAY_AUTO_CERT" = "1" ] && issue_cert "$XRAY_DOMAIN" && certpair="$(find_cert "$XRAY_DOMAIN")"; then
    say "Certificate issued for $XRAY_DOMAIN."
  else
    die "no certificate found for $XRAY_DOMAIN (checked XRAY_CERT, ~/.acme.sh incl. _ecc, /etc/letsencrypt) and auto-issue is unavailable or failed. Issue one manually, e.g. acme.sh --issue -d $XRAY_DOMAIN --standalone, or pass XRAY_CERT/XRAY_KEY."
  fi
  CERT_FILE="${certpair%% *}"; KEY_FILE="${certpair##* }"
  case "$CERT_FILE" in "${HOME:-/root}/.acme.sh/"*) CERT_SRC="acme";; esac
  if [ "$CERT_SRC" = "acme" ]; then
    # Copy the acme.sh-managed cert into our own dir and register a reload
    # hook, so automatic renewals land here and restart the fallback site.
    local_ecc=""
    case "$CERT_FILE" in *"_ecc/"*) local_ecc="--ecc";; esac
    mkdir -p "$CONF_DIR"
    if "${HOME:-/root}/.acme.sh/acme.sh" --install-cert -d "$XRAY_DOMAIN" $local_ecc \
         --fullchain-file "${CONF_DIR}/fullchain.pem" --key-file "${CONF_DIR}/privkey.pem" \
         --reloadcmd "systemctl restart ${FALLBACK_SERVICE}" >/dev/null 2>&1; then
      CERT_FILE="${CONF_DIR}/fullchain.pem"; KEY_FILE="${CONF_DIR}/privkey.pem"
      say "acme.sh renewal hook registered (renewed cert -> ${CONF_DIR}, restarts ${FALLBACK_SERVICE})."
    else
      warn "acme.sh --install-cert failed; using the cert in place — renewals will need a manual ${FALLBACK_SERVICE} restart."
    fi
  fi
  say "Self inbound: $XRAY_DOMAIN with cert $CERT_FILE"
  # Sanity: DNS should point at this machine (warning only — proxies/VPN mgmt exist).
  dns_ip="$(getent hosts "$XRAY_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  my_ip="$(public_ipv4)"
  if [ -n "$dns_ip" ] && [ -n "$my_ip" ] && [ "$dns_ip" != "$my_ip" ]; then
    warn "$XRAY_DOMAIN resolves to $dns_ip but this server's public IP looks like $my_ip"
  fi
fi
case "$XRAY_DEST_MODE" in
  external)
    SNI="$XRAY_DEST_HOST"
    LINK_HOST="${XRAY_ADDR:-$(public_ipv4)}" ;;
  self)
    SNI="$XRAY_DOMAIN"
    LINK_HOST="${XRAY_ADDR:-$XRAY_DOMAIN}" ;;
  both)
    SNI="$XRAY_DEST_HOST"
    LINK_HOST="${XRAY_ADDR:-$(public_ipv4)}"
    SELF_PORT_SAVED="$XRAY_SELF_PORT"; SELF_SNI_SAVED="$XRAY_DOMAIN" ;;
esac
[ -n "$LINK_HOST" ] || { LINK_HOST="YOUR_SERVER_IP"; warn "could not auto-detect public IPv4 — replace YOUR_SERVER_IP in the client link, or re-run with XRAY_ADDR=<ip>"; }

# ---- credentials: reuse state when ports & mode & snis still match the request
load_state
if [ -n "${UUID:-}" ] && [ -n "${PRIVATE_KEY:-}" ] \
   && [ "${PORT:-}" = "$XRAY_PORT" ] && [ "${MODE:-}" = "$XRAY_DEST_MODE" ] && [ "${SNI:-}" = "$SNI" ] \
   && [ "${SELF_PORT:-}" = "$SELF_PORT_SAVED" ] && [ "${SELF_SNI:-}" = "$SELF_SNI_SAVED" ]; then
  say "Reusing existing credentials from state (UUID / keys / shortId unchanged)."
else
  [ -n "${UUID:-}" ] && say "Parameters changed — generating fresh credentials."
  gen_credentials
fi

PORT_SAVED="$XRAY_PORT"; MODE_SAVED="$XRAY_DEST_MODE"; SNI_SAVED="$SNI"; LINK_HOST_SAVED="$LINK_HOST"
save_state

if [ "$XRAY_DEST_MODE" != "external" ]; then
  write_fallback "$CERT_FILE" "$KEY_FILE" "$XRAY_DOMAIN"
fi
write_config
write_service

if [ -z "$PREFIX" ]; then
  systemctl daemon-reload
  [ "$XRAY_DEST_MODE" != "external" ] && systemctl enable --now "$FALLBACK_SERVICE"
  systemctl enable --now "$SERVICE"
  systemctl is-active --quiet "$SERVICE" || { journalctl -u "$SERVICE" -n 30 --no-pager; die "service failed to start"; }
  say "Service ${SERVICE} is running."
  if [ "$XRAY_DEST_MODE" = "both" ]; then
    open_firewall "$XRAY_PORT" "$XRAY_SELF_PORT"
  else
    open_firewall "$XRAY_PORT"
  fi
else
  say "Dry local run (prefix set): systemd steps skipped."
fi

if [ -z "$PREFIX" ]; then
  case "$XRAY_DEST_MODE" in
    external) smoke_test "$XRAY_PORT" "$XRAY_DEST_HOST" ;;
    self)     smoke_test "$XRAY_PORT" "$XRAY_DOMAIN" ;;
    both)     smoke_test "$XRAY_PORT" "$XRAY_DEST_HOST"; smoke_test "$XRAY_SELF_PORT" "$XRAY_DOMAIN" ;;
  esac
fi
print_link
say ""
if [ "$XRAY_DEST_MODE" = "both" ]; then
  say "Done. Firewall/cloud panel: allow TCP ${XRAY_PORT} and TCP ${XRAY_SELF_PORT} inbound if this is a fresh box."
else
  say "Done. Firewall/cloud panel: allow TCP ${XRAY_PORT} inbound if this is a fresh box."
fi

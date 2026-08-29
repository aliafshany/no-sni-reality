#!/usr/bin/env bash
#
# no-sni-reality — one-command installer.
#
# Sets up VLESS + XTLS-Vision + REALITY on a server, arranged so the client
# never sends an SNI at all, and so anyone who probes the port sees an ordinary
# HTTPS server holding a browser-trusted Let's Encrypt certificate issued for
# the bare IP address. No domain name is involved anywhere.
#
#   ssh root@SERVER 'curl -fsSL https://raw.githubusercontent.com/aliafshany/no-sni-reality/main/install.sh | bash'
#
# Optional environment overrides, set before the pipe:
#
#   PORT=8443          public TCP port for VLESS   (default: first free of 443 8443 2083 2087 2096 9443)
#   FALLBACK_PORT=8444 loopback port for the decoy nginx
#   ACME_EMAIL=you@x   registration address for Let's Encrypt
#   SERVER_IP=1.2.3.4  skip public IP autodetection
#   TAG=my-node        label shown at the end of the share link
#
set -eu

RS_TAG_INBOUND="reality-ip-nosni"
CERT_DIR=/etc/no-sni-reality
WEBROOT=/var/www/no-sni-reality
XRAY_CONFIG=/usr/local/etc/xray/config.json
OUT_DIR=/root/no-sni-reality
NGINX_ACME_CONF=/etc/nginx/conf.d/no-sni-reality-acme.conf
NGINX_DECOY_CONF=/etc/nginx/conf.d/no-sni-reality-decoy.conf

FALLBACK_PORT="${FALLBACK_PORT:-8444}"
ACME_EMAIL="${ACME_EMAIL:-}"
TAG="${TAG:-no-sni-reality}"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$GRN$BLD" "$OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW$BLD" "$OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED$BLD" "$OFF" "$*" >&2; exit 1; }

# --------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || die "run this as root"
[ "$(uname -s)" = Linux ] || die "Linux only (found $(uname -s))"
command -v systemctl >/dev/null 2>&1 || die "this installer manages services with systemd"

if   command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
elif command -v yum     >/dev/null 2>&1; then PKG=yum
else die "need apt-get, dnf or yum; install nginx, curl, socat, cron and jq by hand and rerun"
fi

# Everything that might read stdin gets /dev/null, because when this script is
# run as 'curl | bash' the shell's stdin is the script itself. A package manager
# prompt would otherwise swallow the rest of the file and the install would stop
# halfway with no error at all.
install_packages() {
  say "installing packages with $PKG"
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
      # A broken third-party repo must not stop the run. If a package we actually
      # need is missing, the install below fails and says so.
      apt-get update -qq </dev/null || warn "apt-get update reported errors, continuing"
      apt-get install -y -qq nginx curl socat cron openssl jq unzip ca-certificates </dev/null >/dev/null \
        || die "package install failed; fix the package sources and rerun"
      apt-get install -y -qq qrencode </dev/null >/dev/null 2>&1 || true
      ;;
    dnf|yum)
      $PKG install -y -q nginx curl socat cronie openssl jq unzip ca-certificates </dev/null >/dev/null \
        || die "package install failed"
      # qrencode lives in EPEL on RHEL derivatives, and the QR code is a nicety.
      $PKG install -y -q qrencode </dev/null >/dev/null 2>&1 || true
      systemctl enable --now crond >/dev/null 2>&1 || true
      ;;
  esac
}

port_in_use() {
  local ports
  ports=$(ss -lntH 2>/dev/null | awk '{print $4}' | sed 's/.*://' || true)
  grep -qx -- "$1" <<<"$ports"
}

port_owner() {
  ss -lntpH "sport = :$1" 2>/dev/null | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p' | head -1
}

is_number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# $1 is the port to avoid, so the public port and the loopback decoy port can
# never land on the same number.
pick_port() {
  local avoid="${1:-0}" candidate
  for candidate in 443 8443 2083 2087 2096 9443; do
    [ "$candidate" = "$avoid" ] && continue
    port_in_use "$candidate" || { printf '%s' "$candidate"; return 0; }
  done
  for _ in $(seq 1 60); do
    candidate=$(( (RANDOM % 20000) + 20000 ))
    [ "$candidate" = "$avoid" ] && continue
    port_in_use "$candidate" || { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

detect_ip() {
  local url ip
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -fsS4 -m 8 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    if printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

open_firewall() {
  local port
  for port in "$@"; do
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
      ufw allow "$port"/tcp >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1 || true
      FIREWALLD_TOUCHED=1
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | head -1 | grep -q -- '-P INPUT DROP'; then
      iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
    fi
  done
  if [ -n "${FIREWALLD_TOUCHED:-}" ]; then
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qE 'hook input .*policy drop'; then
    warn "nftables input policy is drop — open TCP 80 and $XRAY_PORT there yourself"
  fi
  return 0
}

# nginx is confined by SELinux on RHEL derivatives and http_port_t does not
# cover an arbitrary loopback port, so binding the decoy would be denied.
allow_selinux_port() {
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    if command -v semanage >/dev/null 2>&1; then
      semanage port -a -t http_port_t -p tcp "$1" >/dev/null 2>&1 \
        || semanage port -m -t http_port_t -p tcp "$1" >/dev/null 2>&1 \
        || warn "could not label TCP $1 as http_port_t; nginx may be denied by SELinux"
    else
      warn "SELinux is enforcing but semanage is missing; install policycoreutils-python-utils if nginx fails to bind $1"
    fi
  fi
  return 0
}

# --------------------------------------------------------------- decisions

SERVER_IP="${SERVER_IP:-}"
if [ -z "$SERVER_IP" ]; then
  say "detecting public IPv4"
  SERVER_IP=$(detect_ip) || die "could not detect a public IPv4; rerun with SERVER_IP=1.2.3.4"
fi
say "server address: $SERVER_IP"

# An existing install is reused rather than replaced, so rerunning this script is
# safe and hands back the same link.
REUSED=""
if [ -f "$XRAY_CONFIG" ] && jq -e --arg t "$RS_TAG_INBOUND" \
     '.inbounds[]? | select(.tag == $t)' "$XRAY_CONFIG" >/dev/null 2>&1; then
  UUID=$(jq -r --arg t "$RS_TAG_INBOUND" '[.inbounds[] | select(.tag==$t)][0].settings.clients[0].id // ""' "$XRAY_CONFIG")
  PRIVATE_KEY=$(jq -r --arg t "$RS_TAG_INBOUND" '[.inbounds[] | select(.tag==$t)][0].streamSettings.realitySettings.privateKey // ""' "$XRAY_CONFIG")
  OLD_PORT=$(jq -r --arg t "$RS_TAG_INBOUND" '[.inbounds[] | select(.tag==$t)][0].port // ""' "$XRAY_CONFIG")
  OLD_DEST=$(jq -r --arg t "$RS_TAG_INBOUND" '[.inbounds[] | select(.tag==$t)][0].streamSettings.realitySettings.dest // ""' "$XRAY_CONFIG")

  # jq prints the word "null" for a missing field, which is not empty. Anything
  # unusable here means the old inbound is broken; build a fresh one instead.
  if [ -n "$UUID" ] && [ "$UUID" != null ] \
     && [ -n "$PRIVATE_KEY" ] && [ "$PRIVATE_KEY" != null ] \
     && is_number "$OLD_PORT"; then
    REUSED=1
    XRAY_PORT="$OLD_PORT"
    case "$OLD_DEST" in
      *:*) OLD_FALLBACK="${OLD_DEST##*:}"; is_number "$OLD_FALLBACK" && FALLBACK_PORT="$OLD_FALLBACK" ;;
    esac
    say "found an existing install — keeping its UUID, key and port $XRAY_PORT"
  else
    warn "existing $RS_TAG_INBOUND inbound is incomplete; generating a fresh one"
    UUID=""; PRIVATE_KEY=""
  fi
fi

# Port 80 has to be free: http-01 is the only challenge Let's Encrypt will run
# against an IP identifier, dns-01 cannot validate an IP, and tls-alpn-01 would
# need the port REALITY is on.
if [ ! -f "$CERT_DIR/fullchain.pem" ] && port_in_use 80; then
  owner=$(port_owner 80)
  [ "$owner" = nginx ] || die "TCP 80 is held by ${owner:-another process}; free it and rerun — the certificate cannot be issued or renewed without it"
fi

NGINX_WAS_PRESENT=""
command -v nginx >/dev/null 2>&1 && NGINX_WAS_PRESENT=1

install_packages

if [ -z "$REUSED" ]; then
  if [ -n "${PORT:-}" ]; then
    is_number "$PORT" || die "PORT must be a number"
    XRAY_PORT="$PORT"
    if port_in_use "$XRAY_PORT"; then
      die "TCP $XRAY_PORT is already held by $(port_owner "$XRAY_PORT")"
    fi
  else
    XRAY_PORT=$(pick_port "$FALLBACK_PORT") || die "no free TCP port found"
  fi
fi

if [ "$FALLBACK_PORT" = "$XRAY_PORT" ]; then
  die "FALLBACK_PORT and the public port cannot both be $XRAY_PORT"
fi
if [ -z "$REUSED" ]; then
  while port_in_use "$FALLBACK_PORT" || [ "$FALLBACK_PORT" = "$XRAY_PORT" ]; do
    FALLBACK_PORT=$((FALLBACK_PORT + 1))
    [ "$FALLBACK_PORT" -lt 65535 ] || die "no free loopback port for the decoy site"
  done
fi

say "public port $XRAY_PORT, decoy site on 127.0.0.1:$FALLBACK_PORT"
open_firewall 80 "$XRAY_PORT"
allow_selinux_port "$FALLBACK_PORT"

# --------------------------------------------------------------- acme + cert

ACME=/root/.acme.sh/acme.sh
if [ ! -x "$ACME" ]; then
  say "installing acme.sh"
  if [ -n "$ACME_EMAIL" ]; then
    curl -fsS https://get.acme.sh | sh -s email="$ACME_EMAIL" >/dev/null
  else
    curl -fsS https://get.acme.sh | sh >/dev/null
  fi
fi
[ -x "$ACME" ] || die "acme.sh did not install"

"$ACME" --upgrade --auto-upgrade >/dev/null 2>&1 || true
ACME_HELP=$("$ACME" --help 2>&1 || true)
grep -q -- '--certificate-profile' <<<"$ACME_HELP" \
  || die "this acme.sh is too old for certificate profiles; run '$ACME --upgrade' and rerun"
"$ACME" --set-default-ca --server letsencrypt >/dev/null

mkdir -p "$WEBROOT" "$CERT_DIR" "$OUT_DIR"
chmod 700 "$CERT_DIR" "$OUT_DIR"

# Matching on server_name rather than claiming default_server keeps this block
# from colliding with whatever default server the distro's nginx already ships.
LISTEN6=""
[ -f /proc/net/if_inet6 ] && LISTEN6="    listen [::]:80;"

say "writing nginx ACME block"
cat > "$NGINX_ACME_CONF" <<EOF
server {
    listen 80;
$LISTEN6
    server_name $SERVER_IP;
    root $WEBROOT;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 404; }
}
EOF

# Debian ships a placeholder site that claims port 80 as default_server. Only
# drop it when this run is what installed nginx, so an existing web server on
# the box keeps whatever it was serving.
if [ -z "$NGINX_WAS_PRESENT" ] && [ -L /etc/nginx/sites-enabled/default ]; then
  rm -f /etc/nginx/sites-enabled/default
fi

nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx rejected the ACME config"; }
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
  # acme.sh exits non-zero when asked to reissue a certificate that has not
  # expired, so an existing one in its store is installed rather than requested.
  if [ -f "/root/.acme.sh/${SERVER_IP}_ecc/fullchain.cer" ]; then
    say "acme.sh already holds a certificate for $SERVER_IP; installing it"
  else
    say "requesting a Let's Encrypt certificate for $SERVER_IP"
    # 'shortlived' is the only Let's Encrypt profile that accepts an IP address
    # as an identifier. It lives 160 hours, hence the three-day renewal check.
    "$ACME" --issue --server letsencrypt \
        -d "$SERVER_IP" \
        -w "$WEBROOT" \
        --certificate-profile shortlived \
        --days 3 \
      || die "certificate issuance failed — check that TCP 80 is reachable from the internet"
  fi

  "$ACME" --install-cert -d "$SERVER_IP" --ecc \
      --key-file       "$CERT_DIR/key.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" \
      --reloadcmd      "systemctl reload nginx" >/dev/null
else
  say "certificate already present, leaving it alone"
fi

[ -s "$CERT_DIR/fullchain.pem" ] || die "certificate file is empty"

# acme.sh renews using the webroot it recorded at issue time. If that directory
# is not the one nginx serves any more — an earlier hand-built setup, a moved
# docroot — renewal fails the http-01 challenge and the certificate quietly dies
# 160 hours later. Repoint it.
ACME_DOMAIN_CONF="/root/.acme.sh/${SERVER_IP}_ecc/${SERVER_IP}.conf"
if [ -f "$ACME_DOMAIN_CONF" ]; then
  STORED_WEBROOT=$(sed -n "s/^Le_Webroot='\(.*\)'\$/\1/p" "$ACME_DOMAIN_CONF" | head -1)
  if [ -n "$STORED_WEBROOT" ] && [ "$STORED_WEBROOT" != "$WEBROOT" ]; then
    warn "renewal pointed at $STORED_WEBROOT, which is not what nginx serves; repointing to $WEBROOT"
    sed -i "s#^Le_Webroot='.*'#Le_Webroot='$WEBROOT'#" "$ACME_DOMAIN_CONF"
  fi
fi

CRONTAB_NOW=$(crontab -l 2>/dev/null || true)
grep -q 'acme.sh --cron' <<<"$CRONTAB_NOW" || "$ACME" --install-cronjob >/dev/null 2>&1 || true
CRONTAB_NOW=$(crontab -l 2>/dev/null || true)
grep -q 'acme.sh --cron' <<<"$CRONTAB_NOW" \
  || warn "no acme.sh cron entry — this certificate will not renew itself"

# Prove the challenge directory is actually reachable, rather than assuming it.
# This is the single thing that makes or breaks renewal, and it is silent when
# it breaks.
CANARY=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
mkdir -p "$WEBROOT/.well-known/acme-challenge"
printf '%s' "$CANARY" > "$WEBROOT/.well-known/acme-challenge/$CANARY"
if [ "$(curl -fsS -m 10 "http://$SERVER_IP/.well-known/acme-challenge/$CANARY" 2>/dev/null)" = "$CANARY" ]; then
  say "renewal path verified: the ACME challenge directory answers over HTTP"
else
  warn "the ACME challenge directory is NOT reachable at http://$SERVER_IP/.well-known/acme-challenge/
     This certificate lives 160 hours and will not renew. Free TCP 80 and rerun."
fi
rm -f "$WEBROOT/.well-known/acme-challenge/$CANARY"

# --------------------------------------------------------------- decoy site

# 'http2 on;' only exists from nginx 1.25.1. Older builds — Debian 12, Ubuntu
# 24.04 — take the parameter on the listen line instead, and rejecting the wrong
# one is a hard config error.
NGINX_VERSION=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9.]*\).*#\1#p')
if [ -n "$NGINX_VERSION" ] && version_ge "$NGINX_VERSION" 1.25.1; then
  DECOY_LISTEN="listen 127.0.0.1:$FALLBACK_PORT ssl default_server;
    http2 on;"
else
  DECOY_LISTEN="listen 127.0.0.1:$FALLBACK_PORT ssl http2 default_server;"
fi

say "writing the decoy site on 127.0.0.1:$FALLBACK_PORT (nginx ${NGINX_VERSION:-unknown})"
cat > "$NGINX_DECOY_CONF" <<EOF
server {
    $DECOY_LISTEN
    server_name _;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ecdh_curve      X25519:prime256v1;
    ssl_session_tickets off;

    location / {
        default_type text/html;
        return 200 "<html><head><title></title></head><body></body></html>";
    }
}
EOF

nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx rejected the decoy config"; }
systemctl reload nginx

# --------------------------------------------------------------- xray

if ! command -v xray >/dev/null 2>&1; then
  say "installing Xray-core"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
    </dev/null >/dev/null 2>&1 || die "Xray install script failed"
fi
command -v xray >/dev/null 2>&1 || die "xray is not on PATH after install"
say "$(xray version 2>/dev/null | head -1 || true)"

if [ -z "${UUID:-}" ]; then
  UUID=$(xray uuid)
fi
if [ -z "${PRIVATE_KEY:-}" ]; then
  KEYPAIR=$(xray x25519)
  PRIVATE_KEY=$(printf '%s\n' "$KEYPAIR" | sed -n 's/.*[Pp]rivate[ _-]*[Kk]ey:[[:space:]]*//p' | head -1 | tr -d ' ')
fi
[ -n "$PRIVATE_KEY" ] || die "could not obtain a REALITY private key"

# Derive the public key from the private one, so a reused install still prints a
# correct link. Newer Xray labels this line 'Password (PublicKey)'.
DERIVED=$(xray x25519 -i "$PRIVATE_KEY") || die "xray rejected the stored private key"
PUBLIC_KEY=$(printf '%s\n' "$DERIVED" | sed -n 's/.*(PublicKey):[[:space:]]*//p' | head -1 | tr -d ' ')
if [ -z "$PUBLIC_KEY" ]; then
  PUBLIC_KEY=$(printf '%s\n' "$DERIVED" | sed -n 's/.*[Pp]ublic[ _-]*[Kk]ey:[[:space:]]*//p' | head -1 | tr -d ' ')
fi
[ -n "$PUBLIC_KEY" ] || die "could not derive the REALITY public key"

# serverNames holds a single empty string, which is what makes the server accept
# a ClientHello carrying no server_name extension at all. shortIds holds an empty
# string so the client can leave sid blank.
INBOUND=$(jq -n \
  --arg tag  "$RS_TAG_INBOUND" \
  --argjson port "$XRAY_PORT" \
  --arg uuid "$UUID" \
  --arg priv "$PRIVATE_KEY" \
  --arg dest "127.0.0.1:$FALLBACK_PORT" \
  '{
     tag: $tag,
     listen: "0.0.0.0",
     port: $port,
     protocol: "vless",
     settings: {
       clients: [ { id: $uuid, flow: "xtls-rprx-vision" } ],
       decryption: "none"
     },
     streamSettings: {
       network: "tcp",
       security: "reality",
       realitySettings: {
         show: false,
         dest: $dest,
         xver: 0,
         serverNames: [""],
         privateKey: $priv,
         shortIds: [""]
       }
     },
     sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
   }') || die "could not build the inbound"

say "writing $XRAY_CONFIG"
mkdir -p "$(dirname "$XRAY_CONFIG")"
TMP_CONFIG=$(mktemp)
trap 'rm -f "$TMP_CONFIG"' EXIT

# Splice our inbound into whatever is already there instead of overwriting the
# file, so a box running other inbounds or custom routing keeps them.
if [ -f "$XRAY_CONFIG" ] && jq -e . "$XRAY_CONFIG" >/dev/null 2>&1; then
  cp -a "$XRAY_CONFIG" "$XRAY_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  # On a rerun, anything the operator tuned on this inbound by hand — a real
  # shortId, minClientVer, fallback limits, sniffing options — must survive.
  # jq's '*' merges recursively with the right side winning, so the existing
  # inbound wins field by field; only the invariants this installer owns are
  # then forced back into place.
  jq --argjson nb "$INBOUND" --arg t "$RS_TAG_INBOUND" --arg dest "127.0.0.1:$FALLBACK_PORT" '
        .log = (.log // { loglevel: "warning" })
      | .inbounds = (
          if ((.inbounds // []) | any(.tag == $t))
          then (.inbounds | map(
                  if .tag == $t
                  then ($nb * .)
                       | .streamSettings.security = "reality"
                       | .streamSettings.realitySettings.serverNames = [""]
                       | .streamSettings.realitySettings.dest = $dest
                  else . end))
          else ((.inbounds // []) + [$nb])
          end)
      | .outbounds = (if ((.outbounds // []) | length) > 0
                      then .outbounds
                      else [ { protocol: "freedom", tag: "direct" } ] end)
    ' "$XRAY_CONFIG" > "$TMP_CONFIG" || die "could not merge the inbound into $XRAY_CONFIG"
else
  jq -n --argjson nb "$INBOUND" '{
      log: { loglevel: "warning" },
      inbounds: [ $nb ],
      outbounds: [ { protocol: "freedom", tag: "direct" } ]
    }' > "$TMP_CONFIG" || die "could not build $XRAY_CONFIG"
fi

cat "$TMP_CONFIG" > "$XRAY_CONFIG"
xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || { xray run -test -config "$XRAY_CONFIG"; die "Xray rejected the generated config"; }
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || die "xray failed to start; see: journalctl -u xray -n 50"

# --------------------------------------------------------------- self-check

# Probe the public port the way a stranger would: no SNI, no credentials. REALITY
# should hand the connection to the decoy and return its certificate.
say "probing port $XRAY_PORT the way an outsider would"
PROBE=$(echo | openssl s_client -connect "127.0.0.1:$XRAY_PORT" -noservername 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' \n' || true)
case "$PROBE" in
  *"$SERVER_IP"*) say "the port answers with a certificate covering $SERVER_IP" ;;
  "")             warn "the probe returned nothing; check 'journalctl -u xray -n 50'" ;;
  *)              warn "the certificate on that port does not list $SERVER_IP — probing it will look wrong" ;;
esac

# --------------------------------------------------------------- output

LINK="vless://$UUID@$SERVER_IP:$XRAY_PORT?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&pbk=$PUBLIC_KEY&fp=chrome&sni=$SERVER_IP&sid=&spx=#$TAG"

umask 077
printf '%s\n' "$LINK" > "$OUT_DIR/link.txt"
jq -n --arg s "$SERVER_IP" --argjson p "$XRAY_PORT" --arg u "$UUID" --arg k "$PUBLIC_KEY" \
  '{ server: $s, server_port: $p, uuid: $u, flow: "xtls-rprx-vision",
     public_key: $k, short_id: "", server_name: $s, fingerprint: "chrome" }' \
  > "$OUT_DIR/client.json"

echo
printf '%s\n' "────────────────────────────────────────────────────────────────"
printf '%s%s%s\n' "$BLD" " VLESS share link" "$OFF"
printf '%s\n' "────────────────────────────────────────────────────────────────"
printf '%s\n' "$LINK"
printf '%s\n' "────────────────────────────────────────────────────────────────"
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 -m 1 "$LINK" || true
fi
cat <<EOF

Saved to $OUT_DIR/link.txt and $OUT_DIR/client.json

The sni field holds the server's own IP on purpose. RFC 6066 forbids IP literals
in the SNI extension, so Xray, sing-box and the apps built on them drop it
entirely and send a ClientHello with no server_name. Leaving sni empty does the
same. Do not put a domain there — the server accepts nothing else.

Certificate: Let's Encrypt shortlived profile, 160 hours, renewed by acme.sh
cron over TCP 80. Keep port 80 open and free, or the decoy certificate expires,
which is a louder signal than running no decoy at all.
EOF

#!/usr/bin/env bash
#
# Show what an active prober sees on a no-sni-reality port.
#
#   ./verify.sh <server-ip> [port]
#
# A healthy install answers both probes — one with no SNI, one with a bogus SNI
# — with the same Let's Encrypt certificate whose SAN is the server's own IP
# address, and with a plain web server behind it.
#
set -euo pipefail

HOST="${1:?usage: verify.sh <server-ip> [port]}"
PORT="${2:-443}"

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

python3 - "$HOST" "$PORT" <<'PY'
import ssl, socket, subprocess, sys

host, port = sys.argv[1], int(sys.argv[2])
ok = True

def probe(sni):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["http/1.1"])
    with socket.create_connection((host, port), timeout=10) as s:
        c = ctx.wrap_socket(s, **({"server_hostname": sni} if sni else {}))
        der = c.getpeercert(binary_form=True)
        print(f"--- sni={sni!r}  {c.version()}  {c.cipher()[0]}  alpn={c.selected_alpn_protocol()}")
        out = subprocess.run(
            ["openssl", "x509", "-inform", "DER", "-noout",
             "-issuer", "-dates", "-ext", "subjectAltName"],
            input=der, capture_output=True)
        text = out.stdout.decode().strip()
        print(text)
        c.send(b"GET / HTTP/1.1\r\nHost: " + host.encode() + b"\r\nConnection: close\r\n\r\n")
        print(c.recv(400).decode(errors="replace").split("\r\n\r\n")[0])
        c.close()
        return der, text

seen = []
for sni in (None, "www.example.com"):
    try:
        seen.append(probe(sni))
    except Exception as e:
        print(f"probe sni={sni!r} failed: {type(e).__name__}: {e}")
        ok = False
    print()

if len(seen) == 2 and seen[0][0] != seen[1][0]:
    print("MISMATCH: the port answered two different certificates")
    ok = False
if seen and host not in seen[0][1]:
    print(f"MISMATCH: the certificate does not list {host} in its SAN")
    ok = False

# The whole point is that a browser would trust this. Check it properly.
try:
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=10) as s:
        c = ctx.wrap_socket(s, server_hostname=host)
        print(f"trust chain: VALID for {host} ({c.version()})")
        c.close()
except Exception as e:
    print(f"trust chain: FAILED — {type(e).__name__}: {e}")
    ok = False

print()
print("OK" if ok else "PROBLEMS FOUND")
sys.exit(0 if ok else 1)
PY

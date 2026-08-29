# no-sni-reality

VLESS + XTLS-Vision + REALITY set up so the client sends **no SNI at all**, and
so anyone who probes the port finds an ordinary HTTPS server holding a
browser-trusted Let's Encrypt certificate issued for the server's bare IP
address.

No domain name is involved anywhere — not in the certificate, not in the share
link, not on the wire.

```
ssh root@YOUR_SERVER_IP 'curl -fsSL https://raw.githubusercontent.com/aliafshany/no-sni-reality/main/install.sh | bash'
```

That is the whole installation. It prints the `vless://` link and a QR code when
it finishes.

---

## Why this exists

Ordinary REALITY borrows someone else's domain. You pick a `dest` such as
`www.microsoft.com:443`, put that name in `serverNames`, and every client
announces `www.microsoft.com` in the SNI field of its ClientHello. That works,
but it leaves a name on the wire for a censor to read, match, and eventually
distrust — a residential IP claiming to be Microsoft is not a story that
survives much scrutiny.

This setup removes the name instead of borrowing one.

### How the SNI disappears

RFC 6066 §3 says a literal IP address is not permitted as an SNI `HostName`.
Go's `crypto/tls` implements that rule in `hostnameInSNI()`, which returns an
empty string for anything that parses as an IP. uTLS inherits the behaviour. So
when a client sets its `serverName` to an IP address, **the `server_name`
extension is not sent at all** — not sent empty, not sent with the IP in it,
simply absent.

Xray's own documentation states this directly:

> The client can also set this to any IP address. In that case Xray sends a
> Client Hello without an SNI extension. To use this feature, the server-side
> `serverNames` must contain an empty string `""`.

That is the entire client-side trick, and it works in every Go-based client:
Xray, sing-box, and the apps built on top of them.

### How the server accepts it

```json
"serverNames": [""],
"shortIds": [""]
```

An empty string in `serverNames` means *connections without SNI are accepted*.
An empty string in `shortIds` lets the client leave `sid` blank.

### What a prober sees

REALITY forwards any handshake it cannot authenticate to `dest`. Here `dest` is
a local nginx holding a real Let's Encrypt certificate for the server's own IP
address. So an active prober connecting to the port gets:

- a valid TLS 1.3 handshake,
- a certificate that a browser trusts, whose SAN is *this exact IP*,
- a plain web server behind it.

Nothing to compare against a real site, because it **is** the real site for that
address. There is no domain to blocklist and no SNI to match.

Let's Encrypt began issuing certificates for IP addresses under its `shortlived`
profile, generally available since January 2026. They are valid for 160 hours,
which is the one real operational cost of this design.

---

## Requirements

| Need | Why |
|------|-----|
| A VPS with a **public IPv4** | The certificate is issued to the address itself. Not usable behind NAT. |
| **TCP 80 free and reachable** | `http-01` is the only challenge Let's Encrypt runs against an IP identifier. `dns-01` cannot validate an IP, and `tls-alpn-01` would need the port REALITY is on. |
| One free TCP port for VLESS | 443 if you have it; the installer picks another if you don't. |
| systemd, and apt / dnf / yum | Debian, Ubuntu, RHEL and friends. |
| root | It installs services. |

---

## Step by step

### 1. Point a shell at the server

```
ssh root@YOUR_SERVER_IP
```

Confirm port 80 is free — this is the one precondition that matters:

```
ss -lnt | grep ':80 '
```

No output means you are fine. If a web server answers there, either stop it or
plan to serve the ACME challenge some other way; the certificate cannot be
issued or renewed without it.

### 2. Run the installer

From your laptop, in one command:

```
ssh root@YOUR_SERVER_IP 'curl -fsSL https://raw.githubusercontent.com/aliafshany/no-sni-reality/main/install.sh | bash'
```

It will:

1. detect the public IPv4 address,
2. install nginx, acme.sh, Xray-core and a few small tools,
3. pick a free TCP port (trying 443, 8443, 2083, 2087, 2096, 9443 in that order),
4. get a Let's Encrypt certificate for the bare IP using the `shortlived` profile,
5. serve that certificate from nginx on loopback as the REALITY decoy,
6. write and start the Xray inbound with `serverNames: [""]`,
7. print the `vless://` link and a QR code.

### 3. Import the link

Paste the link into any REALITY-capable client — v2rayNG, Hiddify, Streisand,
sing-box, Xray itself. Scan the QR code on a phone.

The `sni` field holds the server's own IP **on purpose**. Leaving it empty works
identically. Putting a domain there will break the connection, because the
server accepts nothing but a ClientHello with no `server_name`.

### 4. Check what strangers see

From your laptop, not the server:

```
git clone https://github.com/aliafshany/no-sni-reality.git
cd no-sni-reality
./verify.sh YOUR_SERVER_IP PORT
```

A healthy install answers both probes — one with no SNI, one with a bogus SNI —
with the same certificate, whose SAN is your IP, and reports `trust chain: VALID`.
Anything else means the decoy is not convincing and should be fixed before you
rely on it.

---

## Options

Set these before the pipe:

```
ssh root@YOUR_SERVER_IP 'PORT=2083 ACME_EMAIL=you@example.com curl -fsSL https://raw.githubusercontent.com/aliafshany/no-sni-reality/main/install.sh | bash'
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `PORT` | first free of 443, 8443, 2083, 2087, 2096, 9443 | public TCP port for VLESS |
| `FALLBACK_PORT` | 8444 | loopback port for the decoy nginx |
| `ACME_EMAIL` | none | registration address for Let's Encrypt |
| `SERVER_IP` | autodetected | skip public IP detection |
| `TAG` | `no-sni-reality` | label at the end of the share link |
| `FORCE` | unset | overwrite an unrelated existing Xray config |

Rerunning the installer is safe. It finds an existing install, keeps the same
UUID, key and port, and prints the same link back.

---

## Certificate renewal

This is the part that needs attention.

- Profile: `shortlived` — the only Let's Encrypt profile that accepts an IP
  address as an identifier.
- Lifetime: **160 hours**, about six and a half days.
- Renewal: `acme.sh` cron, with `--days 3` and the CA's ARI window.
- Reload: `systemctl reload nginx`, wired in as acme.sh's `reloadcmd`.

**Keep TCP 80 open and free.** If renewal stops working, the decoy starts
serving an expired certificate, and an expired certificate on a strange port is
a much louder signal than having no decoy at all.

Check the state any time:

```
/root/.acme.sh/acme.sh --list
```

---

## What gets installed where

| Path | What |
|------|------|
| `/usr/local/etc/xray/config.json` | the VLESS + REALITY inbound |
| `/etc/nginx/conf.d/no-sni-reality-acme.conf` | ACME challenge server on port 80 |
| `/etc/nginx/conf.d/no-sni-reality-decoy.conf` | the decoy site on loopback |
| `/etc/no-sni-reality/` | certificate and key |
| `/var/www/no-sni-reality/` | ACME webroot |
| `/root/no-sni-reality/link.txt` | the share link |
| `/root/no-sni-reality/client.json` | the same parameters as JSON |

Existing Xray configs are not overwritten unless you pass `FORCE=1`; the
installer backs up whatever it replaces.

---

## Honest limitations

**A no-SNI ClientHello is itself uncommon.** Very few real sites are reached by
IP with no name, so on a network that profiles TLS handshakes, absence of SNI is
a feature a censor could key on. The Xray authors say as much about this mode:
it exists, it works, and it is not something to deploy everywhere without
thinking. Borrowing a popular domain hides you in a larger crowd; removing the
name entirely puts you in a smaller, stranger one. Which is better depends
entirely on what your particular censor actually inspects — test, do not assume.

**The certificate is short-lived by design.** Six and a half days. Automation is
not optional here.

**IPv4 only, for now.** The certificate covers the address the installer
detects.

**This does not obfuscate traffic volume or timing.** REALITY defeats protocol
and certificate inspection. It does not make a long-lived high-throughput flow
look like casual browsing.

---

## References

- [REALITY configuration — Project X](https://xtls.github.io/en/config/transports/reality.html)
- [XTLS/REALITY](https://github.com/XTLS/REALITY)
- [Let's Encrypt: 6-day and IP address certificates are generally available](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)
- [Let's Encrypt certificate profiles](https://letsencrypt.org/docs/profiles/)
- [RFC 6066 §3 — Server Name Indication](https://datatracker.ietf.org/doc/html/rfc6066#section-3)

## License

MIT

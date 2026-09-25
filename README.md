# mosquitto-conf

TLS certificate issuance for a Mosquitto broker and a LoRaWAN gateway on the same LAN. Port layout follows
<https://test.mosquitto.org/ssl/>, with a local CA.

The gateway authenticates with a client certificate on `:8884`. No password: the
certificate CN becomes the MQTT username, and the ACL keys off it.

Broker configs are generated here and installed on the broker host separately —
`make deploy-help` prints the commands.

---

## Contents

| Path | What it is |
|---|---|
| `Makefile` | every certificate operation; `make help` lists targets |
| `openssl/ca.cnf` | CA policy, signing extensions, CRL settings |
| `openssl/leaf.cnf` | CSR template, shared by server and client |
| `mosquitto/mosquitto.conf` | top-level broker config |
| `mosquitto/conf.d/tls.conf` | the three listeners |
| `mosquitto/acl` | per-user topic rules |
| `LICENSE` | MIT |

Created on first run, not tracked:

| Path | What it is |
|---|---|
| `ca/` | `ca.crt`, `ca.key`, `ca.crl`, `index.txt`, `serial` |
| `certs/` | issued certificates |
| `private/` | private keys, mode 0600 |
| `dist/<CN>/` | 3-file bundles staged for gateway upload |

This is a template: it ships no CA and no certificates. `ca/` and `certs/` are
gitignored, since `ca/index.txt` is an inventory of gateways and renewal dates.
To version your own certificates, drop those two lines from `.gitignore` in your
fork — but never `ca/ca.key` or `private/`.

### Defaults

Override on the command line, e.g. `make server BROKER_IP=<your-broker-ip>`.

| Variable | Default |
|---|---|
| `BROKER_IP` | `192.168.178.90` |
| `CA_CN` | `Home LoRa CA` |
| `SAN` | `IP:$(BROKER_IP),DNS:mqtt.lan,DNS:localhost,IP:127.0.0.1` |
| `CA_DAYS` | `3650` |
| `LEAF_DAYS` | `365` |
| `KEY_BITS` | `2048` (RSA; embedded mbedTLS is unreliable with EC and 4096) |

---

## Usage

`BROKER_IP` must be the address the gateway dials. The `192.168.178.90` default
is a placeholder; substitute your own everywhere it appears below.

```bash
git clone <this-repo> && cd mosquitto-conf

make init                                    # create the CA — once per site
make server  BROKER_IP=<your-broker-ip>      # broker cert, SAN includes that IP
make client  CN=gw-01                        # one per gateway
make bundle  CN=gw-01                        # stage 3 files in dist/gw-01/
make verify  BROKER_IP=<your-broker-ip>      # chain, IP SAN, EKUs, revocation

# then edit mosquitto/acl to replace the placeholder gateway EUI
make deploy-help BROKER_IP=<your-broker-ip>
```

`make init` creates `ca/`, `certs/`, and `private/` if absent.

To stop repeating `BROKER_IP=`, edit the defaults at the top of the `Makefile`:

```make
BROKER_IP   ?= <your-broker-ip>
CA_CN       ?= <your-ca-name>
```


`make init` creates `ca/`, `certs/`, and `private/` if absent.

To stop repeating `BROKER_IP=`, edit the defaults at the top of the `Makefile`:

```make
BROKER_IP   ?= <your-broker-ip>
CA_CN       ?= <your-ca-name>
```

Ongoing operations:

```bash
make check-remote CN=gw-01   # live mTLS handshake against the broker
make revoke CN=gw-02         # revoke + regenerate CRL
make crl                     # regenerate CRL alone
make expiry                  # anything expiring within 30 days
make list                    # issued certs: V=valid R=revoked E=expired
make help-security           # ca.key hardening options
```

`make server` and `make client` are idempotent: reissuing reuses the existing
private key, so only the certificate changes. Reload with
`systemctl reload mosquitto` — Mosquitto 2.x re-reads certificates on SIGHUP
without dropping sessions.

`ca/ca.key` is unencrypted, mode 0600, gitignored. It is the only irrecoverable
secret here; whoever holds it can mint both gateway and broker certificates.
`make help-security` covers encrypting it or moving it offline.

---

## Listeners

| Port | TLS | Client cert | Auth | For |
|---|---|---|---|---|
| 1883 | no | no | — | bound to `127.0.0.1`. Delete if unused. |
| 8883 | yes | no | `password_file` | laptops, dashboards |
| 8884 | yes | **required** | cert CN as username | the UG65 |

`:8884` sets `require_certificate true` and `use_identity_as_username true`.

---

## Gateway setup

1. Set NTP first — see [Clock skew](#clock-skew).
2. Network Server → Application → *your app* → Data Transmission → MQTT.
   Configuration mode: **Manual Configuration**.
3. Broker Address: the `BROKER_IP` used above. Broker Port `8884`.
4. TLS → Enable, mode **Self signed certificates**. Upload the three files from
   `dist/gw-01/`. One certificate per file; no fullchain bundles, no PKCS#12.
   Accepts `.cer`/`.crt`/`.pem` for certs, `.key`/`.pem` for the key.
5. Leave User Credentials disabled. The certificate is the login.
6. Set a topic per Data Type.

### Topics

The UG65 has no hardcoded topics — set one per Data Type. The eight types
(UG65 user guide, Table 3-2-2-5):

| Data Type | Gateway |
|---|---|
| Uplink Data | publishes |
| Join Notification | publishes |
| ACK Notification | publishes |
| Error Notification | publishes |
| Response data | publishes (NS-API) |
| Downlink Data | subscribes |
| Multicast Downlink Data | subscribes |
| Request data | subscribes (NS-API) |

`mosquitto/acl` follows the convention in Milesight's Beaver IoT integration
(`MsGwMqttUtil.java` in
[Milesight-IoT/beaver-iot-integrations](https://github.com/Milesight-IoT/beaver-iot-integrations)):

```
milesight-gateway/<gatewayEUI>/{uplink,downlink,request,response}
```

Topics are arbitrary; they only have to match on both sides.

`$deveui` in a downlink topic is substituted by the gateway with the real device
EUI, e.g. `.../downlink/$deveui`. That occupies one topic level, so the ACL
matches it with `+`.

Downlink payload format — `data` base64, `fport` 85 for Milesight devices:

```json
{"confirmed": true, "fport": 85, "data": "CQEA/w=="}
```

Uplink JSON top-level keys: `applicationID`, `applicationName`, `data`, `devEUI`,
`deviceName`, `fCnt`, `fPort`, `time`, `rxInfo`, `txInfo`.

---

## What is likely to break

### Placeholder values

Two values are placeholders and must be changed:

- **`BROKER_IP`** — `192.168.178.90`. A wrong value means no IP SAN match, and
  the gateway rejects the broker. See [Missing IP SAN](#missing-ip-san).
- **Gateway EUI** in `mosquitto/acl` — `24e124fffef00000`. Real Milesight OUI
  (`24:E1:24`) with an all-zero device tail, so it cannot collide with hardware.
  Until replaced, the gateway connects and then has every publish denied, which
  reads as an auth failure but is an ACL mismatch.

The real EUI is under Status → Overview and on the device label. Replace every
occurrence in `mosquitto/acl` and use matching topics in the gateway UI.

### Clock skew

A wrong clock on the gateway produces `certificate is not yet valid` or an
endless "connecting" state with nothing useful logged. Certificate validity is
absolute time.

Set NTP on the gateway and confirm it took effect.

<img width="819" height="408" alt="image" src="https://github.com/user-attachments/assets/601f1a7c-3b25-47c4-9d03-7e948fa4b876" />


### Missing IP SAN

The gateway dials a raw IP, so `certs/server.crt` must carry that IP literally,
e.g. `IP:192.168.178.90`. SAN matching is textual and typed: a `DNS:mqtt.lan`
entry does not satisfy an IP connection even when `mqtt.lan` resolves to the
same address.

`make verify` checks this and exits non-zero if absent:

```
FAIL: IP:192.168.178.99 MISSING — gateway will reject
```

Changing the broker address requires reissuing: `make server BROKER_IP=<new>`.

### CN / ACL mismatch

The `CN=` passed to `make client` becomes the MQTT username and must equal the
`user` line in `mosquitto/acl` exactly. A mismatch authenticates fine, then
denies every publish — same symptom as the placeholder EUI.

### The `debug` user is disabled

`mosquitto/acl` carries a `debug` block, commented out:

```
#user debug
#topic readwrite #
```

That grants read/write on every topic including downlinks, so a certificate with
`CN=debug` can actuate hardware. Enable only while troubleshooting:

```bash
# uncomment both lines in mosquitto/acl, copy it across, then reload
make client CN=debug
mosquitto_sub -h <broker> -p 8884 --cafile ca/ca.crt \
  --cert certs/client-debug.crt --key private/client-debug.key -t '#' -v
```

Reverting:

```bash
make revoke CN=debug && make crl     # then copy ca.crl across and reload
```

Revocation only takes effect if `crlfile` is enabled.

### File permissions on the broker

* `server.key` must be mode 0600 owned `mosquitto:mosquitto`,

`make deploy-help` prints the correct `chown`/`chmod` for both.

* `mosquitto` in Docker expects both `certs` and `data` to be UID 1883

 `chown -R 1883 certs data`

### `crlfile` pointing at a missing file

`crlfile` is commented out in `conf.d/tls.conf`, because Mosquitto refuses to
start when it references a file that does not exist. Run `make crl`, copy
`ca/ca.crl` to the broker, then uncomment.

### TLS version is a minimum, not a pin

`tls_version tlsv1.2` sets a floor in Mosquitto 2.x; it was an exact pin in
1.6.x and earlier. With it set, a 1.3-capable client still negotiates 1.3, and a
1.2-only mbedTLS client negotiates 1.2. Its effect is to refuse anything below
1.2.

Setting a single `ciphers_tls1.3` ciphersuite does not force 1.2. It makes
1.3-capable clients fail the handshake with `alert handshake failure` instead of
falling back. A gateway that cannot talk to a 1.3-capable broker needs a
firmware update.

### `per_listener_settings`

`mosquitto.conf` sets `per_listener_settings true`, required when listeners use
different auth modes. It also changes how `acl_file` and `password_file` are
scoped; unset, authentication silently applies to the wrong listener.

### CRL scope

The broker enforces revocation against clients: a revoked gateway certificate is
refused at handshake with `alert certificate revoked`.

The reverse is unreliable — Milesight firmware frequently ignores CRLs, so a
revoked *broker* certificate may still be accepted by the gateway. That case
needs a CA rotation. One CA per site with 1-year leaves keeps the blast radius
small.

### `openssl verify` ignores CRLs

Plain `openssl verify` reports a revoked certificate as `OK`. It consults a CRL
only with `-crl_check` and the CRL concatenated onto the CA file. `make verify`
does this and reports `REVOKED` distinctly from `OK`.

---

## Symptom table

| Symptom | Cause | Fix |
|---|---|---|
| Connects, then every publish denied | placeholder EUI, or CN ≠ ACL `user` | fix `mosquitto/acl` |
| Stuck "connecting", nothing logged | clock skew | NTP on the gateway |
| `certificate is not yet valid` / `has expired` | clock skew | NTP on the gateway |
| `Hostname mismatch` / `IP address mismatch` | IP SAN absent | `make server`, `make verify` |
| Broker will not start, no log output | `server.key` perms | `chown mosquitto:mosquitto`, `chmod 600` |
| Broker will not start after enabling CRL | `crlfile` missing | `make crl`, copy across |
| `Warning: File ... world readable` | `acl_file` perms | `chmod 0700` |
| Broker rejects the client cert | no `clientAuth` EKU | `make client CN=...`, `make verify` |
| `alert certificate revoked` | cert was revoked | `make list`, issue a new one |
| `alert certificate required` | gateway sent no cert | check TLS mode, all 3 files uploaded |
| `alert handshake failure` from modern clients | `ciphers_tls1.3` over-restricted | remove that line |
| Auth applies to the wrong listener | `per_listener_settings` unset | set it `true` |

For silent failures, check in order: **clock, SAN, permissions.**

For more detail, uncomment `log_type all` in `mosquitto.conf`, or run
`mosquitto -c /etc/mosquitto/mosquitto.conf -v` in the foreground.

---

## Before this works

- Set `BROKER_IP`, then `make server && make verify`.
- Replace `24e124fffef00000` in `mosquitto/acl` with the real gateway EUI.
- Set `CA_CN` for your own CA name.
- Decide on `:8883`. If unwanted, delete its block from `conf.d/tls.conf` and the
  `backend` user from the ACL.

## License

MIT — see [LICENSE](LICENSE).

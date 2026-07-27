---
title: "Moving RAUC's HTTPS Streaming Key into TPM2 via PKCS#11"
date: 2026-04-23
draft: true
tags: ["rauc", "yocto", "tpm2", "pkcs11", "mtls", "iot-gateway", "ota", "debugging"]
slug: "rauc-streaming-key-tpm2-pkcs11"
summary: "Migrating RAUC's mTLS client key from a file on disk to a TPM2-backed PKCS#11 URI. The recipe wiring was straightforward; the URI was not. p11-kit and libp11 disagree on a single attribute, and RAUC routes through both."
---

<!--
SCAFFOLD NOTES (delete before publish):
- All sections drafted. Read end-to-end for tone before flipping draft: false.
- Date is 2026-04-23 (when the work happened). Change to publication date
  if you'd rather. Hugo sorts by frontmatter date, not commit date.
-->

RAUC HTTPS streaming with mTLS had been working on the
[rpi5-iot-gateway](https://github.com/umair-as/rpi5-iot-gateway) — a
Yocto-built Raspberry Pi 5 with a Thread border router, MQTT broker, and a
self-hosted RAUC OTA backend — since March, on file-based client keys:
`/etc/ota/device.key` on the rootfs, referenced from `system.conf`'s
`[streaming]` section, paired with a CA-signed `device.crt`. That stack was
good enough to get over-the-air installs running over a real WAN, but it left
the private key recoverable from any rootfs image — an SD card pulled from a
fielded device, a backup, a misplaced flash dump.

This post is the next step: moving that streaming key off the filesystem and
into the TPM2 via PKCS#11. The Yocto recipe wiring was straightforward — the
URI handed to RAUC's streaming subprocess was not.

## Why TPM-back the streaming key

A file-based `device.key` on the rootfs is recoverable from any image of that
rootfs — an SD card pulled from a fielded device, a debug image left on a
workbench, a backup blob in a build artifact. The recovered key is enough to
impersonate the gateway against the OTA backend indefinitely, and a CA
revocation only closes the window after the abuse is detected. Moving the key
into a TPM2 object accessed via PKCS#11 binds it to this physical device's
TPM: the same image read on a different machine yields a useless certificate.

This is the convergent pattern across embedded mTLS clients. AWS IoT Greengrass
v2, Azure IoT Edge, and Mender all support PKCS#11-backed TPM or HSM keys via
libp11 for the same reason. Anyone integrating that stack lands on the same
URI parser this post is about.

The honest limitation: a live device with the PIN file readable to its owner
process remains a signing oracle. A root-level runtime compromise can drive
the TPM to sign anything at request rate. This migration addresses
rootfs-at-rest, not runtime compromise — the full threat-model triage and
the CRA mapping land in the planned hardening series.

## The provisioning side, briefly

Before any of this matters at install time, three things have to be in place
on the device. First, a TPM2 PKCS#11 token store at `/var/lib/tpm2_pkcs11`,
initialised with `tpm2_ptool` and populated with the `rauc-client-key` keypair
generated inside the TPM. Second, the `ota` system user — created by an
`iotgw-ota-user` Yocto recipe (system account, group `ota`, no home,
`/bin/false` shell) — which is the `sandbox-user` RAUC drops the streaming
subprocess to. Third, the OTA material under `/etc/ota/`: `device.crt` and
`ca.crt` for mTLS, and `pkcs11-pin` (mode `0640 root:ota`) holding the PIN
that unlocks the PKCS#11 token at runtime.

A oneshot `ota-certs-provision` service handles all of this on every boot. It
sources cert material from the boot partition (factory provisioning), falls
back to `/data/ota/certs/` (persisted from prior provisioning), and then runs
a PKCS#11 preflight that opens the token, unlocks it with the PIN file, and
signs a probe message. If the preflight passes, RAUC has everything it needs
by the time the OTA service starts. The preflight is also where this post's
bug was hidden in plain sight — but that comes later.

## The four moving parts

The migration touches four things in the Yocto layer: a distro toggle
(`IOTGW_RAUC_STREAMING_KEY_MODE`) that selects `file` vs `pkcs11`; the
`rauc-conf` recipe template that substitutes the chosen `tls-key` value into
`system.conf`; a systemd drop-in that exports `PKCS11_MODULE_PATH` and
`TPM2_PKCS11_STORE` to the streaming subprocess; and the upstream RAUC meson
option `pkcs11_engine`, which has to be enabled so RAUC links libp11 as the
OpenSSL PKCS#11 engine.

The full wiring is at the bottom of this post. It is worth seeing the failure
first.

## First boot in PKCS#11 mode: `server not responding`

Day one of the new mode. The URI in `local.yml` looked like every TPM2 PKCS#11
example online — token, object, type, the module path, the PIN source:

```text
pkcs11:token=iotgw;object=rauc-client-key;type=private;module-path=/usr/lib/pkcs11/libtpm2_pkcs11.so;pin-source=file:/etc/ota/pkcs11-pin
```

A local-bundle install (`rauc install /tmp/foo.raucb`) worked. HTTPS streaming
from the same server, with the same bundle, failed every time. The top-level
error was `failed to configure streaming: server not responding`, which implied
a network or TLS connectivity problem.

It wasn't.

From `journalctl -u rauc -b` during `rauc install https://...`:

```text
Apr 23 05:36:45 iot-gateway rauc[1090]: Remote URI detected, streaming bundle...
Apr 23 05:36:45 iot-gateway rauc[1090]: sending config request to nbd server: {
    'key': <'pkcs11:token=iotgw;object=rauc-client-key;type=private;
             module-path=/usr/lib/pkcs11/libtpm2_pkcs11.so;
             pin-source=file:/etc/ota/pkcs11-pin'>, ...}
Apr 23 05:36:45 iot-gateway rauc[1193]: The private key ID is not a valid PKCS#11 URI
Apr 23 05:36:45 iot-gateway rauc[1193]: The PKCS#11 URI format is defined by RFC7512
Apr 23 05:36:45 iot-gateway rauc[1193]: The private key was not found at:
    pkcs11:token=iotgw;object=rauc-client-key;type=private;
    module-path=/usr/lib/pkcs11/libtpm2_pkcs11.so;pin-source=file:/etc/ota/pkcs11-pin
Apr 23 05:36:45 iot-gateway rauc[1193]: PKCS11_get_private_key returned NULL
Apr 23 05:36:45 iot-gateway rauc[1090]: Installation 7836ac74 failed:
    Failed to stream bundle: failed to configure streaming: server not responding
```

The `server not responding` line is RAUC's generic failure when the streaming
subprocess can't configure the connection. The actual failure is two lines
earlier in the subprocess output — key loading failed before any TLS handshake
started.

## Two PIDs, two error sources

The two PIDs in that log matter. `rauc[1090]` is the main RAUC daemon.
`rauc[1193]` is the NBD streaming subprocess it spawned. RAUC's HTTPS streaming
path runs in a separate sandboxed process that drops privileges to the user
named in `system.conf`'s `sandbox-user` — on this gateway, the dedicated `ota`
user (UID 997, GID 996). The subprocess inherits the environment of
`rauc.service`, which includes the `10-tpm2-pkcs11-store.conf` drop-in:

```text
Apr 23 06:14:43 iot-gateway rauc-nbd[1827]: nbd server running as UID 997, GID 996
```

Privilege drop worked. Module path environment was inherited. The failure was
in URI parsing, inside libp11, after the subprocess had everything it needed to
load the key.

The diagnostic point: the lines `The private key ID is not a valid PKCS#11 URI`
and `The PKCS#11 URI format is defined by RFC7512` come from libp11's URI
parser, not from RAUC. RAUC reports the top-level failure (`server not
responding`); libp11 reports the actual reason at the subprocess PID. If you
read only the daemon's output, you never see the reason.

## First fix attempt: RFC7512 query form

RFC7512 partitions PKCS#11 URI attributes into two groups: path attributes
(`token`, `object`, `type`, `id`, `slot`...) and query attributes (`pin-source`,
`pin-value`, `module-name`...). A reasonable first hypothesis was that placement
was the issue — `pin-source` and `module-path` are both query-shaped attributes,
and the URI as written had them mixed in with path attributes after a
semicolon, not after a `?`. So:

```text
pkcs11:token=iotgw;object=rauc-client-key;type=private?module-path=/usr/lib/pkcs11/libtpm2_pkcs11.so&pin-source=file:/etc/ota/pkcs11-pin
```

Same error. Same `not a valid PKCS#11 URI`. Placement wasn't the problem.

## Root cause: libp11 and p11-kit disagree on `module-path`

`module-path` is not part of RFC7512 at all. It is a p11-kit extension, defined
in p11-kit's URI documentation, that lets a URI itself name a PKCS#11 module
file when no module-loading framework is configured. p11-kit accepts it.
libp11 does not — it rejects URIs containing attributes it doesn't recognise,
with the exact error strings seen above.

libp11's accepted attribute set is the RFC7512 standard query attributes
(`pin-source` and `pin-value` are both defined there, in §2.4). `module-path`
is not. RAUC's streaming subprocess loads the key via OpenSSL's ENGINE
interface with libp11 as the engine, so the strict parser is the one that
runs at install time.

The kicker: with `PKCS11_MODULE_PATH` already exported in
`rauc.service.d/10-tpm2-pkcs11-store.conf`, libp11 already knows which module
to load. `module-path` in the URI was both unsupported by the parser and
redundant given the environment.

## The fix

Strip `module-path` from the URI. Use only standard RFC7512 attributes plus
`pin-source`:

```text
tls-key=pkcs11:token=iotgw;object=rauc-client-key;type=private;pin-source=file:/etc/ota/pkcs11-pin
```

From the validated run:

```text
Apr 23 06:14:43 iot-gateway rauc-nbd[1827]: nbd server running as UID 997, GID 996
Apr 23 06:14:43 iot-gateway rauc-nbd[1827]: nbd server received configuration: {
    'key': <'pkcs11:token=iotgw;object=rauc-client-key;type=private;
             pin-source=file:/etc/ota/pkcs11-pin'>, ...}
Apr 23 06:14:43 iot-gateway rauc-nbd[1827]: nbd server received total size 555044310
Apr 23 06:18:25 iot-gateway rauc[1813]: Installation 87af83d1 succeeded
```

No key loading errors. The NBD subprocess opened the TPM2-backed key,
established the mTLS connection, and the install completed. `pin-source=file:`
reads the PIN from `/etc/ota/pkcs11-pin` at runtime — the PIN does not appear
in `system.conf`, in environment variables, or in the journal.

## The diagnostic gap

The PKCS#11 preflight check that runs as part of OTA provisioning passed
cleanly with the broken URI:

```text
Apr 23 05:31:08 iot-gateway ota-certs[575]: [INFO] PKCS#11 preflight passed
    for token='iotgw' key='rauc-client-key'
```

It was never going to catch this, and the reason is worth sitting with. The
preflight signs a probe with `pkcs11-tool`, addressing the key by token and
object label with the module passed explicitly:

```bash
pkcs11-tool --module /usr/lib/pkcs11/libtpm2_pkcs11.so \
    --token-label iotgw --login --pin "$pin" \
    --label rauc-client-key --sign --mechanism RSA-PKCS ...
```

That proves the key exists, the PIN unlocks it, and the TPM will sign. What it
never touches is the streaming URI. `module-path` lives only in that URI, and
the URI is parsed by exactly one thing: libp11, inside RAUC's streaming
subprocess, at install time. **A passing preflight gives no signal about
whether the streaming path can load the same key** — not because two parsers
disagree, but because only one of them ever sees the string that's broken. The
install wrapper doesn't close the gap either: its connectivity preflight skips
the key check entirely for a `pkcs11:` `tls-key`, deferring to RAUC.

The fix has two shapes: validate the URI against the actual streaming consumer
at provisioning time, or refuse to emit URIs the streaming consumer can't
parse. The recipe-level guard below does the second — cheaper, and it catches
the bug at build time instead of first-boot.

## How it's wired in the layer

The toggle and the URI live in the distro include
(`meta-iot-gateway/conf/distro/include/iotgw-common.inc`):

```bash
IOTGW_RAUC_STREAMING_KEY_MODE ?= "file"
IOTGW_RAUC_PKCS11_BACKEND ?= "tpm2"
IOTGW_RAUC_PKCS11_TLS_KEY ?= ""
IOTGW_RAUC_PKCS11_MODULE ?= "/usr/lib/pkcs11/libtpm2_pkcs11.so"
IOTGW_TPM2_PKCS11_STORE ?= "/var/lib/tpm2_pkcs11"
```

The `rauc-conf` recipe selects between `device.key` and the PKCS#11 URI based
on the mode, then substitutes into the `system.conf` template:

```bash
IOTGW_RAUC_STREAMING_TLS_KEY = "${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE', 'pkcs11', d.getVar('IOTGW_RAUC_PKCS11_TLS_KEY') or '', '/etc/ota/device.key', d)}"

# ...
sed -e "s|@TLS_KEY@|${IOTGW_RAUC_STREAMING_TLS_KEY}|g" \
    ${WORKDIR}/iotgw-system.conf > ${D}${sysconfdir}/rauc/system.conf
```

The template is otherwise identical between modes:

```ini
[streaming]
sandbox-user=ota
tls-cert=/etc/ota/device.crt
tls-key=@TLS_KEY@
tls-ca=/etc/ota/ca.crt
```

In `pkcs11` mode, `@TLS_KEY@` becomes a PKCS#11 URI. In `file` mode, it stays
`/etc/ota/device.key`.

The `rauc_%.bbappend` installs a systemd drop-in under
`/etc/systemd/system/rauc.service.d/10-tpm2-pkcs11-store.conf` only when
`IOTGW_RAUC_PKCS11_USES_TPM2 = "1"`:

```ini
[Service]
Environment=TPM2_PKCS11_STORE=@IOTGW_TPM2_PKCS11_STORE@
Environment=PKCS11_MODULE_PATH=@IOTGW_RAUC_PKCS11_MODULE@
```

`PKCS11_MODULE_PATH` is what libp11 reads at runtime to load
`libtpm2_pkcs11.so`. It is also what makes `module-path` redundant in the URI
— set it here, and the parser never needs to be told which module to use.

The same bbappend handles the upstream meson option. RAUC's `rauc.inc`
defaults `pkcs11_engine` to true on 1.15.x; the bbappend explicitly disables
it when the streaming key is file-based, to avoid pulling libp11 into builds
that don't use PKCS#11:

```bash
EXTRA_OEMESON:append = "${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE', 'pkcs11', '', ' -Dpkcs11_engine=false', d)}"

RDEPENDS:${PN}-service:append = "${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE', 'pkcs11', ' openssl-engines libp11', '', d)}"
```

In PKCS#11 mode, RAUC links against `openssl-engines` and `libp11`. In file
mode, neither package is in the image.

The build-time guard sits in `rauc-conf-iotgw_1.0.bb`. It refuses to render
`system.conf` if the URI contains `module-path=`, or if it lacks both
`pin-source` and `pin-value`:

```bash
do_install() {
    if [ "${IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE}" = "pkcs11" ] && \
       [ "${IOTGW_RAUC_PKCS11_USES_TPM2}" = "1" ]; then
        case "${IOTGW_RAUC_STREAMING_TLS_KEY}" in
            *"module-path="*)
                echo "ERROR: TPM2 PKCS#11 streaming key URI must not include module-path when PKCS11_MODULE_PATH service env is used." >&2
                echo "       Current: ${IOTGW_RAUC_STREAMING_TLS_KEY}" >&2
                exit 1
                ;;
        esac
        case "${IOTGW_RAUC_STREAMING_TLS_KEY}" in
            *"pin-source=file:/etc/ota/pkcs11-pin"*|*"pin-value="*) ;;
            *)
                echo "ERROR: TPM2 PKCS#11 streaming key URI must include pin-source=file:/etc/ota/pkcs11-pin (preferred) or pin-value=<PIN>." >&2
                exit 1
                ;;
        esac
    fi
    # ... sed substitution into system.conf
}
```

Around 15 lines, and it catches the only failure mode in this stack that has
no clean runtime fallback.

The migration shipped in
[PR #49](https://github.com/umair-as/rpi5-iot-gateway/pull/49) — "ota/rauc: gated
PKCS#11+crypt OTA flow with TPM2 streaming fix". The PKCS#11 path is opt-in;
file-key streaming remains the default. To switch a build to TPM2-backed
streaming:

```yaml
# kas/local.yml
local_conf_header:
  iotgw: |
    IOTGW_RAUC_STREAMING_KEY_MODE = "pkcs11"
    IOTGW_RAUC_PKCS11_BACKEND = "tpm2"
    IOTGW_RAUC_PKCS11_TLS_KEY = "pkcs11:token=iotgw;object=rauc-client-key;type=private;pin-source=file:/etc/ota/pkcs11-pin"
```

Anything else in that URI (notably `module-path=`) fails the recipe.

## A wider lesson on daemons and subprocesses

When a daemon spawns a sandboxed subprocess and the subprocess fails, the
daemon's top-level error is often a generic timeout. RAUC reports
`server not responding` whether the failure was a real network problem, a TLS
handshake error, a sandbox setup failure, or — as here — a parse error in a
URI the subprocess never got to use. The first place to look in
`journalctl -u <unit>` is not the line with the word `failed`; it is the
highest PID in the same time window. The shortest-lived process is usually
the one that actually broke.

---

> **Update (v0.5.0, July 2026).** This was the layout as of April 2026. The
> TPM2 PKCS#11 token store has since moved from `/var/lib/tpm2_pkcs11` to
> `/data/tpm2_pkcs11`, so the OTA identity survives the switch to a volatile
> `/var` and persists across A/B updates. The URI, the module path, and the
> `module-path`/`pin-source` handling are unchanged.

## References

- [RAUC — Streaming Bundles](https://rauc.readthedocs.io/en/latest/advanced.html#streaming-bundles) — `[streaming]` configuration, the NBD subprocess model
- [RAUC — PKCS#11 Support](https://rauc.readthedocs.io/en/latest/advanced.html#pkcs11-support)
- [RFC 7512 — The PKCS#11 URI Scheme](https://datatracker.ietf.org/doc/html/rfc7512) — defines the standard attribute set; `pin-source` and `pin-value` are in §2.4
- [libp11 — engine_pkcs11](https://github.com/OpenSC/libp11/blob/master/src/eng_back.c) — the URI parser used by OpenSSL's ENGINE backend
- [p11-kit URI specification](https://p11-glue.github.io/p11-glue/p11-kit/manual/p11-kit-uris.html) — defines `module-path` as a p11-kit extension, not RFC7512
- [tpm2-pkcs11](https://github.com/tpm2-software/tpm2-pkcs11) — TPM2 PKCS#11 module
- [AWS IoT Greengrass v2 — Hardware security integration](https://docs.aws.amazon.com/greengrass/v2/developerguide/hardware-security.html) — equivalent PKCS#11 plugin pattern in a different stack
- [PR #49 in rpi5-iot-gateway](https://github.com/umair-as/rpi5-iot-gateway/pull/49) — gated PKCS#11+crypt OTA flow with the TPM2 streaming fix and recipe guard

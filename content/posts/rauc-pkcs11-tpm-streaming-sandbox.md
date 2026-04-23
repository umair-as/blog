---
title: "RAUC Streaming OTA with TPM-Backed PKCS#11: What `Unable to load module (null)` Actually Means"
date: 2026-04-21
draft: true
tags: ["rauc", "ota", "pkcs11", "tpm", "tpm2-pkcs11", "systemd", "security", "embedded-linux", "yocto"]
slug: "rauc-pkcs11-tpm-streaming-sandbox"
series: ["IoT Gateway OS"]
summary: "Switching RAUC's streaming mTLS client key from a file path to a PKCS#11 URI produced a one-line error with no obvious cause. The real problem was not the module path, not the engine, and not a missing PIN — it was the sandbox user's group membership and what tpm2-pkcs11 needs to initialise."
---

The streaming OTA setup had been working for months: RAUC's `rauc-nbd` subprocess
authenticates to the bundle server over mTLS, streams the bundle directly into the
inactive slot, and hands off to RAUC for signature verification and slot activation.
The TLS client key lived at `/etc/ota/device.key`, file permissions handled access,
and `sandbox-user=ota` in `system.conf` kept the streaming helper running as a
dedicated system user with no shell, no home directory, and minimal privileges.

Moving that key into the TPM was the next step — store the private key in a TPM2
key object on the SLB9672 via tpm2-pkcs11, and reference it through a PKCS#11 URI
instead of a file path. One line in `system.conf` changed:

```ini
[streaming]
sandbox-user=ota
tls-cert=/etc/ota/device.crt
tls-key=pkcs11:token=iotgw;object=rauc-client-key;type=private
tls-ca=/etc/ota/ca.crt
```

Same bundle, same server, same network. The install failed on the first attempt:

```text
Apr 21 12:26:33 iot-gateway rauc-nbd[1887]: nbd server running as UID 985, GID 984
Apr 21 12:26:33 iot-gateway rauc-nbd[1887]: nbd server configuring for URL: https://192.168.0.193:8443/bundles/iot-gw-image-dev-bundle-full-fit.raucb
Apr 21 12:26:33 iot-gateway rauc[1887]: Unable to load module (null)
Apr 21 12:26:33 iot-gateway rauc[1887]: PKCS11_get_private_key returned NULL
Apr 21 12:26:33 iot-gateway rauc-nbd[1887]: request failed: failed to load private key from crypto engine (retrying 1/5)
```

Five retries, identical output each time. The parent process gave up:

```text
Apr 21 12:26:38 iot-gateway rauc[632]: Installation 348ed464 failed: Failed to stream bundle \
  https://192.168.0.193:8443/bundles/iot-gw-image-dev-bundle-full-fit.raucb: \
  failed to configure streaming: server not responding
```

## The first wrong read

`Unable to load module (null)` is from libp11, the OpenSSL engine RAUC uses for
PKCS#11 operations. When libp11 gets a null module path, the engine never opened a
token or attempted a key lookup — no `CKR_*` error, no PIN prompt, no
token-not-found. The PKCS#11 module itself didn't load.

The setup already had a drop-in for `rauc.service`:

```ini
[Service]
Environment=RAUC_PKCS11_MODULE=/usr/lib/pkcs11/libtpm2_pkcs11.so
```

The RAUC docs describe `RAUC_PKCS11_MODULE` as the fallback for systems where p11-kit
is not available. The error looked like a module discovery failure, so that env var
was the obvious first place to look. I removed the drop-in, restarted rauc, ran the
install again. Same PID, same `(null)`, same five retries.

That killed the env var hypothesis. This system had p11-kit installed with tpm2_pkcs11
registered in its module config — so libp11 was going through p11-kit for discovery
and never reading `RAUC_PKCS11_MODULE` at all. The drop-in had been doing nothing from
the start.

## What the sandbox user actually sees

If p11-kit is involved and libp11 still gets null back, p11-kit is loading the module
but getting nothing usable from it. The right move was to reproduce exactly what
`rauc-nbd` does: run p11-kit as the `ota` user and watch what happens.

```console
$ su -s /bin/sh ota -c 'p11-kit list-modules 2>&1'
```

```text
ERROR: Could not mkdir "/nonexistent/.tpm2_pkcs11", error: No such file or directory
ERROR: Cannot open database: unable to open database file

WARNING: ESYSDB backend was not initialized.
WARNING: Getting tokens from fapi backend failed.
ERROR:tcti:tcti-device.c:454:Tss2_Tcti_Device_Init() Failed to open specified TCTI device file /dev/tpmrm0: Permission denied
ERROR:tcti:tctildr-dl.c:169:tcti_from_file() Could not initialize TCTI file: libtss2-tcti-device.so.0
ERROR:tcti:tcti-device.c:454:Tss2_Tcti_Device_Init() Failed to open specified TCTI device file /dev/tpm0: Permission denied
ERROR:tcti:tctildr-dl.c:169:tcti_from_file() Could not initialize TCTI file: libtss2-tcti-device.so.0
ERROR:tcti:tctildr-dl.c:269:tctildr_get_default() No standard TCTI could be loaded
ERROR:tcti:tctildr.c:430:Tss2_TctiLdr_Initialize_Ex() Failed to instantiate TCTI
ERROR: Could not initialize tpm ctx: 0x5
```

Two independent failures, both happening before the module produces anything usable.

**No TPM device access.** tpm2-tss — the library tpm2-pkcs11 uses to talk to the
hardware — tries device nodes in a fixed order: `/dev/tpmrm0` (the resource manager,
preferred for all userspace use), then `/dev/tpm0` (direct access), then a software
TPM socket on `127.0.0.1:2321`. Their permissions on this system:

```text
crw-rw---- 1 root iotgwtpm 251, 65536 Apr 21 12:19 /dev/tpmrm0
crw------- 1 root root      10,   224 Apr 21 12:19 /dev/tpm0
```

`/dev/tpmrm0` requires membership in `iotgwtpm`. `/dev/tpm0` is root-only. The
software TPM isn't running. The `ota` user's actual group membership:

```text
uid=985(ota) gid=984(ota) groups=984(ota)
```

Not in `iotgwtpm`. Never had been. tpm2-tss exhausts all three paths, fails to open
any device, and returns an error. The PKCS#11 module cannot reach the hardware.

**No database path.** tpm2-pkcs11 maintains a SQLite database of provisioned tokens
and key objects. Without a `TPM2_PKCS11_STORE` environment variable pointing elsewhere,
it defaults to `~/.tpm2_pkcs11/`. The `ota` user in `/etc/passwd`:

```text
ota:x:985:984:OTA Update Daemon:/nonexistent:/bin/false
```

Home is `/nonexistent` — the standard placeholder for system users created with
`--no-create-home`. The directory does not exist and is never created. tpm2-pkcs11
attempts to mkdir `~/.tpm2_pkcs11/` inside it, fails immediately, and exits without
an open store.

Either failure alone would have been fatal. Together, they leave the module unable to
talk to the hardware and with nowhere to load token metadata from. p11-kit loads
`libtpm2_pkcs11.so` successfully, but the module's initialisation fails silently and
returns no slots, no tokens, no usable state. libp11 receives nothing and reports
`Unable to load module (null)` — not because the shared library is missing, but
because the module initialised into an empty, broken state and returned null.

## Why this was invisible with the file key

The two access paths look like this side by side:

```text
# file key
rauc (root) → rauc-nbd (ota, UID 985) → open /etc/ota/device.key

# PKCS#11 key
rauc (root) → rauc-nbd (ota, UID 985) → p11-kit → tpm2_pkcs11 → /dev/tpmrm0
                                                              → ~/.tpm2_pkcs11/store.db
```

For the file key, the sandbox user needed read permission on one file — and it had
that. The sandboxing was correct and working. Switching to PKCS#11 silently expanded
the access requirements: a device node gated by group membership, a writable path for
library-managed state. Neither was wired to the `ota` user because when the file key
was the only option, neither was needed. The sandbox didn't break — the new key
backend's prerequisites were just never accounted for.

## The fix

Two changes in the Yocto layer, each closing one of the two failures.

**Add `ota` to the `iotgwtpm` supplementary group in `ota-updater_1.0.0.bb`:**

```bitbake
USERADD_PARAM:${PN} = " \
    --system \
    --home /nonexistent \
    --no-create-home \
    --shell /bin/false \
    --gid ota \
    --groups iotgwtpm \
    ota"
```

`iotgwtpm` is created by the `iotgw-tpm-policy` recipe specifically to gate access to
`/dev/tpmrm0`. Adding `ota` gives tpm2-tss a device node it can open, which unblocks
the TCTI initialisation chain.

**Redirect the token database in the `rauc.service` drop-in:**

```ini
[Service]
Environment=TPM2_PKCS11_STORE=/var/lib/tpm2_pkcs11
```

`TPM2_PKCS11_STORE` overrides the default `~/.tpm2_pkcs11/` path. `/var/lib/tpm2_pkcs11`
is a system-owned directory that exists and is accessible to the service user. The
token and key object still need to be provisioned there using `tpm2_ptool` — but that
is a one-time setup step, not a permissions problem. With both access issues resolved,
the module initialises cleanly and the error from rauc shifts from
`Unable to load module (null)` to a token lookup failure: a different error, a
solvable one, and proof that the module is now working.

The `RAUC_PKCS11_MODULE` line is gone from the drop-in. With p11-kit present and the
module registered, libp11 never consults it.

## The one-line documentation gap

The RAUC docs have one sentence covering this:

> When using TLS client certificates, you need to ensure that the key (or PKCS#11
> token) is accessible to the streaming sandbox user.

For a file key, "accessible" means read permission on one file. For a TPM-backed
PKCS#11 token it means: membership in the group that gates the TPM device node,
a reachable path for the PKCS#11 library's token database, and a provisioned token
with the key object present. The surface area is significantly larger, and none of it
appears in the error output when something is missing — just a null module pointer
and a generic load failure, with no pointer to which prerequisite was not met.

---
title: "Wrapping rauc install in systemd-run for Consistent Sandboxing"
date: 2026-04-15
draft: true
tags: ["rauc", "ota", "systemd", "security", "embedded-linux", "yocto"]
slug: "rauc-install-systemd-hardening"
summary: "rauc install runs from SSH sessions, serial consoles, and cloud agents — each with different privilege and namespace semantics. Wrapping it in a systemd-run transient unit makes the sandbox explicit and reproducible. This is what that wrapper looks like, what each property does, and where it broke."
---

`rauc install` is conceptually a single operation: verify a bundle, write it to the
inactive slot, mark it bootable. In practice, it gets invoked from at least four different
contexts: an operator SSH session, a serial console, a systemd service triggered by a cloud
agent, and a CI pipeline during factory provisioning. Each of those contexts carries different
privilege assumptions, namespace state, and signal-handling semantics.

The cleanest way to normalise all of them is to re-exec the install through a
`systemd-run` transient unit with explicit properties. The wrapper script does exactly that,
then handles two things `rauc install` doesn't: preflight connectivity checks and `/boot`
remounting when U-Boot env lives there.

## The dispatch pattern

The wrapper re-execs itself:

```bash
unit="iotgw-rauc-install-${RUN_ID}"
reexec=(/usr/sbin/iotgw-rauc-install --direct "${BUNDLE_INPUT}")

systemd-run --quiet --wait --collect --pipe \
    --unit "${unit}" \
    --property=NoNewPrivileges=yes \
    --property=PrivateTmp=yes \
    --property=PrivateMounts=no \
    --property=ProtectSystem=full \
    --property=ProtectHome=yes \
    --property=ProtectKernelTunables=yes \
    --property=ProtectKernelModules=yes \
    --property=ProtectKernelLogs=yes \
    --property=ProtectControlGroups=yes \
    --property=RestrictNamespaces=yes \
    --property=RestrictSUIDSGID=yes \
    --property=LockPersonality=yes \
    --property=MemoryDenyWriteExecute=yes \
    --property=PrivateUsers=no \
    "--property=RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" \
    --property=ReadWritePaths=/run \
    "${reexec[@]}"
```

`--direct` is an internal flag the script uses to detect it is in the inner execution
and skip the dispatch a second time. `--wait --collect --pipe` means the outer process
blocks until the transient unit exits, inherits its exit code, and the unit is
automatically removed from the journal index on completion.

## What each property is doing and why

**`NoNewPrivileges=yes`** — the process cannot gain additional capabilities through
`setuid`/`setgid` or filesystem capabilities after exec. This has no effect on an install
that already runs as root, but it closes the path if the binary or a dependency ever
acquires a setuid bit.

**`PrivateTmp=yes`** — the unit gets its own `/tmp` and `/var/tmp` mount. RAUC
unpacks bundle metadata into a tmpfs under `/run/rauc/`, not `/tmp`, so this doesn't
interfere. It prevents a compromised bundle hook from poisoning a shared `/tmp` that
another process reads.

**`PrivateMounts=no`** — this one must be `no`. `PrivateMounts=yes` gives the unit a
private mount namespace. RAUC communicates slot mount/unmount operations via D-Bus to the
`rauc.service` daemon, which does the actual mounting in the system's real mount namespace.
If the client runs in a private namespace, `findmnt` inside the wrapper sees a diverged
namespace and the boot partition detection logic breaks. This was not obvious until
the `/boot` remount path failed silently during a U-Boot env write.

**`ProtectSystem=full`** — `/usr`, `/boot`, and `/etc` are mounted read-only for the
unit. The install doesn't write to any of those directly (RAUC writes to block devices
via the daemon), so this is safe. The exception for `/boot` is handled separately below.

**`ReadWritePaths=/run`** — `ProtectSystem=full` makes everything read-only by default.
`/run` needs to be writable because the D-Bus socket lives at
`/run/dbus/system_bus_socket` and RAUC's own socket is at `/run/rauc/`. Without this,
the D-Bus call to the RAUC daemon fails before the install starts.

When the U-Boot environment lives on a partition mounted at `/boot` (detected by
checking `/etc/fw_env.config`), an additional `ReadWritePaths=/boot` is added:

```bash
rw_props=(--property=ReadWritePaths=/run)
[ "${BOOT_RW_REQUIRED}" -eq 1 ] && rw_props+=(--property=ReadWritePaths="${BOOT_MP}")
```

**`ProtectKernelTunables=yes`, `ProtectKernelModules=yes`, `ProtectKernelLogs=yes`,
`ProtectControlGroups=yes`** — standard hardening. An OTA install has no business
writing `/proc/sys`, loading kernel modules, reading `/dev/kmsg`, or modifying the
cgroup tree. These block all four.

**`RestrictNamespaces=yes`** — prevents the unit from creating new namespaces with
`unshare(2)`. A bundle hook that tried to create a user namespace to escape other
constraints would fail here.

**`RestrictSUIDSGID=yes`** — setuid and setgid bits on newly created files are
silently stripped. Combined with `NoNewPrivileges`, this ensures nothing the install
writes can be used for privilege escalation post-install.

**`LockPersonality=yes`** — blocks `personality(2)`. Prevents a hook from switching
the kernel execution domain (e.g. switching to `PER_LINUX32` on a 64-bit system).

**`MemoryDenyWriteExecute=yes`** — blocks creation of memory regions that are both
writable and executable. JIT compilers and certain OpenSSL configurations require this
and will fail under it. For an OTA install and its hooks — shell scripts invoking
standard system tools — this is safe. More on this below.

**`PrivateUsers=no`** — explicitly `no`. `PrivateUsers=yes` sets up a user namespace
where the root user inside maps to a less-privileged UID outside. RAUC's slot
operations check file ownership on mounted filesystems. With a user namespace, those
ownership checks see the wrong UIDs and the post-install slot marking fails.

**`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`** — only Unix domain sockets
(D-Bus, RAUC socket), IPv4, and IPv6 are permitted. `AF_NETLINK` and `AF_PACKET` are
blocked; the install has no need for raw socket access.

## Signal handling

This is the non-obvious part. If an operator hits Ctrl-C while the install is running,
the natural instinct is to kill the process. That kills the `systemd-run` client. It does
not kill the `rauc.service` daemon, which continues writing to the slot in the background.

The correct sequence is:

```bash
trap '
    busctl call de.pengutronix.rauc / \
        de.pengutronix.rauc.Installer Cancel 2>/dev/null || true
    systemctl stop "${unit}" 2>/dev/null || true
    exit 130
' INT TERM
```

Call the RAUC D-Bus `Cancel` method first to abort the daemon's install, then stop the
transient unit. If `Cancel` is omitted, the slot gets a partially written image and RAUC
marks the slot bad on next boot — which is the right behavior, but it's better to abort
cleanly than to corrupt-and-recover.

## Where it broke

During testing against a fresh build, the wrapper's preflight connectivity check failed
with `curl_rc=2` — `CURLE_FAILED_INIT`. The preflight runs before the `systemd-run`
dispatch (so `MemoryDenyWriteExecute` is not yet in effect), and it still failed with
`--no-systemd-run` as well:

```
Preflight  192.168.0.193:8443
  ✓  OTA certificates
  ✗  Server  192.168.0.193:8443    curl_rc=2

Error: server not reachable: 192.168.0.193:8443
```

Direct `rauc install` worked immediately:

```
root@iot-gateway:~# rauc install "https://192.168.0.193:8443/bundles/iot-gw-image-dev-bundle-full-fit.raucb"
installing
  0% Installing
  ...
 46% Copying image to rootfs.1
```

The install completed cleanly and rootfs.1 is now marked activated. The preflight curl
and RAUC's native HTTPS streaming are not identical in capability: RAUC links directly
against its TLS library and reads key material from the `[streaming]` section of
`system.conf` natively, including hardware-backed keys. The preflight curl in the wrapper
reads the same `system.conf` values and reconstructs a `curl` invocation — but that
reconstruction may not cover all key URI schemes that RAUC handles internally. On the
`feat/tpm-crypto-providers-gate` branch, this gap is the current suspect for the failure.

The short-term fix is to skip the preflight or run it differently. The right fix is to
make the preflight and the install path use the same key access mechanism, which means
either using RAUC's `--check` mode (if that gets added upstream) or reproducing the key
access in the wrapper correctly for every scheme it needs to support.

## The score

With those properties set, `systemd-analyze security iotgw-rauc-install-<unit>` for a
running transient unit comes in well below the 4.0 threshold that marks a meaningfully
hardened unit. The remaining exposure is the kernel call surface — `SystemCallFilter` is
not applied because the full set of syscalls needed by `rauc install`, its hooks, and the
tools they invoke is wide enough that a static allowlist would break on the first hook
that calls something unexpected. That's a tradeoff worth naming rather than papering over
with a `SystemCallFilter=@system-service` that looks good in the score but silently
permits too much.

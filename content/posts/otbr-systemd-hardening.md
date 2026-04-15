---
title: "Hardening the OTBR Service File: Reading systemd-analyze Security"
date: 2026-04-14
draft: false
tags: ["otbr", "openthread", "linux", "systemd", "security", "yocto", "cra"]
slug: "otbr-systemd-hardening"
series: ["Hardening OTBR"]
summary: "Part 1 got OTBR running as a non-root user with three capabilities. Part 2 covers the hardening block in the service file — what each directive does, why one had to be an exception, and how to use systemd-analyze security as a decision tool rather than a score to chase. Part 2 of 2."
---

[Part 1](/blog/posts/running-otbr-as-non-root/) ended with `otbr-agent` running as a dedicated system user with three network capabilities and a `systemd-analyze security` score of `4.1 OK`. The service unit carried a hardening block we didn't explain:

```
root@iot-gateway:~# systemctl cat otbr-agent | grep -A20 "# Capabilities"
# Capabilities and hardening
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=false
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
```


This post walks through each directive: what it does, what it restricts, and where the tradeoffs are for a border router specifically. One — `PrivateDevices` — had to be set to `false`. The others held.

> **Setup note:** Validated on a Yocto-built image on a Raspberry Pi 5 (systemd 255, Linux 6.18). Kernel version, systemd version, and how your dependencies are built all affect which directives are safe to enable. The drop-in test pattern used throughout — write a `/run/systemd/system/<service>.d/test.conf`, `daemon-reload`, restart, verify — is how to check any directive on your own system before committing it.

## What systemd-analyze security actually measures

Before walking the directives, it helps to understand what the tool is actually scoring.

`systemd-analyze security <service>` evaluates the service unit against a rubric of hardening options. Each missing or weakly-set directive contributes exposure points to the total score. Lower is better:

```text
0.0        → very secure
0.1 – 2.9  → OK
3.0 – 5.9  → medium exposure
6.0 – 8.9  → exposed
9.0+       → UNSAFE
```

A ✓ means the directive is set and provides the expected restriction. A ✗ means it's absent or set permissively — but ✗ is a signal, not a verdict. A border router that manages network interfaces will always have `PrivateNetwork=` marked ✗ because isolating the network namespace would break the thing it exists to do. That's a deliberate gap, not a missed directive.

The useful question isn't "how do I get to zero?" It's "do I understand every ✗ in my output?"

Here's what it looks like on this gateway, abbreviated:

```
root@iot-gateway:~# systemd-analyze security otbr-agent.service --no-pager
NAME                                                  DESCRIPTION                                               EXPOSURE
✗ PrivateDevices=       Service potentially has access to hardware devices              0.2
✓ PrivateTmp=           Service has no access to other software's temporary files
✓ ProtectHome=          Service has no access to home directories
✓ ProtectKernelLogs=    Service cannot read from or write to the kernel log ring buffer
✓ ProtectKernelModules= Service cannot load or read kernel modules
✓ RestrictNamespaces=~user  Service cannot create user namespaces
✓ RestrictNamespaces=~net   Service cannot create network namespaces
✓ LockPersonality=      Service cannot change ABI personality
✓ RestrictSUIDSGID=     SUID/SGID file creation by service is restricted
✗ PrivateNetwork=       Service has access to the host's network                        0.5
✗ SystemCallFilter=~@privileged  Service does not filter system calls                   0.2
✗ UMask=                Files created by service are world-readable by default          0.1
...
→ Overall exposure level for otbr-agent.service: 4.1 OK :-)
```

Every ✗ is accounted for by the end of this post.

## The hardening directives

Walking through each directive above — what it restricts and where the tradeoffs are. The [`systemd.exec(5)`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html) man page has the full semantics; links to the relevant anchors are in each section.

### [ProtectSystem=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectSystem=)full

Remounts `/usr`, `/boot`, and `/efi` read-only inside the service's mount namespace. The process can't modify system binaries or bootloader files. `strict` would make the entire file system hierarchy read-only and would require a complete audit of every path the service writes to at runtime — that audit is deferred. `full` covers the primary threat surface without that cost.

### [ProtectHome=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectHome=)true

No access to `/home`, `/root`, or `/run/user`. Standard for any daemon — a border router has no business reading home directories.

### [PrivateTmp=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#PrivateTmp=)true

The service gets an isolated `/tmp` and `/var/tmp` namespace, separate from the host and all other services. Rules out a class of attacks where one service leaves crafted files in shared temp space for another to consume.

### [PrivateDevices=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#PrivateDevices=)false — the forced exception

This is the one directive that had to stay off.

`PrivateDevices=true` mounts a minimal private `/dev` that contains only a safe subset of device nodes: `null`, `zero`, `full`, `random`, `urandom`, `tty`. It explicitly excludes real hardware devices — including `/dev/net/tun`.

OTBR creates the `wpan0` Thread interface by opening `/dev/net/tun` and issuing a `TUNSETIFF` ioctl. Without the TUN device node, startup fails immediately:

```
iot-gateway otbr-agent[4235]: [NOTE]-AGENT---: Radio URL: spinel+hdlc+uart:///dev/otbr-rcp?uart-baudrate=460800
iot-gateway otbr-agent[4235]: [C] Platform------: Init() at hdlc_interface.cpp:153: No such file or directory
iot-gateway systemd[1]: otbr-agent.service: Main process exited, code=exited, status=5/NOTINSTALLED
iot-gateway systemd[1]: otbr-agent.service: Failed with result 'exit-code'.
```

Verified by enabling it via a `/run/systemd/system/` drop-in on the device:

```bash
mkdir -p /run/systemd/system/otbr-agent.service.d/
cat > /run/systemd/system/otbr-agent.service.d/test.conf << EOF
[Service]
PrivateDevices=true
EOF
systemctl daemon-reload && systemctl restart otbr-agent
```

The RCP serial device (`/dev/otbr-rcp`, symlinked to `/dev/ttyACM1`) also disappears from the private `/dev`. Both failures happen at the same point.

`PrivateDevices=false` is the correct setting for this configuration. The TUN device requirement is fundamental to how OTBR creates the `wpan0` interface; no alternative was validated against this build.

### [ProtectKernelTunables=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectKernelTunables=)true

Prevents the process from writing to `/proc/sys` at runtime — no sysctl modifications from within the service. This is safe for OTBR provided IPv6 forwarding is configured at boot, not by the daemon.

On this image, `net.ipv6.conf.all.forwarding=1` is set via a `sysctl.d` fragment applied during early boot by systemd. OTBR never needs to set it at runtime. If your image relies on OTBR to configure forwarding dynamically, this directive needs to come off.

### [ProtectKernelModules](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectKernelModules=), [ProtectKernelLogs](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectKernelLogs=), [ProtectControlGroups](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectControlGroups=), [ProtectClock](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectClock=)

All safe for OTBR without exception:

- `ProtectKernelModules=true` — the service cannot load or unload kernel modules
- `ProtectKernelLogs=true` — no access to `/proc/kmsg` or the kernel log ring buffer
- `ProtectControlGroups=true` — the cgroup filesystem is read-only; the service can't modify its own or any other cgroup
- `ProtectClock=true` — blocks `clock_settime`, `settimeofday`, and related calls; NTP is managed by `systemd-timesyncd`, not OTBR

### [RestrictAddressFamilies=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#RestrictAddressFamilies=)

```ini
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
```

Any `socket()` call for a family not in this list is blocked by a seccomp BPF rule that systemd generates and loads before `ExecStart` runs. The four allowed families come directly from the strace output in Part 1:

| Family | Used for |
|---|---|
| `AF_UNIX` | D-Bus, local IPC, the agent's own Unix domain socket |
| `AF_INET` / `AF_INET6` | REST API, TREL, multicast, ICMPv6 |
| `AF_NETLINK` | Route management via netlink sockets (`NETLINK_ROUTE`) |

`AF_PACKET` is notably absent — raw packet socket access at the Ethernet layer is not needed. Excluding it is correct and intentional.

### [RestrictNamespaces=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#RestrictNamespaces=)true

Blocks `unshare()`, `clone()` with namespace flags, and `setns()` for all namespace types. The implementation is seccomp BPF — each namespace type gets its own filter program. This is where the 15 seccomp filters visible in Part 1's `/proc/status` output come from:

```text
Seccomp:         2
Seccomp_filters: 15
```

`RestrictNamespaces`, `RestrictAddressFamilies`, `LockPersonality`, and `RestrictSUIDSGID` together account for all 15. None of them appear as `SystemCallFilter=` in `systemd-analyze security` output — they're a side effect of sandbox directives, not an explicit syscall allowlist.

### [LockPersonality=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#LockPersonality=)true, [RestrictSUIDSGID=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#RestrictSUIDSGID=)true

`LockPersonality=true` prevents `personality()` syscall — the process can't change the kernel execution domain (e.g. switch to Linux32 ABI emulation). `RestrictSUIDSGID=true` prevents the service from creating setuid/setgid files. Both are standard; neither has OTBR-specific caveats.

### [NoNewPrivileges=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#NoNewPrivileges=)true with ambient capabilities

`NoNewPrivileges=true` ensures that any binary executed via `execve()` within the service — including child processes — cannot gain capabilities or privileges beyond what the bounding set allows. Combined with `AmbientCapabilities`, the interaction is:

- Ambient set grants capabilities at startup without `setcap` on the binary
- Bounding set caps what can ever be held
- `NoNewPrivileges` prevents `execve` from escalating beyond the bounding set

With all three set consistently to the same capability list, this is belt-and-suspenders: the bounding set already prevents escalation, `NoNewPrivileges` makes that guarantee hold for child processes too. Correct default for any non-root service with ambient capabilities.

### [StateDirectory=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#StateDirectory=) and [ReadWritePaths=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ReadWritePaths=)

```ini
StateDirectory=thread
ReadWritePaths=/var/lib/thread
ReadWritePaths=/run
```

`StateDirectory=thread` tells systemd to create `/var/lib/thread` owned by the `otbr` user before the service starts. OTBR persists Thread network dataset here across reboots.

`ProtectSystem=full` makes `/usr`, `/boot`, and `/efi` read-only — it does not restrict `/run`. `RuntimeDirectory=otbr` creates `/run/otbr` with correct ownership before the process starts, which is all the service actually needs. `ReadWritePaths=/run` is redundant here and can be dropped; it's in the unit as a leftover from earlier iterations when the sandbox boundary wasn't fully mapped.

## The remaining gaps

```text
✗ PrivateNetwork=         Service has access to the host's network         0.5
✗ RestrictAddressFamilies=~AF_(INET|INET6)  Service may allocate Internet sockets  0.3
✗ SystemCallFilter=~@privileged             Service does not filter system calls    0.2
✗ SystemCallFilter=~@clock                  Service does not filter system calls    0.2
✗ UMask=                  Files created by service are world-readable by default   0.1
```

**`PrivateNetwork=`** — a border router manages host network interfaces by design. Running in a private network namespace would isolate it from `wlan0`, `wpan0`, and the infrastructure network it exists to bridge. This gap cannot be closed.

**`RestrictAddressFamilies=~AF_(INET|INET6)`** — `AF_INET` and `AF_INET6` are in the allowed set because OTBR needs them. systemd's scoring flags any service that can allocate internet sockets as exposed, regardless of whether those sockets are required. The allowed family list is as tight as it can be.

**`SystemCallFilter=`** — an explicit syscall allowlist would tighten the remaining attack surface significantly. It's not set here because building a correct allowlist requires profiling the full runtime syscall set — strace under normal operation, error paths, and restart scenarios. A wrong allowlist causes silent failures that are harder to debug than a missing hardening directive. Deferred to a future iteration.

**`UMask=`** — low severity. Files created by the service default to world-readable. Setting `UMask=0027` would restrict this. It's a cosmetic open item; OTBR doesn't create files that require tighter default permissions.

## The score

```text
root@iot-gateway:~# systemd-analyze security otbr-agent.service --no-pager
...
→ Overall exposure level for otbr-agent.service: 4.1 OK :-)
```

`4.1 OK`. Every ✗ in the output is accounted for: one is a hard operational requirement (`PrivateNetwork`), one is a documented tradeoff (`SystemCallFilter`), two are required socket families that systemd scores as exposed regardless of intent (`RestrictAddressFamilies`), and one is cosmetic (`UMask`). None are oversights.

That closes the OTBR service. The pattern — read the directive, test it on hardware, account for every ✗ — is the same work for every other daemon on this gateway. When another service has an interesting story, it'll make it here.

## References

- [`systemd.exec(5)` — execution environment](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
- [`systemd-analyze security`](https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html)
- [`seccomp(2)` — Linux man page](https://man7.org/linux/man-pages/man2/seccomp.2.html)
- [seccomp BPF — kernel documentation](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html)
- [EU Cyber Resilience Act — European Commission](https://digital-strategy.ec.europa.eu/en/policies/cyber-resilience-act)
- [Part 1 — Running OTBR as Non-Root: Finding the Capability Floor](/blog/posts/running-otbr-as-non-root/)

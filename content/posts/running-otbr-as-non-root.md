---
title: "Running OTBR as Non-Root: Finding the Capability Floor"
date: 2026-04-14
draft: true
tags: ["otbr", "openthread", "linux", "systemd", "security", "yocto"]
slug: "running-otbr-as-non-root"
series: ["Hardening OTBR"]
summary: "OpenThread Border Router assumes it runs as root. Getting it down to a least-privilege non-root user means figuring out exactly what it needs — which turned out to be a source code problem, not a trial-and-error problem. Part 1 of 2."
---

A while back I was hardening the services on my [Raspberry Pi 5 IoT gateway](https://github.com/umair-as/rpi5-iot-gateway) — a Yocto-built image running a Thread border router, MQTT broker, and a handful of other daemons. One of the design requirements I'd set for myself early on: every long-running service runs as a dedicated non-root user. Least privilege, isolated runtime directories, no ambient root access sitting around waiting to be exploited. The kind of posture the EU's Cyber Resilience Act will eventually require you to justify on paper, but worth doing regardless.

Most daemons were straightforward — a `USERADD_PARAM` in the recipe, a `User=` line in the service file, done. OpenThread Border Router was not.

OTBR ships expecting to run as root. The CMake build system makes this explicit:

```cmake
set(OTBR_AGENT_USER "root" CACHE STRING "set the username running otbr-agent service")
set(OTBR_AGENT_GROUP "root" CACHE STRING "set the group using otbr-agent client")
```

Override flags exist — `-DOTBR_AGENT_USER` and `-DOTBR_AGENT_GROUP` — but the documentation stops there. It doesn't tell you what the non-root user actually needs. All test scripts use `sudo`. The Docker container runs as root without user switching. The escape hatch exists; it's just unlabeled.

## The first error

Create the user, update the service, restart:

```text
otbr-agent[1423]: Failed to create TUN device: Operation not permitted
```

`EPERM` on `TUNSETIFF`. Expected. The question is: what else will fail once we fix this? The brute-force approach — add capabilities until it starts — leaves you with more than you need and no understanding of why. Better to map the requirements first.

## Tracing capabilities from source

Rather than iterating blind on the device, I used [DeepWiki's ot-br-posix index](https://deepwiki.com/openthread/ot-br-posix) with Claude Code to trace through the OTBR source and identify every call site that requires elevated privileges — complete list upfront, no hardware iteration.

## What it actually needs

> **Portability note:** Some decisions here are specific to this image — a nftables-only kernel (`CONFIG_IP6_NF_IPTABLES=n`), a read-only rootfs, and `otbr-web` sharing the same system user as `otbr-agent`. The two core capability requirements (`CAP_NET_ADMIN`, `CAP_NET_RAW`) were required in this build and are expected for any standard OTBR configuration — but may vary with non-default build flags. The third (`CAP_NET_BIND_SERVICE`) and the firewall approach are deployment-specific.

Two capabilities are required unconditionally by `otbr-agent`. A third depends on your deployment. The source analysis makes this clear before touching the device.

### `CAP_NET_ADMIN`

This covers most of what OTBR does with the network stack:

| Operation | Source location |
|---|---|
| Open `/dev/net/tun` + `TUNSETIFF` ioctl | `src/host/posix/netif_linux.cpp:96-99` |
| Netlink route socket (`AF_NETLINK, SOCK_RAW, NETLINK_ROUTE`) | `src/utils/socket_utils.cpp:65` |
| `SO_BINDTODEVICE` socket option | `src/host/posix/netif.cpp:348` |
| `MRT6_INIT`, `MRT6_ADD_MIF` (multicast routing) | `src/host/posix/multicast_routing_manager.cpp:202` |
| Netfilter queue socket | `src/backbone_router/nd_proxy.cpp:418` |

The TUN device is the most fundamental — that's how OTBR creates `wpan0`. Without `CAP_NET_ADMIN`, you never get past startup.

### `CAP_NET_RAW`

Two raw socket operations, both in the infrastructure interface code:

```text
src/host/posix/netif.cpp:334      AF_INET6, SOCK_RAW, IPPROTO_ICMPV6
src/host/posix/infra_if.cpp:278   AF_INET6, SOCK_RAW, IPPROTO_ICMPV6
```

These are for ICMPv6 — neighbor discovery, router advertisements — the machinery that makes Thread devices appear as proper IPv6 nodes on the infrastructure network.

### `CAP_NET_BIND_SERVICE` *(deployment-specific)*

`otbr-agent`'s REST API runs on port 8081 — above 1024, so the agent itself doesn't need this. The web UI (`otbr-webui`) binds port 80, and that does. On this image both services run under the same `otbr` user, so `CAP_NET_BIND_SERVICE` is carried in the bounding set to cover both. If you run `otbr-webui` as a separate user or redirect port 80 via nftables, you can drop it from the agent entirely. It is not a core requirement of `otbr-agent`.

## The external command problem

Capabilities cover the direct syscalls. But OTBR also execs external tools at runtime via `system()`:

- `ip -6 route` commands — `dua_routing_manager.cpp`
- `ip6tables` — `nd_proxy.cpp`
- `ipset` — firewall set management

There are two problems here, and they're independent.

The first is image-specific: this kernel has no legacy iptables stack (`CONFIG_IP6_NF_IPTABLES=n`). The `ip6tables` calls in `nd_proxy.cpp` would fail regardless of privilege — the binary simply isn't there. If you're on a distribution with the full xtables stack, you won't hit this, but you'll still hit the second problem.

The second is architectural: firewall state should be initialized once before the daemon starts, not managed at runtime by a long-running process. Child processes spawned via `system()` do inherit ambient capabilities from the parent — with `CAP_NET_ADMIN` in the ambient set, `ip route` operations would work without root. But `ip6tables` and `ipset` rule setup belongs in initialization, not scattered through a daemon's runtime path. It's fragile, hard to audit, and makes the service harder to reason about.

Both issues point to the same solution: take firewall management out of OTBR's hands entirely. Front-load the rules in an init script that runs once as root before the daemon starts.

systemd's `ExecStartPre=+` is the mechanism. The `+` prefix is a per-command root override — it runs that specific command as root regardless of the service's `User=` setting. The main `ExecStart` (without `+`) still runs as `otbr`. So the privilege split is clean: root work happens once during initialization, the long-running process never has root.

## The socket directory problem

OTBR creates its Unix domain sockets in `/run` by default:

```text
/run/openthread-wpan0.sock
/run/openthread-wpan0.lock
```

Two things make this impossible on this gateway. First, the rootfs is read-only (`ext4, ro`) — but that's actually fine here because `/run` is a separate `tmpfs` mount (`rw`). The real problem is permissions: `/run` itself is `drwxr-xr-x` (root-owned, no write for others), and the `otbr` user gets a hard `Permission denied` trying to create anything there:

```console
$ touch /run/test-otbr
touch: cannot touch '/run/test-otbr': Permission denied
```

Every other daemon on the system has its own subdirectory — `/run/avahi-daemon/`, `/run/mosquitto/`, etc. — owned by its respective user. OTBR needs the same treatment.

The problem is the socket path is compiled in, hardcoded in two places:

```c
// third_party/openthread/repo/src/posix/platform/openthread-posix-daemon-config.h
#define OPENTHREAD_POSIX_CONFIG_DAEMON_SOCKET_BASENAME "/run/openthread-%s"
```

This needed a patch — same change in both the web service client and the platform config header, because if they're out of sync, the web UI can't connect to the daemon socket:

```diff
-#define OPENTHREAD_POSIX_CONFIG_DAEMON_SOCKET_BASENAME "/run/openthread-%s"
+#define OPENTHREAD_POSIX_CONFIG_DAEMON_SOCKET_BASENAME "/run/otbr/openthread-%s"
```

Then `tmpfiles.d` creates the directory at boot:

```ini
# /usr/lib/tmpfiles.d/otbr.conf
d /run/otbr 0750 otbr otbr -
```

## The configuration

### System user and device

```bash
groupadd --system otbr
useradd --system --home-dir /var/lib/otbr \
        --shell /sbin/nologin \
        --gid otbr --groups dialout \
        otbr
```

In a Yocto recipe, this is handled by `USERADD_PARAM`. The CMake flags wire into the build via `EXTRA_OECMAKE += "-DOTBR_AGENT_USER=otbr -DOTBR_AGENT_GROUP=otbr"` — this makes the installed systemd unit reference the correct user without patching it manually.

The `dialout` group gives access to the RCP serial device. A udev rule assigns the symlink:

```text
SUBSYSTEM=="tty", KERNEL=="ttyACM*", GROUP="dialout", MODE="0660", SYMLINK+="otbr-rcp"
```

### Service unit

```ini
[Unit]
Description=OpenThread Border Router Agent
Requires=dbus.socket avahi-daemon.service dev-otbr\x2drcp.device
After=dbus.socket avahi-daemon.service dev-otbr\x2drcp.device

[Service]
User=otbr
Group=otbr
SupplementaryGroups=dialout
EnvironmentFile=-/etc/default/otbr-agent
Environment=OTBR_SOCKET_DIR=/run/otbr
RuntimeDirectory=otbr
RuntimeDirectoryMode=0750

# These run as root (note the + prefix)
ExecStartPre=+/usr/libexec/otbr/otbr-ipset-init
ExecStartPre=+/bin/sh -c 'rm -f /run/otbr/openthread-wpan0.sock; \
    touch /run/otbr/openthread-wpan0.lock; \
    chown otbr:otbr /run/otbr/openthread-wpan0.lock; \
    chmod 660 /run/otbr/openthread-wpan0.lock'

ExecStart=/usr/sbin/otbr-agent $OTBR_AGENT_OPTS
KillMode=mixed
Restart=on-failure
RestartSec=5

# Core: CAP_NET_ADMIN CAP_NET_RAW — required by otbr-agent
# Deployment-specific: CAP_NET_BIND_SERVICE — needed here because otbr-web shares this user
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

The service file also carries a hardening block — `ProtectSystem`, `PrivateDevices`, `RestrictAddressFamilies`, `MemoryDenyWriteExecute`, and a dozen others. Some of them required deliberate exceptions for OTBR specifically, and each directive is worth explaining properly. That's Part 2.

### The firewall init script

`otbr-ipset-init` replaces what upstream OTBR would do via `ip6tables` at runtime. It runs once as root via `ExecStartPre=+`, sets up the ipset tables OTBR expects to exist, and installs the equivalent nftables rules. The NAT block has an explicit fallback — not all kernel configs include `nf_nat`, and the service shouldn't fail hard on a device where NAT isn't needed:

```bash
#!/bin/sh
set -e
THREAD_IF="${THREAD_IF:-wpan0}"
INFRA_IF="${INFRA_IF:-wlan0}"

ipset create -exist otbr-ingress-deny-src hash:net family inet6
ipset create -exist otbr-ingress-deny-src-swap hash:net family inet6
ipset create -exist otbr-ingress-allow-dst hash:net family inet6
ipset create -exist otbr-ingress-allow-dst-swap hash:net family inet6

nft delete table inet otbr 2>/dev/null || true
nft -f - <<EOF
table inet otbr {
    chain mangle_prerouting {
        type filter hook prerouting priority mangle; policy accept;
        iifname "$THREAD_IF" meta mark set 0x1001
    }
    chain filter_forward {
        type filter hook forward priority filter; policy accept;
        oifname "$INFRA_IF" accept
        iifname "$INFRA_IF" accept
    }
}
EOF

nft -f - <<EOF || echo "WARNING: nftables NAT unavailable, running without masquerade" >&2
table ip otbr_nat {
    chain nat_postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        meta mark 0x1001 oifname "$INFRA_IF" masquerade
    }
}
EOF
```

### D-Bus policy

OTBR claims a D-Bus name (`io.openthread.BorderRouter.*`). The default policy only allows root to own service names. This one is easy to miss — D-Bus registration happens late in startup, after the TUN device, sockets, and capabilities are all working. The agent exits silently.

```xml
<policy user="otbr">
    <allow own_prefix="io.openthread.BorderRouter"/>
    <allow send_interface="io.openthread.BorderRouter"/>
    <allow send_interface="org.freedesktop.DBus.Properties"/>
    <allow send_interface="org.freedesktop.DBus.Introspectable"/>
</policy>
```

## Verifying on the device

### strace confirmation

Before locking down the unit file, confirm with `strace` that the three capabilities are sufficient. Stop the service, run the ipset init manually (it normally runs via `ExecStartPre=+`), then launch under `capsh`:

```bash
root@iot-gateway:~# systemctl stop otbr-agent
root@iot-gateway:~# /usr/libexec/otbr/otbr-ipset-init
root@iot-gateway:~# capsh --user=otbr \
  --inh="cap_net_admin,cap_net_raw,cap_net_bind_service" \
  --addamb="cap_net_admin,cap_net_raw,cap_net_bind_service" \
  -- -c "strace -f -e trace=socket,bind,ioctl \
    /usr/sbin/otbr-agent -I wpan0 -B wlan0 \
    --rest-listen-address 0.0.0.0 \
    spinel+hdlc+uart:///dev/otbr-rcp?uart-baudrate=460800 trel://wlan0" 2>&1 | \
  grep -E "socket|bind|TUNSETIFF|EPERM|error"
```

The `-f` follows forked threads — important since `otbr-agent` spawns several that each do their own socket setup. Output from the device:

```text
socket(AF_NETLINK, SOCK_DGRAM|SOCK_CLOEXEC, NETLINK_ROUTE)        = 14
bind(14, {sa_family=AF_NETLINK, nl_pid=0, nl_groups=0x000101}, 12) = 0
socket(AF_NETLINK, SOCK_DGRAM|SOCK_CLOEXEC|SOCK_NONBLOCK, NETLINK_ROUTE) = 16
bind(16, {sa_family=AF_NETLINK, nl_pid=0, nl_groups=0x000101}, 12) = 0
ioctl(17, TUNSETIFF, 0xffffca8e61e0)                               = 0
socket(AF_INET6, SOCK_RAW|SOCK_CLOEXEC|SOCK_NONBLOCK, IPPROTO_ICMPV6) = 18
socket(AF_INET6, SOCK_RAW|SOCK_CLOEXEC, IPPROTO_ICMPV6)           = 21
socket(AF_NETLINK, SOCK_RAW|SOCK_CLOEXEC, NETLINK_ROUTE)          = 22
bind(22, {sa_family=AF_NETLINK, nl_pid=0, nl_groups=00000000}, 12) = 0
```

No `EPERM` anywhere. Every call maps back to the source analysis: `TUNSETIFF` and netlink sockets → `CAP_NET_ADMIN`; both `IPPROTO_ICMPV6` raw sockets → `CAP_NET_RAW`. `CAP_NET_BIND_SERVICE` doesn't appear because the REST API binds above port 1024 — it only matters for `otbr-web` on port 80.

### Capability sets

Check what the running process actually holds:

```bash
cat /proc/$(pgrep -x otbr-agent)/status | grep Cap
capsh --decode=$(cat /proc/$(pgrep -x otbr-agent)/status | grep CapEff | awk '{print $2}')
```

Three capabilities: `cap_net_bind_service`, `cap_net_admin`, `cap_net_raw`. Nothing else.

## Known rough edges

A few warnings appear in the logs that don't affect operation:

```text
[W] P-Netif-------: ADD [U] fe80::107f:217:fc6f:63bf failed (InvalidArgs)
[W] P-Netif-------: Failed to process event, error:InvalidArgs
```

OTBR attempting to add a link-local address that already exists on the interface. The interface still comes up correctly.

## Before and after

Before: `otbr-agent` as root, full capabilities, no sandbox.

After: a system user with no shell, three network capabilities, `ExecStartPre=+` handling the root-only initialization work, and a runtime directory the process can actually write to.

The socket patch took longer to track down than it should have — the web service client and the platform config header need matching paths, and a mismatch produces a silent connection failure, not a crash. Everything after that — the hardening block, the directives that had to stay off, the `systemd-analyze security` score — is a different kind of work: not "will it run?" but "how much surface are you actually exposing?"

That's the next article.

---

Full source for the Yocto recipe, service files, and init script is in
[`meta-iot-gateway`](https://github.com/umair-as/rpi5-iot-gateway/tree/main/meta-iot-gateway/recipes-connectivity/otbr).

## References

- [OpenThread Border Router — official docs](https://openthread.io/guides/border-router)
- [ot-br-posix source index — DeepWiki](https://deepwiki.com/openthread/ot-br-posix)
- [ot-br-posix on GitHub](https://github.com/openthread/ot-br-posix)
- [`capabilities(7)` — Linux man page](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [`CAP_NET_ADMIN`, `CAP_NET_RAW`, `CAP_NET_BIND_SERVICE` — kernel credentials docs](https://www.kernel.org/doc/html/latest/security/credentials.html)
- [`systemd.exec(5)` — execution environment](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
- [`systemd-analyze security`](https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html)
- [`tmpfiles.d(5)`](https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html)
- [`seccomp(2)` — Linux man page](https://man7.org/linux/man-pages/man2/seccomp.2.html)
- [seccomp BPF — kernel documentation](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html)
- [nftables wiki](https://wiki.nftables.org/)
- [Migrating from iptables to nftables](https://wiki.nftables.org/wiki-nftables/index.php/Moving_from_iptables_to_nftables)
- [`ipset` man page](https://ipset.netfilter.org/ipset.man.html)
- [EU Cyber Resilience Act — European Commission](https://digital-strategy.ec.europa.eu/en/policies/cyber-resilience-act)
- [EU Cyber Resilience Act — community resource](https://www.european-cyber-resilience-act.com/)
- [Part 2 — Hardening the OTBR Service File](/blog/posts/otbr-systemd-hardening/)

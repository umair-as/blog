# Blog — Claude Context

## What this repo is

Personal technical blog for Umair Ahmed Shah. Hugo + PaperMod theme, deployed
to GitHub Pages via GitHub Actions on every merge to `main`.

Live at: https://umair-as.github.io/blog/

## Author profile

Senior systems software engineer, Cologne Germany. Deep hands-on background in
embedded Linux (Yocto, BSP, kernel), Zephyr RTOS, wireless protocols (Thread,
BLE, Wi-Fi), IoT/edge infrastructure, OTA pipelines (RAUC), and security
hardening. Primary languages: C, C++, Rust, Go.

The audience for this blog is peers — embedded and systems engineers who can
immediately tell if something is shallow or hand-wavy. Writing standard is
accordingly high. Not tutorials. First-person engineering accounts: what the
problem was, what the constraints were, what failed, and what eventually worked.

## Repository structure

```
blog/
├── content/
│   ├── posts/          ← articles (one .md per post)
│   ├── about.md
│   ├── archives.md
│   ├── search.md
│   └── privacy.md
├── layouts/
│   └── partials/
│       ├── extend_head.html    ← custom fonts, meta
│       ├── extend_footer.html  ← copyright, license
│       └── home_info.html      ← custom homepage hero
├── assets/             ← custom CSS
├── themes/PaperMod/    ← git submodule
├── hugo.yaml           ← site config
├── Makefile            ← dev workflow commands
├── Dockerfile          ← Hugo build environment
├── docker-compose.yml
└── CONTRIBUTING.md     ← writing workflow documentation
```

## Local development

```bash
make image    # build Docker image once (or after Hugo version bump)
make serve    # dev server at http://localhost:1313/blog/ (drafts visible)
make build    # production build → ./public/
make clean    # remove ./public/
make shell    # bash inside build container
```

Start a new post:
```bash
make article SLUG=your-post-slug
# creates branch post/your-post-slug
# creates content/posts/your-post-slug.md as draft
```

## Hugo config highlights

- Theme: PaperMod (git submodule)
- Hugo version: 0.159.0 (pinned in Dockerfile)
- Base URL: https://umair-as.github.io/blog/
- Default theme: dark
- Syntax highlighting: Nord style
- ToC: enabled, closed by default
- Share buttons: disabled
- Series navigation: enabled (ShowSeriesNavigation)
- Code copy buttons: enabled

## Post frontmatter standard

```yaml
---
title: "Title of the Post"
date: YYYY-MM-DD
draft: true                    # set false only after final review
tags: ["tag1", "tag2"]
slug: "url-friendly-slug"
series: ["Series Name"]        # omit if not part of a series
summary: "One sentence. What the post covers and why it matters to a systems engineer."
---
```

## Writing and review workflow

1. `make article SLUG=post-slug` — creates branch and draft file
2. Write draft, commit freely on the branch
3. Self-review (see CONTRIBUTING.md checklist)
4. Final review pass — see review skill below
5. Set `draft: false`, commit, open PR against `main`
6. Merge → GitHub Actions deploys automatically (~30 seconds)

Drafts never reach `main`. The git log on `main` is a clean publication timeline.

## Blog review skill

The review skill lives at `~/.claude/skills/blog-review/SKILL.md` on the
author's machine. It is NOT in this repo (private tooling).

When asked to review a post:
- In Claude Code: the skill is auto-loaded from `~/.claude/skills/`
- In the web interface: read the skill file content if provided, or apply
  the standards defined below directly

### Review standards (summary)

The benchmark is a post a senior embedded/systems engineer would read and
trust immediately. Specifically:

**Technical depth:** All claims must be specific and verifiable — exact file
paths, exact error messages, exact kernel config options, exact versions.
The "why" must be explained, not just the "what". Code examples must be
complete enough to be useful, not pseudocode.

**Structure:** Opening establishes the actual problem within 2 paragraphs.
Logical flow: problem → constraints → attempts → solution → insight.
Ending leaves reader with something concrete, not a summary.

**Prose:** Direct. Peer-to-peer tone, not instructional. No filler phrases.
No "simply", "easy", "you should". Sentences do one job.

**Anti-patterns (hard stops):**
- Tutorial-speak
- Documentation repackaging (no original insight)
- Happy path only (no failures, no caveats)
- Vague causality ("this caused issues")
- Generic advice not specific to the actual problem
- Motivation padding in the opening

**Code formatting:** Language tags on all blocks. `inline code` for file
paths, config keys, function names, tool names. Output shown separately
from commands.

## Active post series

### Hardening OTBR (2 parts)
- Part 1: `content/posts/running-otbr-as-non-root.md` — capability mapping,
  dedicated user, socket directory patch, firewall init, D-Bus policy
- Part 2: (planned) systemd service hardening — ProtectSystem,
  RestrictAddressFamilies, SystemCallFilter, closing the gaps from the
  4.1 OK security score

### Planned posts (not started)
- SSH hardening on production embedded Linux
- Kernel + U-Boot hardening on RPi5
- RPi5 secure boot: BCM2712 OTP → U-Boot gap

## Planned backlog
Posts derived from the rpi5-iot-gateway project:
https://github.com/umair-as/rpi5-iot-gateway

## Deployment

Push to `main` triggers `.github/workflows/deploy.yml`:
- Builds with Hugo extended 0.159.0
- Deploys to GitHub Pages via `actions/deploy-pages`
- Timezone set to Europe/Berlin
- `--baseURL` override from Pages config at build time

GitHub Pages must be configured to deploy from GitHub Actions (not gh-pages
branch) in repo Settings → Pages.

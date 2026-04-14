# Writing workflow

## Prerequisites

```bash
make image   # build the Docker image once (re-run after Hugo version bumps)
```

---

## Writing a new article

### 1. Start the article

```bash
make article SLUG=otbr-non-root
```

This creates a git branch `post/otbr-non-root` and a draft file
`content/posts/otbr-non-root.md`. All your work stays on this branch
and never touches `main` until you're ready to publish.

### 2. Preview locally

```bash
make serve
# http://localhost:1313/blog/ — live reload, drafts visible
```

### 3. Write, iterate, commit freely

```bash
git add content/posts/otbr-non-root.md
git commit -m "docs(posts): draft otbr non-root article"
# keep committing as you write — cheap and useful history
```

### 4. Publish

When the article is ready:

1. Set `draft: false` in the post frontmatter
2. Commit:
   ```bash
   git add content/posts/otbr-non-root.md
   git commit -m "docs(posts): publish otbr-non-root article"
   ```
3. Push and open a PR:
   ```bash
   git push -u origin post/otbr-non-root
   gh pr create --title "publish: OTBR as Non-Root" --body "" --base main
   ```
4. Merge the PR → GitHub Actions builds and deploys automatically

Live at **https://umair-as.github.io/blog/** in ~30 seconds.

---

## Why this workflow

Every merged PR becomes a commit on `main`. Over time the git log reads
like a publication timeline:

```
* docs(posts): publish otbr-non-root article
* docs(posts): publish rauc-ota article
* docs(posts): publish yocto-rpi5 article
* chore: initial blog setup
```

Drafts never appear in `main`, so the public repo only ever shows
published work — even though the repo itself is public.

---

## Other commands

```bash
make build   # production build → ./public/
make clean   # remove ./public/
make shell   # bash inside the build container
```

## Notes

- Tags go in frontmatter: `tags: ["yocto", "rauc", "ota"]`
- Images go in `static/images/` and reference as `/blog/images/filename.png`
- RSS feed at `/blog/index.xml`
- Hugo version is pinned in `Dockerfile` — bump `HUGO_VERSION` + `make image` to upgrade

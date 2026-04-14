HUGO_VERSION := 0.159.0
IMAGE        := blog-hugo

.PHONY: image serve build clean shell article

## Build the Docker image (run once, or after Hugo version bump)
image:
	docker compose build

## Start local dev server at http://localhost:1313/blog/
serve:
	docker compose up serve

## Production build → ./public/
build:
	docker compose run --rm build

## Drop into a shell inside the build container
shell:
	docker compose run --rm --entrypoint bash build

## Remove ./public/
clean:
	rm -rf public/

## Start a new article:  make article SLUG=my-post-title
##   - creates branch post/SLUG
##   - creates content/posts/SLUG.md as draft
article:
	@test -n "$(SLUG)" || (echo "Usage: make article SLUG=my-post-title" && exit 1)
	git checkout -b post/$(SLUG)
	docker compose run --rm build hugo new content posts/$(SLUG).md
	@echo ""
	@echo "  branch : post/$(SLUG)"
	@echo "  file   : content/posts/$(SLUG).md"
	@echo "  next   : make serve"

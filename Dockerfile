FROM debian:bookworm-slim

ARG HUGO_VERSION=0.159.0
# Matches Docker buildx TARGETARCH values (amd64, arm64)
ARG TARGETARCH=amd64

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        git \
    && rm -rf /var/lib/apt/lists/* \
    && wget -qO /tmp/hugo.tar.gz \
        "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-${TARGETARCH}.tar.gz" \
    && tar -xzf /tmp/hugo.tar.gz -C /tmp \
    && mv /tmp/hugo /usr/local/bin/hugo \
    && rm /tmp/hugo.tar.gz \
    && hugo version

WORKDIR /site

EXPOSE 1313

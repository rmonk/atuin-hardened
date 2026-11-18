# Hardened atuin server image: upstream source at the release tag, built with upstream's pinned
# Rust toolchain and locked dependencies, on Debian 13 with current packages, running as a fixed
# non-1000 uid with tini as PID 1. Same binary, environment, config dir, port, health check and
# entrypoint as upstream's image, so it is a drop-in replacement for ghcr.io/atuinsh/atuin.
#
# Build context: build/src (upstream source), prepared by scripts/prepare.sh.
# Build args come from build/build-args.

ARG RUST_IMAGE
ARG RUNTIME_IMAGE

FROM ${RUST_IMAGE} AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libssl-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# RUST_IMAGE matches rust-toolchain.toml, so rustup uses it instead of downloading a toolchain.
RUN cargo build --release --locked --bin atuin-server \
 && ./target/release/atuin-server --version

FROM ${RUNTIME_IMAGE}
ARG UPSTREAM_VERSION
ARG UPSTREAM_SHA
ARG HARDENED_VERSION=dev
ARG HARDENED_SOURCE=
# Fixed IDs; upstream's `useradd` gets 1000, which is a real user on futomaki.
ARG ATUIN_UID=8888
ARG ATUIN_GID=8888

LABEL org.opencontainers.image.title="atuin server (hardened)" \
      org.opencontainers.image.version="${HARDENED_VERSION}" \
      org.opencontainers.image.source="${HARDENED_SOURCE}" \
      org.opencontainers.image.description="atuin-server ${UPSTREAM_VERSION} built from source on Debian 13, non-root" \
      org.opencontainers.image.licenses="MIT" \
      sh.atuin.version="${UPSTREAM_VERSION}" \
      sh.atuin.revision="${UPSTREAM_SHA}"

# Upstream's packages minus curl: ca-certificates for webhooks and OpenSSL. The health check uses
# bash's /dev/tcp instead of curl, which drops curl's dependency tree (Kerberos, libssh2, ...) and
# most of the remaining unfixed Debian findings. tini is PID 1 so health-check processes are
# reaped (upstream leaves zombies, its PID 1 is the server).
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends ca-certificates libssl3t64 tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g "${ATUIN_GID}" atuin \
 && useradd -u "${ATUIN_UID}" -g "${ATUIN_GID}" -c 'atuin user' -M -d /app -s /usr/sbin/nologin atuin \
 && mkdir /config && chown atuin:atuin /config
WORKDIR /app

USER ${ATUIN_UID}:${ATUIN_GID}

ENV TZ=Etc/UTC
ENV RUST_LOG=atuin_server=info
ENV ATUIN_CONFIG_DIR=/config

COPY --from=build /src/target/release/atuin-server /usr/local/bin/

# Same check as upstream (GET /healthz must return 200), without curl.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${ATUIN_PORT:-8888} && printf 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]

ENTRYPOINT ["tini", "--", "/usr/local/bin/atuin-server"]
CMD ["start"]

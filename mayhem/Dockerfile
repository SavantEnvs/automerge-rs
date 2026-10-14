# syntax=docker/dockerfile:1.7
#
# automerge-rs commit-image Dockerfile — Rust cargo-fuzz on the org base
# (ghcr.io/savantenvs/base). Installs a pinned nightly (needed for -Zsanitizer=address)
# PLUS the exact stable release upstream's own rust/rust-toolchain.toml pins (1.90 — also
# automerge's Cargo.toml rust-version="1.90.0" MSRV), both at a fixed, $HOME-independent
# prefix (/opt/toolchains/rust — SPEC §6.2 item 8). The oracle (mayhem/test.sh, `cargo
# test`) runs on +1.90 so it matches upstream's own pin; the fuzz targets build on the
# pinned nightly. Never invoke bare `cargo` (see mayhem/build.sh) — a bare invocation
# anywhere under rust/ would silently pick up rust/rust-toolchain.toml's 1.90 instead of
# the toolchain the caller intended.

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH

ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

ARG RUST_CHANNEL=nightly-2025-10-15
ARG RUST_STABLE=1.90
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:$PATH

USER root
RUN set -eux; \
    install -d /opt/toolchains/rust; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_CHANNEL"; \
    rustup component add rust-src --toolchain "$RUST_CHANNEL"; \
    rustup toolchain install "$RUST_STABLE" --profile minimal; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    chown -R 2000:2000 /opt/toolchains/rust; \
    rustc --version; cargo --version; cargo fuzz --version; rustc "+$RUST_STABLE" --version
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      rlenv.fix="f10981173c2ac68d294e61dca8f4ea28444d07ac" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem

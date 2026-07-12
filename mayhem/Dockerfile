# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — delta (dandavison/delta), a Rust CLI (syntax-highlighting
# pager for git). Builds ON TOP of the org base (ghcr.io/mayhemheroes/base), adding a
# pinned Rust nightly toolchain under /opt/toolchains/rust, then runs mayhem/build.sh
# (ASan-sanitized `delta` binary — the Mayhem target reads a diff on stdin) and
# mayhem/test.sh (upstream's full cargo test suite + the three end-to-end scripts).
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t delta-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Declared for parity with the C/C++ contract; Rust instrumentation is driven via
# RUSTFLAGS (-Zsanitizer=address) in build.sh, not clang's $SANITIZER_FLAGS.
ARG SANITIZER_FLAGS

# Pin the nightly by DATE: -Zsanitizer=address needs nightly, and a dated nightly keeps
# the build reproducible (mirrors OSS-Fuzz's base-builder-rust).
ARG RUST_CHANNEL=nightly-2025-09-05

# Rust toolchain at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8): the cargo
# registry this first (online) build populates under $CARGO_HOME is found again by the
# air-gapped PATCH re-run of build.sh regardless of the re-run identity's $HOME.
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): hand the
 # whole prefix to 2000 so build.sh can read the toolchain and refresh the registry cache.
 && chown -R 2000:2000 /opt/toolchains/rust

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build), builds the sanitized target binary
# AND the normal-flags binary + test suite that test.sh runs.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem

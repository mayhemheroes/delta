# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest as builder

## Add source code to the build stage.
ADD . /src
WORKDIR /src

RUN env RUSTFLAGS="-g -Cdebug-assertions=on" cargo +nightly -Z sparse-registry build --release && \
    mv target/release/delta /delta

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /delta /

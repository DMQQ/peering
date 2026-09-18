# For running the relay in a container rather than as a bare binary.
#
# If you only want the binary — to copy to a VPS and run under systemd — you do not need this. Use
# the GitHub Actions build, or `cargo build --release` on a Linux machine. This file is for people
# who would rather run the relay as a container, which is a perfectly good way to do it.
#
#   docker build -t peeringd Relay
#   docker run -d --name peeringd \
#     -p 8443:8443 -p 9443:9443 -p 9444:9444/udp \
#     -v /etc/letsencrypt:/certs:ro \
#     -e PEERINGD_TLS_CERT=/certs/live/relay.example/fullchain.pem \
#     -e PEERINGD_TLS_KEY=/certs/live/relay.example/privkey.pem \
#     peeringd
#
# The image carries the site as well, and serves it on 127.0.0.1:8080 — inside the container, so a
# reverse proxy on the host either reaches it through the container network or the relay is told to
# bind wider:
#
#   -e PEERINGD_WEB_ADDR=0.0.0.0:8080 -p 8080:8080
#
# Building for a server of a different architecture needs `--platform`:
#
#   docker build --platform linux/amd64 -t peeringd Relay    # x86_64 VPS, from an Apple Silicon Mac
#
# That runs the whole build under emulation and takes several minutes. Building on the target
# architecture — or letting GitHub Actions do it — avoids that entirely.

FROM rust:1.98.1 AS build

# musl-gcc is the only C toolchain needed, because the relay's TLS is on `ring` rather than
# `aws-lc-rs`. See the comment in Cargo.toml.
RUN apt-get update \
    && apt-get install -y --no-install-recommends musl-tools \
    && rm -rf /var/lib/apt/lists/*

RUN rustup target add x86_64-unknown-linux-musl

WORKDIR /src
COPY . .

ENV CC_x86_64_unknown_linux_musl=musl-gcc
ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc

# --locked so the build is the one Cargo.lock describes, rather than a newer resolution that
# happens to work today.
RUN cargo build --release --locked --target x86_64-unknown-linux-musl

# alpine rather than scratch so there is a shell to debug with, and so `ca-certificates` can be
# installed — not that the relay makes outbound TLS calls, but a container with no trust store is a
# trap for whoever adds one later.
FROM alpine:3
RUN apk add --no-cache ca-certificates
COPY --from=build /src/target/x86_64-unknown-linux-musl/release/peeringd /usr/local/bin/peeringd

# The site. Copied rather than baked into the binary so that changing a line of the privacy policy
# is a container rebuild and not a Rust build — and so the pages can be opened and read by whoever
# has to stand behind them.
COPY --from=build /src/site /srv/site
ENV PEERINGD_WEB_ROOT=/srv/site

# 8443 signalling, 9443 control, 9444 the one video socket every session shares — see
# PEERINGD_VIDEO_BIND. 8080 is the site, and is loopback-only unless PEERINGD_WEB_ADDR is changed:
# it belongs behind whatever terminates TLS on the host, not on a published port.
EXPOSE 8443/tcp 9443/tcp 9444/udp

ENTRYPOINT ["peeringd"]

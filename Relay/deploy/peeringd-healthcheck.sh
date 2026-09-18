#!/bin/sh
# Restarts the relay if it is running but not answering.
#
# `Restart=always` in the unit covers a process that died. It does not cover the state this script
# exists for: the process alive, the socket gone — a listener that failed to bind, a thread that
# unwound, a port taken by something that started first. From outside those look identical to a
# crash, and systemd sees a healthy service, so nothing restarts it and nobody finds out until
# somebody tries to connect.
#
# Run from a timer every few minutes. Deliberately quiet on success: a log line every five minutes
# is a log nobody reads, and the journal's own "Stopped/Started" pair records each restart anyway.

set -eu

URL="${PEERINGD_HEALTHCHECK_URL:-http://127.0.0.1:8080/healthz}"
TAG="peeringd-healthcheck"

# The service being down is systemd's business, not this script's — it would only start a race
# with the unit's own restart.
if ! systemctl is-active --quiet peeringd; then
    exit 0
fi

if curl -fsS --max-time 5 "$URL" >/dev/null 2>&1; then
    exit 0
fi

# One retry before acting: the web listener answers from the same event loop as signalling, and a
# single busy moment under a burst of registrations should not cost every session on the box.
sleep 5
if curl -fsS --max-time 5 "$URL" >/dev/null 2>&1; then
    exit 0
fi

logger -t "$TAG" "healthz did not answer at $URL; the process is alive, so restarting it"
systemctl restart peeringd

# Confirmed rather than assumed, and said out loud when it is still wrong: a restart that does not
# fix it is a different problem, and the next reader should see that from one line.
sleep 3
if curl -fsS --max-time 5 "$URL" >/dev/null 2>&1; then
    logger -t "$TAG" "restarted, and it is answering again"
else
    logger -t "$TAG" "restarted, and it is STILL not answering — this is not a stuck process"
fi

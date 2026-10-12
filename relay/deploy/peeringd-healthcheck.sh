#!/bin/bash
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
# The listeners the relay is expected to hold, as host:port. `/healthz` reports the relay's own
# view of them, so these only matter when the web listener is not there to ask.
PORTS="${PEERINGD_HEALTHCHECK_PORTS:-127.0.0.1:8443 127.0.0.1:9443}"
TAG="peeringd-healthcheck"

# The HTTP status of /healthz, or 000 when nothing answered.
status() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null || true
}

# Whether every expected port accepts a connection.
listeners_accept() {
    local endpoint
    for endpoint in $PORTS; do
        timeout 3 bash -c "exec 3<>/dev/tcp/${endpoint%:*}/${endpoint##*:}" 2>/dev/null || return 1
    done
}

# Healthy means `/healthz` says 200. When nothing answers at all the web listener is simply absent,
# which says nothing about the relay, so the real listeners are asked directly. A 503 is the relay
# saying one of its own tasks has stopped, and is never excused.
healthy() {
    case "$(status)" in
        200) return 0 ;;
        000) listeners_accept ;;
        *) return 1 ;;
    esac
}

# The service being down is systemd's business, not this script's — it would only start a race
# with the unit's own restart.
if ! systemctl is-active --quiet peeringd; then
    exit 0
fi

if healthy; then
    exit 0
fi

# One retry before acting: the web listener answers from the same event loop as signalling, and a
# single busy moment under a burst of registrations should not cost every session on the box.
sleep 5
if healthy; then
    exit 0
fi

logger -t "$TAG" "healthz at $URL is not healthy and the listeners do not answer; the process is alive, so restarting it"
systemctl restart peeringd

# Confirmed rather than assumed, and said out loud when it is still wrong: a restart that does not
# fix it is a different problem, and the next reader should see that from one line.
sleep 3
if healthy; then
    logger -t "$TAG" "restarted, and it is answering again"
else
    logger -t "$TAG" "restarted, and it is STILL not answering — this is not a stuck process"
fi

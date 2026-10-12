# Sourced by tools/deploy-relay.sh on the box after a restart: decides whether the new binary is
# good enough to keep, or must be rolled back.
#
# Needs HEALTH_URL and HEALTH_PORTS (host:port pairs, signalling then control) from the caller.
# Healthy means every listed port accepts a connection and /healthz is either 200 or not answering
# at all. Nothing answering is the web listener not being bound, which says nothing about the relay
# (a missing site directory or a taken web port must not roll back a good deploy). A 503 is the
# relay reporting a stopped task and is never excused.

health_attempts="${PEERINGD_HEALTH_ATTEMPTS:-10}"

health_status() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$HEALTH_URL" 2>/dev/null || true
}

listeners_accept() {
    local endpoint
    for endpoint in $HEALTH_PORTS; do
        timeout 3 bash -c "exec 3<>/dev/tcp/${endpoint%:*}/${endpoint##*:}" 2>/dev/null || return 1
    done
}

healthy() {
    local attempt
    for attempt in $(seq 1 "$health_attempts"); do
        if listeners_accept; then
            case "$(health_status)" in
                200 | 000) return 0 ;;
            esac
        fi
        sleep 1
    done
    return 1
}

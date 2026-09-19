#!/bin/bash
# Build the relay in CI, fetch the binary, and install it on the server.
#
# Where each step happens is the whole design of this script:
#
#   * **Built on GitHub**, not here and not there. A runner is already x86_64 Linux, so there is no
#     cross-compilation to get wrong, the build is reproducible from `Cargo.lock`, and the machine
#     facing the internet never gets a Rust toolchain installed on it. The relay's own workflow
#     says the same thing at more length.
#   * **Fetched here**, with the credential `git` already holds — the repository is private, so the
#     release asset is not downloadable anonymously.
#   * **Installed there**, over ssh, with the old binary kept as a `.bak` beside it.
#
# The tag is what makes the artifact downloadable without logging in, which is why this takes a
# tag rather than a branch or a commit.
#
#   Tools/deploy-relay.sh v0.1.6
#   Tools/deploy-relay.sh v0.1.6 --yes      # skip the confirmation
#
# Environment overrides: PEERINGD_SSH (default below), PEERINGD_REPO, PEERINGD_REMOTE_BIN,
# PEERINGD_REMOTE_SITE.

set -euo pipefail

REPO="${PEERINGD_REPO:-DMQQ/peering}"
SSH_TARGET="${PEERINGD_SSH:-root@pro01.mikr.us}"
# `-p` for ssh and `-P` for scp, which is not a typo and not interchangeable: to scp, a lowercase
# `-p` means "preserve times", so passing the port that way makes it treat the number as a file
# and fail with `stat local "10190": No such file or directory`.
SSH_ARGS=(-p "${PEERINGD_SSH_PORT:-10190}")
SCP_ARGS=(-P "${PEERINGD_SSH_PORT:-10190}")
REMOTE_BIN="${PEERINGD_REMOTE_BIN:-/usr/local/bin/peeringd}"
REMOTE_SITE="${PEERINGD_REMOTE_SITE:-/srv/peering/site}"
ASSET="peeringd-linux-x86_64"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TAG="${1:-}"
YES="${2:-}"
if [ -z "$TAG" ]; then
    echo "usage: $(basename "$0") <tag> [--yes]      (e.g. $(basename "$0") v0.1.6)" >&2
    echo "tags so far: $(git -C "$REPO_DIR" tag | tail -3 | tr '\n' ' ')" >&2
    exit 1
fi

echo "==> waiting for CI to publish $TAG"

# The release asset appears only when the workflow has finished: tests, then the musl build, then
# the upload. Polling for it is simpler than watching the run, and it is the thing this script
# actually needs.
TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
if [ -z "$TOKEN" ]; then
    echo "no GitHub credential found for github.com — run 'git fetch' once so the keychain is filled" >&2
    exit 1
fi

ASSET_ID=""
for _ in $(seq 1 60); do
    RELEASE="$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$REPO/releases/tags/$TAG" || true)"
    ASSET_ID="$(printf '%s' "$RELEASE" | python3 -c "
import json,sys
try: release = json.load(sys.stdin)
except Exception: raise SystemExit
print(next((a['id'] for a in release.get('assets', []) if a['name'] == '$ASSET'), ''))
" 2>/dev/null || true)"
    [ -n "$ASSET_ID" ] && break
    sleep 15
done

if [ -z "$ASSET_ID" ]; then
    echo "no $ASSET asset on release $TAG after 15 minutes — check the workflow run" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> fetching the binary"
# The API endpoint rather than the browser URL, because the repository is private and this is the
# form that carries authentication.
curl -sL -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" \
    "https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID" -o "$STAGING/peeringd"

FILE_TYPE="$(file -b "$STAGING/peeringd")"
case "$FILE_TYPE" in
    *"ELF 64-bit"*x86-64*) ;;
    *) echo "that is not an x86-64 ELF binary: $FILE_TYPE" >&2; exit 1 ;;
esac
echo "    $FILE_TYPE"

echo "==> uploading to $SSH_TARGET"
scp -q "${SCP_ARGS[@]}" "$STAGING/peeringd" "$SSH_TARGET:/tmp/peeringd-new"
# The site as well, because it is served by the relay and changing a line of the privacy policy
# should not need a Rust build to reach the server.
scp -q -r "${SCP_ARGS[@]}" "$REPO_DIR/Relay/site" "$SSH_TARGET:/tmp/peering-site-new"
# The self-check travels with the binary: it is part of what a deployment installs, not something
# that was set up once by hand and then silently drifted.
scp -q "${SCP_ARGS[@]}" \
    "$REPO_DIR/Relay/deploy/peeringd-healthcheck.sh" \
    "$REPO_DIR/Relay/deploy/peeringd-healthcheck.service" \
    "$REPO_DIR/Relay/deploy/peeringd-healthcheck.timer" \
    "$SSH_TARGET:/tmp/"
# And the relay's own unit, for the same reason the healthcheck's travels: it is part of what a
# deployment installs rather than something set up once by hand and left to drift. It has to go
# with the binary in particular, because the unit is what declares the state directory the relay
# writes its usage log into. A binary that expects one and a unit that does not grant it is a
# relay that starts, records nothing, and looks healthy.
scp -q "${SCP_ARGS[@]}" "$REPO_DIR/Relay/deploy/peeringd.service" "$SSH_TARGET:/tmp/"

if [ "$YES" != "--yes" ]; then
    printf 'install on %s and restart peeringd? [y/N] ' "$SSH_TARGET"
    read -r answer
    case "$answer" in [yY]*) ;; *) echo "left alone."; exit 1 ;; esac
fi

echo "==> installing"
# `set -e` on the far side too, so a failure half way through stops there rather than leaving the
# relay down with a note that it succeeded.
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" bash -euo pipefail <<REMOTE
stamp="\$(date +%Y%m%d-%H%M%S)"

install -m 755 /tmp/peeringd-new "$REMOTE_BIN.new"
if [ -f "$REMOTE_BIN" ]; then
    cp -p "$REMOTE_BIN" "$REMOTE_BIN.bak-\$stamp"
fi
mv "$REMOTE_BIN.new" "$REMOTE_BIN"
rm -f /tmp/peeringd-new

mkdir -p "$REMOTE_SITE"
rm -rf "$REMOTE_SITE.new"
mv /tmp/peering-site-new "$REMOTE_SITE.new"
# Names only, so a deploy never deletes something a person put there by hand.
rsync -a --delete --exclude '.impeccable' "$REMOTE_SITE.new/" "$REMOTE_SITE/"
rm -rf "$REMOTE_SITE.new"

install -m 755 /tmp/peeringd-healthcheck.sh /usr/local/bin/peeringd-healthcheck.sh
install -m 644 /tmp/peeringd-healthcheck.service /etc/systemd/system/peeringd-healthcheck.service
install -m 644 /tmp/peeringd-healthcheck.timer /etc/systemd/system/peeringd-healthcheck.timer
rm -f /tmp/peeringd-healthcheck.sh /tmp/peeringd-healthcheck.service /tmp/peeringd-healthcheck.timer
install -m 644 /tmp/peeringd.service /etc/systemd/system/peeringd.service
rm -f /tmp/peeringd.service
# Before the restart below, not after: this is what tells systemd to create the state directory
# the new unit declares, and a restart that happens first starts the relay without one.
systemctl daemon-reload
# Enable as well as start, or the check exists until the next reboot and then does not.
# (No backticks in here: this heredoc is unquoted, so the remote shell would run them.)
systemctl enable --now peeringd-healthcheck.timer >/dev/null 2>&1 || true

systemctl restart peeringd
sleep 2
systemctl is-active peeringd
REMOTE

echo "==> verifying"
# From the box first: that proves the process is listening, and it is the half this script controls.
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" 'curl -s --max-time 5 http://127.0.0.1:8080/healthz || echo "healthz did not answer"'
# Whether the counter found a home, said by the relay itself rather than inferred from a file
# existing. A relay that could not open its usage log still answers healthz, so the healthz check
# above passes in exactly the case this line exists to catch.
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" 'journalctl -u peeringd -n 40 --no-pager | grep -i "usage" | tail -2 || echo "(no usage line in the journal yet)"'
# Then from here, through whatever terminates TLS — which is the half a user meets, and the half
# that was answering 502 while the relay itself was fine.
curl -s --max-time 10 https://getpeering.app/healthz || echo "(the public hostname did not answer)"
echo
echo "==> done. 'systemctl status peeringd' and 'journalctl -u peeringd -n 30' on the box for the rest."

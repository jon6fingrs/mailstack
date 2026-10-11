#!/bin/sh
# mailstack mbsync entrypoint: write an mbsync config from environment
# variables, then sync every SYNC_INTERVAL seconds (or once, if 0).
#
# The password never goes into the config file: mbsync asks for it through
# PassCmd at login time, from the environment or a Docker secret file.
set -eu

log() { echo "mailstack: $(date '+%F %T') $*"; }
die() { echo "mailstack: ERROR: $*" >&2; exit 1; }

# Quote a value for mbsync's config syntax: "...", with \ and " escaped.
q() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }

: "${REMOTE_HOST:?set REMOTE_HOST (e.g. imap.fastmail.com)}"
: "${REMOTE_USER:?set REMOTE_USER}"
REMOTE_PORT=${REMOTE_PORT:-993}
TLS_TYPE=${TLS_TYPE:-IMAPS}
ACCOUNT_NAME=${ACCOUNT_NAME:-remote}
PATTERNS=${PATTERNS:-*}
SYNC=${SYNC:-PullNew}
SYNC_INTERVAL=${SYNC_INTERVAL:-300}

case "$ACCOUNT_NAME" in *[!A-Za-z0-9_-]*|'') die "ACCOUNT_NAME may only use letters, numbers, - and _" ;; esac
case "$SYNC_INTERVAL" in *[!0-9]*|'') die "SYNC_INTERVAL must be a number of seconds" ;; esac

if [ -n "${REMOTE_PASSWORD_FILE:-}" ]; then
  [ -r "$REMOTE_PASSWORD_FILE" ] || die "can't read REMOTE_PASSWORD_FILE=$REMOTE_PASSWORD_FILE"
  passcmd="cat $(printf '%s' "$REMOTE_PASSWORD_FILE" | sed "s/'/'\\\\''/g; s/.*/'&'/")"
elif [ -n "${REMOTE_PASSWORD:-}" ]; then
  passcmd="printenv REMOTE_PASSWORD"
else
  die "set REMOTE_PASSWORD or REMOTE_PASSWORD_FILE"
fi

[ -d /mail ] || die "/mail is not mounted"
[ -w /mail ] || die "/mail isn't writable by uid $(id -u):$(id -g), but it belongs to $(stat -c %u:%g /mail); set PUID=$(stat -c %u /mail) and PGID=$(stat -c %g /mail) in .env"

config=/tmp/mbsyncrc
umask 077
{
  echo "IMAPAccount $ACCOUNT_NAME"
  echo "Host $(q "$REMOTE_HOST")"
  echo "Port $REMOTE_PORT"
  echo "User $(q "$REMOTE_USER")"
  echo "PassCmd $(q "$passcmd")"
  echo "TLSType $TLS_TYPE"
  [ -z "${TLS_VERSIONS:-}" ] || echo "TLSVersions $TLS_VERSIONS"
  [ -z "${PIPELINE_DEPTH:-}" ] || echo "PipelineDepth $PIPELINE_DEPTH"
  echo
  echo "IMAPStore $ACCOUNT_NAME-remote"
  echo "Account $ACCOUNT_NAME"
  echo "UseNamespace no"
  echo
  echo "MaildirStore $ACCOUNT_NAME-local"
  echo "Path /mail/"
  echo "Inbox /mail/INBOX/"
  echo "SubFolders Verbatim"
  echo
  echo "Channel $ACCOUNT_NAME"
  echo "Far :$ACCOUNT_NAME-remote:"
  echo "Near :$ACCOUNT_NAME-local:"
  echo "Patterns $PATTERNS"
  # Archive mode: never delete anything locally, even if it's gone remotely.
  echo "Sync $SYNC"
  echo "Create Near"
  echo "Remove None"
  echo "Expunge None"
  echo "CopyArrivalDate yes"
  echo "SyncState *"
} > "$config"
umask 022

flags=-a
[ "${VERBOSE:-no}" != yes ] || flags=-Va

log "syncing $REMOTE_USER@$REMOTE_HOST into /mail every ${SYNC_INTERVAL}s (uid $(id -u))"
while :; do
  status=0
  mbsync -c "$config" $flags || status=$?
  if [ "$status" -ne 0 ]; then
    log "mbsync exited with status $status"
  fi
  [ "$SYNC_INTERVAL" -ne 0 ] || exit "$status"
  sleep "$SYNC_INTERVAL"
done

#!/bin/bash
# mailstack dovecot entrypoint: check settings, write the login file, start
# two small background jobs (search indexing, certificate reload), then run
# Dovecot in the foreground.
set -euo pipefail

log() { echo "mailstack: $*"; }
die() { echo "mailstack: ERROR: $*" >&2; exit 1; }

# Read VAR, or the contents of the file named by VAR_FILE (Docker secrets).
secret() {
  local name=$1 file_var="${1}_FILE"
  if [[ -n "${!file_var:-}" ]]; then
    [[ -r "${!file_var}" ]] || die "$file_var points to ${!file_var}, which can't be read"
    # Strip a trailing newline, which most editors add.
    printf '%s' "$(<"${!file_var}")"
  else
    printf '%s' "${!name:-}"
  fi
}

MAIL_USER=${MAIL_USER:-}
MAIL_PASSWORD=$(secret MAIL_PASSWORD)
PUID=${PUID:-1000}
PGID=${PGID:-$PUID}
INDEX_INTERVAL=${INDEX_INTERVAL:-120}
CERT_CHECK_INTERVAL=${CERT_CHECK_INTERVAL:-300}
export TLS_CERT_FILE=${TLS_CERT_FILE:-/etc/dovecot/ssl/tls.crt}
export TLS_KEY_FILE=${TLS_KEY_FILE:-/etc/dovecot/ssl/tls.key}
export SOLR_URL=${SOLR_URL:-http://solr:8983/solr/dovecot/}
export TIKA_URL=${TIKA_URL:-http://tika:9998/tika/}

[[ -n "$MAIL_USER" ]] || die "MAIL_USER is not set"
[[ "$MAIL_USER" != *[:[:space:]]* ]] || die "MAIL_USER can't contain spaces or ':'"
[[ -n "$MAIL_PASSWORD" ]] || die "set MAIL_PASSWORD or MAIL_PASSWORD_FILE"
[[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]] || die "PUID and PGID must be numbers"
[[ "$PUID" -ge 500 ]] || die "PUID must be 500 or higher (Dovecot refuses system users)"
[[ -r "$TLS_CERT_FILE" ]] || die "can't read TLS_CERT_FILE=$TLS_CERT_FILE"
[[ -r "$TLS_KEY_FILE" ]] || die "can't read TLS_KEY_FILE=$TLS_KEY_FILE"
[[ -d /mail ]] || die "/mail is not mounted"

if [[ "$TLS_CERT_FILE" == /etc/dovecot/ssl/tls.crt ]]; then
  log "no TLS_CERT_FILE given; using the built-in self-signed certificate"
fi

# A value starting with {SCHEME} is already a hash (from `doveadm pw`);
# anything else is a plain password and gets hashed here.
if [[ "$MAIL_PASSWORD" == \{*\}* ]]; then
  hash=$MAIL_PASSWORD
else
  hash=$(doveadm pw -s ARGON2ID -p "$MAIL_PASSWORD")
fi

# user:password:uid:gid:gecos:home:shell
umask 027
printf '%s:%s:%s:%s::/mail::\n' "$MAIL_USER" "$hash" "$PUID" "$PGID" > /etc/dovecot/users
chown root:dovecot /etc/dovecot/users
chmod 0640 /etc/dovecot/users
unset MAIL_PASSWORD MAIL_PASSWORD_FILE hash
umask 022

# mbsync writes new mail straight to disk, which doesn't trigger Dovecot's
# indexing. Queue an index run regularly; it only does work for new mail.
index_loop() {
  sleep 30
  while :; do
    doveadm index -u "$MAIL_USER" -q '*' >/dev/null 2>&1 \
      || log "couldn't queue search indexing (will retry)"
    sleep "$INDEX_INTERVAL"
  done
}

# Dovecot reads the certificate only at startup. When the files change (a
# renewal synced in from elsewhere), tell it to reload, but only once the
# certificate and key match, so a half-finished copy can't break TLS.
cert_stamp() { stat -L -c '%Y %s' "$TLS_CERT_FILE" "$TLS_KEY_FILE" 2>/dev/null || true; }
cert_matches_key() {
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$TLS_CERT_FILE" -noout -pubkey 2>/dev/null) || return 1
  key_pub=$(openssl pkey -in "$TLS_KEY_FILE" -pubout 2>/dev/null) || return 1
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}
cert_loop() {
  local last now
  last=$(cert_stamp)
  while sleep "$CERT_CHECK_INTERVAL"; do
    now=$(cert_stamp)
    [[ "$now" != "$last" ]] || continue
    if ! cert_matches_key; then
      log "certificate changed but doesn't match the key yet; waiting"
      continue
    fi
    log "certificate changed, reloading Dovecot"
    if doveadm reload; then
      last=$now
    else
      log "reload failed (will retry)"
    fi
  done
}

[[ "$INDEX_INTERVAL" == 0 ]] || index_loop &
[[ "$CERT_CHECK_INTERVAL" == 0 ]] || cert_loop &

log "serving /mail as $MAIL_USER (uid $PUID, gid $PGID)"
exec dovecot -F

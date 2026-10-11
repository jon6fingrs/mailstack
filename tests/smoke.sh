#!/bin/bash
# End-to-end test: mbsync pulls from a fake remote into a Maildir, Dovecot
# serves it over IMAPS, Dovecot's flatcurve index + Tika make it searchable.
#
#   tests/smoke.sh          # build, run, test, clean up
#   KEEP=1 tests/smoke.sh   # leave the stack running afterwards
set -euo pipefail

cd "$(dirname "$0")"
export TEST_DIR
TEST_DIR=$(mktemp -d)
COMPOSE=(docker compose -f compose.test.yaml)
USER_NAME=tester
USER_PASS='p@ss "word" with spaces'

pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*" >&2
  "${COMPOSE[@]}" logs --no-color --tail 80 >&2 || true
  exit 1
}
cleanup() {
  if [[ -z "${KEEP:-}" ]]; then
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup EXIT

# Wait up to $1 seconds for the command after it to succeed.
wait_for() {
  local timeout=$1; shift
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < end)) || return 1
    sleep 2
  done
}

new_cert() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" \
    -keyout "$TEST_DIR/ssl/key.pem" -out "$TEST_DIR/ssl/cert.pem" 2>/dev/null
  # Same permissions a synced Let's Encrypt key usually has.
  chmod 0600 "$TEST_DIR/ssl/key.pem"
}

# The fake remote gets a certificate from a private test CA, which the
# mbsync container is given as its list of trusted CAs.
remote_ca() {
  local d=$TEST_DIR/remote
  mkdir -p "$d"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=mailstack test CA" \
    -keyout "$d/ca.key" -out "$TEST_DIR/remote-ca.pem" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=remote" \
    -keyout "$d/tls.key" -out "$d/tls.csr" 2>/dev/null
  openssl x509 -req -in "$d/tls.csr" -CA "$TEST_DIR/remote-ca.pem" -CAkey "$d/ca.key" \
    -CAcreateserial -days 2 -extfile <(printf 'subjectAltName=DNS:remote') \
    -out "$d/tls.crt" 2>/dev/null
  chmod 0644 "$TEST_DIR/remote-ca.pem" "$d/tls.crt" "$d/tls.key"
}

mkdir -p "$TEST_DIR/mail" "$TEST_DIR/ssl"
remote_ca
chown 1026:100 "$TEST_DIR/mail"
printf '%s\n' "$USER_PASS" > "$TEST_DIR/mail_password"
new_cert

echo "== building and starting"
"${COMPOSE[@]}" up -d --build --wait --wait-timeout 300 remote tika dovecot \
  || fail "stack didn't start"

dc() { "${COMPOSE[@]}" exec -T "$@"; }
imap() {
  # IMAP over TLS on 993, verified against the test certificate.
  dc dovecot curl -sS --cacert /ssl/cert.pem --user "$USER_NAME:$USER_PASS" "$@"
}

echo "== seeding the fake remote"
seed() {
  local box=$1 subject=$2 body=$3 msgid=$4
  printf 'From: Sender <sender@example.com>\r\nTo: someone@example.com\r\nSubject: %s\r\nMessage-ID: <%s@example.com>\r\nDate: Mon, 5 Oct 2026 10:00:00 +0000\r\n\r\n%s\r\n' \
    "$subject" "$msgid" "$body" | dc remote doveadm save -u someone@example.com -m "$box"
}
dc remote doveadm mailbox create -u someone@example.com "Work Stuff" Archive
seed INBOX "Plain one" "the zebrafish swims at midnight" m1
seed "Work Stuff" "Folder with a space" "the narwhal report is attached" m2
seed Archive "Accented" "Meet me at the Café Olé tomorrow" m3
# A Word attachment: Dovecot can't read .docx itself, so only Tika can index it.
docx_base64() {
  python3 - <<'PY'
import base64, io, zipfile
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
    z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
    z.writestr("word/document.xml", '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>The secret word is quokka.</w:t></w:r></w:p></w:body></w:document>')
print(base64.encodebytes(buf.getvalue()).decode().replace("\n", "\r\n"), end="")
PY
}
{
  printf '%s\r\n' \
    'From: Sender <sender@example.com>' 'To: someone@example.com' \
    'Subject: Attachment test' 'Message-ID: <m4@example.com>' \
    'Date: Mon, 5 Oct 2026 11:00:00 +0000' 'MIME-Version: 1.0' \
    'Content-Type: multipart/mixed; boundary="b1"' '' \
    '--b1' 'Content-Type: text/plain' '' 'See attached.' \
    '--b1' 'Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document' \
    'Content-Disposition: attachment; filename="notes.docx"' 'Content-Transfer-Encoding: base64' ''
  docx_base64
  printf '%s\r\n' '--b1--'
} | dc remote doveadm save -u someone@example.com -m INBOX

echo "== starting mbsync"
"${COMPOSE[@]}" up -d mbsync || fail "mbsync didn't start"
has_mail() { [[ -n "$(find "$TEST_DIR/mail/$1/cur" "$TEST_DIR/mail/$1/new" -type f 2>/dev/null)" ]]; }
wait_for 60 has_mail "Work Stuff" || fail "mbsync didn't sync 'Work Stuff'"
pass "mbsync synced folders, including one with a space"

count=$(find "$TEST_DIR/mail/INBOX" -path '*/cur/*' -o -path '*/new/*' | grep -c . || true)
[[ "$count" -eq 2 ]] || fail "expected 2 messages in INBOX, found $count"
owner=$(stat -c '%u:%g' "$(find "$TEST_DIR/mail/INBOX/new" "$TEST_DIR/mail/INBOX/cur" -type f | head -1)")
[[ "$owner" == "1026:100" ]] || fail "mail files are owned by $owner, expected 1026:100"
pass "mail files belong to PUID:PGID (1026:100)"

echo "== IMAP"
caps=$(imap imaps://localhost/ -X CAPABILITY) || fail "IMAPS login failed"
pass "IMAPS login with a password containing quotes and spaces"
grep -q 'SEARCH=FUZZY' <<<"$caps" && echo "INFO: server advertises SEARCH=FUZZY" || echo "INFO: no SEARCH=FUZZY capability"
grep -q 'SPECIAL-USE' <<<"$caps" || fail "no SPECIAL-USE capability"
! grep -q 'COMPRESS' <<<"$caps" || fail "COMPRESS is advertised; iPhone Mail drops the connection after enabling it"
pass "COMPRESS isn't offered (iPhone Mail breaks with it)"

list=$(imap imaps://localhost/ -X 'LIST "" "*" RETURN (SPECIAL-USE)') || fail "LIST failed"
grep -q '(\\Archive) "/" Archive' <<<"$list" || fail "Archive isn't marked \\Archive: $list"
pass "Archive folder is marked \\Archive"

if dc dovecot curl -sS --cacert /ssl/cert.pem --user "$USER_NAME:wrong" imaps://localhost/ -X CAPABILITY >/dev/null 2>&1; then
  fail "a wrong password was accepted"
fi
pass "wrong password is rejected"

echo "== search (flatcurve index + Tika)"
# Ask the index directly (no IMAP search, which would index on demand), so a
# hit proves the background indexing job put the message there.
in_index() {  # in_index <mailbox> <criteria...>
  local box=$1; shift
  # Prints "<mailbox>: <uids>" on a hit, "<mailbox>: no results" otherwise.
  dc dovecot doveadm fts lookup -u "$USER_NAME" mailbox "$box" "$@" 2>/dev/null | grep -qE ': [0-9]'
}
wait_for 90 in_index INBOX body zebrafish || fail "background indexing didn't index INBOX"
pass "background indexing put new mail into the search index"
in_index INBOX text quokka || fail "the Word attachment's text isn't in the index"
pass "attachment text is in the index (Tika)"

search() {  # search <mailbox> <criteria...>
  local box=$1; shift
  imap "imaps://localhost/$box" -X "SEARCH $*" | tr -d '\r'
}
expect() {  # expect <description> <expected reply> <mailbox> <criteria...>
  local what=$1 want=$2 box=$3; shift 3
  local got; got=$(search "$box" "$@")
  [[ "$got" == "$want" ]] || fail "$what: SEARCH $* in $box gave '$got', expected '$want'"
  pass "$what"
}
expect "body search"                                 "* SEARCH 1" INBOX BODY zebrafish
expect "search finds text inside a Word attachment"  "* SEARCH 2" INBOX TEXT quokka
expect "search in a folder with a space"             "* SEARCH 1" "Work%20Stuff" BODY narwhal
expect "'cafe' finds 'Café' (accents ignored)"       "* SEARCH 1" Archive BODY cafe
expect "'swimming' finds 'swims' (word variants)"    "* SEARCH 1" INBOX BODY swimming
expect "'zebra' finds 'zebrafish' (start of word)"   "* SEARCH 1" INBOX BODY zebra
expect "'narw' finds 'narwhal'"                      "* SEARCH 1" "Work%20Stuff" BODY narw

echo "== All Mail and Flagged"
list=$(imap imaps://localhost/ -X 'LIST "" "Virtual/*" RETURN (SPECIAL-USE)') || fail "LIST Virtual failed"
grep -q '(\\All) "/" Virtual/All' <<<"$list" || fail "Virtual/All missing or not \\All: $list"
grep -q '(\\Flagged) "/" Virtual/Flagged' <<<"$list" || fail "Virtual/Flagged missing: $list"
pass "Virtual/All and Virtual/Flagged are listed with their special-use flags"
lsub=$(imap imaps://localhost/ -X 'LSUB "" "Virtual/*"') || fail "LSUB failed"
grep -q 'Virtual/All' <<<"$lsub" || fail "Virtual/All isn't subscribed, so phones won't show it: $lsub"
pass "the virtual folders are subscribed, so mail apps show them"
got=$(search Virtual/All BODY narwhal)
[[ "$got" =~ ^\*\ SEARCH\ [0-9]+$ ]] || fail "searching Virtual/All for narwhal gave '$got', expected one match"
pass "searching Virtual/All finds mail from another folder"
messages() {  # messages <mailbox>
  imap imaps://localhost/ -X "STATUS \"$1\" (MESSAGES)" | tr -d '\r' | sed -E 's/.*MESSAGES ([0-9]+).*/\1/'
}
[[ "$(messages Virtual/All)" == 4 ]] || fail "Virtual/All has $(messages Virtual/All) messages, expected 4"
pass "Virtual/All holds all 4 messages"
[[ "$(messages Virtual/Flagged)" == 0 ]] || fail "Virtual/Flagged isn't empty before flagging"
imap "imaps://localhost/Work%20Stuff" -X 'STORE 1 +FLAGS (\Flagged)' >/dev/null || fail "couldn't flag a message"
[[ "$(messages Virtual/Flagged)" == 1 ]] || fail "flagged message didn't show up in Virtual/Flagged"
pass "flagging a message adds it to Virtual/Flagged"

echo "== later mail"
seed INBOX "Later" "the axolotl arrived after indexing" m5
wait_for 60 in_index INBOX body axolotl || fail "mail synced after the index existed wasn't indexed"
pass "mbsync keeps syncing alongside the index folders, and later mail is indexed"

echo "== archive semantics"
dc remote doveadm expunge -u someone@example.com mailbox INBOX all
sleep 12
count=$(find "$TEST_DIR/mail/INBOX" -path '*/cur/*' -o -path '*/new/*' | grep -c . || true)
# 2 seeded at the start + 1 seeded later; the remote now has none.
[[ "$count" -eq 3 ]] || fail "deleting on the remote removed local mail ($count left)"
pass "deleting mail on the remote keeps the local copy"

echo "== certificate reload"
served_cert() {
  dc dovecot sh -c 'echo | openssl s_client -connect localhost:993 2>/dev/null | openssl x509 -noout -fingerprint -sha256'
}
before=$(served_cert)
new_cert
expected=$(openssl x509 -in "$TEST_DIR/ssl/cert.pem" -noout -fingerprint -sha256)
serving_new_cert() { [[ "$(served_cert)" == "$expected" ]]; }
wait_for 60 serving_new_cert || fail "Dovecot still serves the old certificate"
[[ "$before" != "$expected" ]] || fail "test certificate didn't change"
pass "a renewed certificate is picked up without a restart"

echo "== logs"
# Expected: an index run cut off by the certificate reload (it's retried on
# the next run).
expected_errors='indexer-worker.*(auth-userdb.*Disconnected unexpectedly|lookup failed: Unexpectedly disconnected from auth service)'
if "${COMPOSE[@]}" logs --no-color dovecot mbsync | grep -iE 'panic|fatal|error' | grep -vE "$expected_errors"; then
  fail "unexpected errors in the logs (above)"
fi
pass "no unexpected errors in the Dovecot or mbsync logs"

echo "All tests passed."

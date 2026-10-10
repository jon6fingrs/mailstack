#!/bin/bash
# End-to-end test: mbsync pulls from a fake remote into a Maildir, Dovecot
# serves it over IMAPS, Solr + Tika make it searchable.
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
"${COMPOSE[@]}" up -d --build --wait --wait-timeout 300 remote solr tika dovecot \
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

list=$(imap imaps://localhost/ -X 'LIST "" "*" RETURN (SPECIAL-USE)') || fail "LIST failed"
grep -q '(\\Archive) "/" Archive' <<<"$list" || fail "Archive isn't marked \\Archive: $list"
pass "Archive folder is marked \\Archive"

if dc dovecot curl -sS --cacert /ssl/cert.pem --user "$USER_NAME:wrong" imaps://localhost/ -X CAPABILITY >/dev/null 2>&1; then
  fail "a wrong password was accepted"
fi
pass "wrong password is rejected"

echo "== search (Solr + Tika)"
solr_docs() {
  dc solr curl -s 'http://localhost:8983/solr/dovecot/select?q=*:*&rows=0&wt=json' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["response"]["numFound"])'
}
solr_has_all() { [[ "$(solr_docs)" -ge 4 ]]; }
wait_for 90 solr_has_all || fail "Solr didn't receive the messages (has $(solr_docs))"
pass "background indexing put all 4 messages into Solr"

search() {  # search <mailbox> <criteria...>
  local box=$1; shift
  imap "imaps://localhost/$box" -X "SEARCH $*" | tr -d '\r'
}
[[ "$(search INBOX BODY zebrafish)" == "* SEARCH 1" ]] || fail "BODY zebrafish: $(search INBOX BODY zebrafish)"
pass "body search"
[[ "$(search INBOX TEXT quokka)" == "* SEARCH 2" ]] || fail "attachment search: $(search INBOX TEXT quokka)"
pass "search finds text inside a Word attachment (Tika)"
[[ "$(search Work%20Stuff BODY narwhal)" == "* SEARCH 1" ]] || fail "search in folder with a space"
pass "search in a folder with a space"
[[ "$(search Archive BODY cafe)" == "* SEARCH 1" ]] || fail "accent-insensitive search: $(search Archive BODY cafe)"
pass "'cafe' finds 'Café' (accent folding)"
[[ "$(search INBOX BODY swimming)" == "* SEARCH 1" ]] || fail "stemming: $(search INBOX BODY swimming)"
pass "'swimming' finds 'swims' (stemming)"
[[ "$(search INBOX FUZZY BODY zebrafsh)" == "* SEARCH 1" ]] || fail "fuzzy search: $(search INBOX FUZZY BODY zebrafsh)"
pass "FUZZY search tolerates a typo ('zebrafsh')"

"${COMPOSE[@]}" stop solr >/dev/null
if search INBOX BODY narwhal >/dev/null 2>&1; then
  fail "search still worked with Solr stopped, so it isn't using Solr"
fi
"${COMPOSE[@]}" start solr >/dev/null
wait_for 120 search INBOX BODY zebrafish || fail "search didn't recover after Solr restarted"
pass "searches go through Solr (and recover when it comes back)"

echo "== archive semantics"
dc remote doveadm expunge -u someone@example.com mailbox INBOX all
sleep 12
count=$(find "$TEST_DIR/mail/INBOX" -path '*/cur/*' -o -path '*/new/*' | grep -c . || true)
[[ "$count" -eq 2 ]] || fail "deleting on the remote removed local mail ($count left)"
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
# Expected: Solr errors while the test had it stopped, and an index run cut
# off by the certificate reload (it's retried on the next run).
expected_errors='fts-solr: .*Lookup failed: (Failed to lookup host solr|connect\(.*\) failed: Connection refused|503 Service Unavailable)'
expected_errors+='|indexer-worker.*(auth-userdb.*Disconnected unexpectedly|lookup failed: Unexpectedly disconnected from auth service)'
if "${COMPOSE[@]}" logs --no-color dovecot mbsync | grep -iE 'panic|fatal|error' | grep -vE "$expected_errors"; then
  fail "unexpected errors in the logs (above)"
fi
pass "no unexpected errors in the Dovecot or mbsync logs"

echo "All tests passed."

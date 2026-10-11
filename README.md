# mailstack

Keep a complete, searchable copy of a remote email account (Fastmail, Gmail,
any IMAP provider) on your own machine, and read it from any mail app as if it
were the real thing.

- **mbsync** copies new mail down every few minutes. It never deletes
  anything locally, so you can empty or trim the remote mailbox and keep
  everything here.
- **Dovecot** serves the copy over IMAP (with TLS) to your phone, laptop or
  webmail.
- **Fast search** across the whole archive, including text inside
  attachments (PDF, Word, Excel and more), using Dovecot's built-in search
  index plus **Tika** to read attachments.
- **All Mail** and **Flagged** folders that gather messages from every folder.

It's the successor to [mbsync-dovecot](https://github.com/jon6fingrs/mbsync-dovecot),
written up in the [Making an Automatic Email Backup](https://thehelpfulidiot.com/making-an-automatic-email-backup)
series. Coming from those images? See [MIGRATING.md](MIGRATING.md).

```text
 remote IMAP ──mbsync──▶  Maildir on disk  ◀──Dovecot──▶ your mail apps (IMAPS)
                          (+ search index)       │
                                               Tika (reads attachments,
                                               private network only)
```

## Quick start

```bash
git clone https://github.com/jon6fingrs/mailstack && cd mailstack
cp .env.example .env
nano .env                  # fill in the settings
docker compose up -d
docker compose logs -f     # watch the first sync
```

Then add an IMAP account in your mail app: server = this machine, port =
`IMAPS_PORT` (993), SSL on, user name and password = `MAIL_USER` and
`MAIL_PASSWORD`. For sending, use your provider's normal SMTP settings; this
stack only receives.

The first sync of a big mailbox takes a while, and so does building the search
index (which happens in the background, after mail arrives). Search still
works during that time; it just gets faster once indexing has caught up.

## Settings

Everything is set in `.env`; [.env.example](.env.example) explains each line.

| Setting | Default | What it does |
|---|---|---|
| `MAIL_DIR` | (required) | Folder holding the archive (Maildir). |
| `PUID`, `PGID` | 1000 | Owner of `MAIL_DIR`. Both containers create files as this user. |
| `REMOTE_HOST`, `REMOTE_USER`, `REMOTE_PASSWORD` | (required) | The account to copy. Use an app password where the provider offers one. |
| `REMOTE_PORT`, `TLS_TYPE` | 993, `IMAPS` | Use `TLS_TYPE=STARTTLS` with port 143 if your provider needs it. |
| `ACCOUNT_NAME` | `remote` | A label for the account inside mbsync. |
| `SYNC_INTERVAL` | 300 | Seconds between checks for new mail. `0` syncs once and exits (for an external timer). |
| `MAIL_USER`, `MAIL_PASSWORD` | (required) | Login for *your* IMAP server. The password can be plain text or a hash from `doveadm pw`. |
| `IMAPS_PORT` | 993 | Port mail apps connect to. |
| `CERT_DIR`, `TLS_CERT_FILE`, `TLS_KEY_FILE` | self-signed | Your certificate. See below. |
| `TZ` | `UTC` | Time zone for log timestamps. |

Less common settings, set under `environment:` in `compose.yaml`:

| Container | Setting | Default | What it does |
|---|---|---|---|
| mbsync | `PATTERNS` | `*` | Which folders to copy, in [mbsync syntax](https://isync.sourceforge.io/mbsync.html), e.g. `* !Trash !Spam`. |
| mbsync | `SYNC` | `PullNew` | mbsync's `Sync` option. The default only adds new mail and never changes or deletes anything. |
| mbsync | `PIPELINE_DEPTH`, `TLS_VERSIONS` | mbsync's | Passed straight to mbsync, for picky servers. |
| mbsync | `VERBOSE` | `no` | `yes` logs every folder on every sync. |
| dovecot | `INDEX_INTERVAL` | 120 | Seconds between background indexing runs for newly synced mail. |
| dovecot | `CERT_CHECK_INTERVAL` | 300 | Seconds between checks for a renewed certificate. |

### Keeping passwords out of the environment

Environment variables show up in `docker inspect`. Both passwords can instead
be read from files with `MAIL_PASSWORD_FILE` and `REMOTE_PASSWORD_FILE`, which
works with [Docker secrets](https://docs.docker.com/compose/how-tos/use-secrets/).
The remote password is never written into mbsync's config file either way;
mbsync reads it only when it logs in.

## Certificates

Without a certificate, Dovecot uses a self-signed one and mail apps will ask
you to trust it. To use a real one (for example a Let's Encrypt certificate
your reverse proxy already has), point `CERT_DIR` at its folder and name the
files:

```ini
CERT_DIR=/home/me/certs
TLS_CERT_FILE=/ssl/fullchain.pem
TLS_KEY_FILE=/ssl/privkey.pem
```

The folder is mounted read-only and the container never changes it. When the
files are renewed, Dovecot reloads them by itself within
`CERT_CHECK_INTERVAL` (once the new certificate and key match), so there's no
need to restart anything.

## Search

Searches run on the server, so they cover the whole archive, not just what
your phone has downloaded. In practice:

- Words match their variants: *invoice* finds *invoices*, *swimming* finds
  *swims*.
- Accents and case don't matter: *cafe* finds *Café*.
- Text inside attachments is searchable (via Tika).
- Partial words match from their start: *invo* finds *invoice*, *447*
  finds *4471*. Fragments from the middle of a word don't (*voice* won't
  find *invoice*); see below to turn that on. (iPhone Mail searches mail
  already on the phone as you type, and asks the server when you press
  Search; this is what the server does with whatever you typed.)
- Search **Virtual/All** to search every folder at once.

New mail is indexed in the background within `INDEX_INTERVAL` of arriving.
Anything not yet indexed is indexed on the spot when you search, so results
are always complete.

The index is Dovecot's built-in [flatcurve](https://doc.dovecot.org/latest/core/plugins/fts_flatcurve.html)
engine. Each folder gets an `fts-flatcurve` directory next to its mail; expect
the index to take roughly a third as much space as the mail itself. It can
always be rebuilt (see below), so it's fine to leave it out of backups.

To also match fragments from the middle of words, mount a file into
`/etc/dovecot/conf.d/` containing `fts flatcurve { substring_search = yes }`
and rebuild the index. It makes the index about three times bigger.

## All Mail and Flagged

Two extra folders appear under **Virtual**:

- **Virtual/All**: every message in the archive except Trash and Junk/Spam,
  in one list. Searching it searches everything at once.
- **Virtual/Flagged**: every flagged message, from any folder. Flag or unflag
  a message anywhere and it appears or disappears here.

They're live views, not copies: nothing is duplicated on disk, and changes
made in them (flags, read state, deleting) apply to the real message. To
change which folders they cover, mount your own copy of `dovecot/virtual/`
over `/etc/dovecot/virtual` (one folder pattern per line, `-` to exclude).

## How it fits together

- The archive is plain Maildir: one file per message, readable by any tool,
  easy to back up. Dovecot keeps its own small index files alongside.
- The search index lives next to the mail (`fts-flatcurve` in each folder),
  and the virtual folders keep a small index in `.dovecot-virtual`. Both are
  hidden from mail apps and from mbsync.
- Tika sits on an internal Docker network with no published ports and no
  internet access, since it has no authentication.
- Nothing runs `chown` or `chmod` on your files at startup.

### Rebuilding the search index

Needed once after moving from an older setup, or if the index is lost or
damaged. It runs in the foreground; a large archive can take a while, and
mail keeps working meanwhile.

```bash
docker compose exec dovecot doveadm fts rescan -u MAIL_USER
docker compose exec dovecot doveadm index -u MAIL_USER '*'
```

## Push notifications on iPhone

The iPhone's Mail app only does background push for iCloud, Exchange and a few
large providers. For any other IMAP server, including this one, it shows new
mail instantly while the app is open, and otherwise checks on the schedule in
Settings → Apps → Mail → Mail Accounts → Fetch New Data. To get mail onto this
server sooner, lower `SYNC_INTERVAL` (120 is reasonable for most providers).

## Testing

`tests/smoke.sh` builds the images and runs the whole stack against a
throwaway IMAP server: syncing, login, background indexing, search (including
attachments, accents, word variants and partial words), the All Mail and
Flagged folders, certificate reload, and that remote deletions never remove
local mail. GitHub Actions runs it on every push.

```bash
sudo tests/smoke.sh
```

## Versions

| Component | Version |
|---|---|
| Dovecot | 2.4.5 (official `dovecot/dovecot` image) |
| mbsync (isync) | 1.5.1 (Debian 13) |
| Tika | 4.1.0 |

# Moving from the old images

This is for anyone running the earlier `thehelpfulidiot/dovecot`,
`thehelpfulidiot/mbsync` and `thehelpfulidiot/solr` images (the
[mbsync-dovecot](https://github.com/jon6fingrs/mbsync-dovecot) setup). Your
mail folder works as is, so nothing gets downloaded again. Solr is no longer
needed: Dovecot keeps its own search index, which you build once (step 5).

## 1. Translate your settings

| Old (environment) | New (`.env`) | Notes |
|---|---|---|
| `email_username` | `MAIL_USER` | Keep it the same so mail apps don't need new login details. |
| `email_password` | `MAIL_PASSWORD` | |
| `PUID` | `PUID` | Also set `PGID` to the group that owns the mail (`ls -ln` on the mail folder; the old images used group `100`). |
| `host_name` | `REMOTE_HOST` | |
| `port` | `REMOTE_PORT` | |
| `remote_username` | `REMOTE_USER` | |
| `remote_password` | `REMOTE_PASSWORD` | |
| `mailbox_name` | `ACCOUNT_NAME` | Keep the same value. |
| `ssltype` | — | IMAPS is the default. For STARTTLS, set `TLS_TYPE=STARTTLS` on mbsync. |
| `sslversions` | — | Not needed: the defaults only allow modern TLS. |
| `cron=yes` | `SYNC_INTERVAL` | Seconds between syncs (default 300). `0` syncs once and exits. |
| `ssl_cert`, `ssl_key` | `TLS_CERT_FILE`, `TLS_KEY_FILE` | Full paths inside the container, e.g. `/ssl/cert.pem`. Mount the folder with `CERT_DIR`. |
| `ssl`, `auth_allow_cleartext`, `disable_plaintext_auth` | — | TLS is always on; passwords are only accepted over TLS. |
| `server_address`, `dh_pem` | — | No longer used. |

## 2. Check disk space

The new search index lives next to the mail and takes roughly a third as much
space as the mail itself. Check that there's room:

```bash
sudo du -sh /path/to/mail      # size of the archive
df -h /path/to/mail            # free space on that disk
```

## 3. Stop the old containers

From the folder with the old compose file:

```bash
docker compose down
```

This keeps the old volumes, so you can always go back.

## 4. Start the new ones

From the folder with the new `compose.yaml` and `.env`:

```bash
docker compose pull
docker compose up -d
docker compose logs -f     # Ctrl+C to stop watching
```

Mail apps can connect right away; nothing gets downloaded again.

## 5. Build the search index

The old Solr index can't be reused, so the new one gets built once. Dovecot
starts on that by itself in the background a couple of minutes after
starting. To watch it finish instead, run it yourself; it prints nothing
until it's done, and a large archive can take an hour or more, mostly spent
reading attachments:

```bash
docker compose exec dovecot doveadm index -u YOUR_MAIL_USER '*'
```

Mail works normally meanwhile. Searching a folder that hasn't been indexed yet
indexes it first, so a search may be slow (or time out) until this finishes.

When you're happy with the new setup, the old Solr volume can go:

```bash
docker volume ls | grep -i solr
docker volume rm THE_OLD_SOLR_VOLUME
```

## Going back

```bash
docker compose down        # in the new folder
docker compose up -d       # in the old folder
```

The old Dovecot reads the mail folder as before and ignores the new index
folders (`fts-flatcurve`, `.dovecot-virtual`).

## Coming from mailstack's first (Solr) version

`docker compose pull`, replace `compose.yaml` with the current one, remove
`SOLR_HEAP` from `.env`, run `docker compose up -d --remove-orphans`, then
build the index as in step 5. Afterwards
`docker volume rm mailstack_solr-data` frees Solr's space.

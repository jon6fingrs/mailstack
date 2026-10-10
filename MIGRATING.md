# Moving from the old images

This is for anyone running the earlier `thehelpfulidiot/dovecot`,
`thehelpfulidiot/mbsync` and `thehelpfulidiot/solr` images (the
[mbsync-dovecot](https://github.com/jon6fingrs/mbsync-dovecot) setup). Your
mail folder works as is, and the search index can be copied over, so nothing
gets downloaded or rebuilt.

## 1. Translate your settings

| Old (environment) | New (`.env`) | Notes |
|---|---|---|
| `email_username` | `MAIL_USER` | **Keep it exactly the same.** The search index is stored per username. |
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

## 2. Find your old search index

```bash
docker volume ls | grep -i solr
```

Note the name (for example `email_solr-data1`). If the old Solr mounted the
volume at `/var/solr` instead of at `/var/solr/data/dovecot/data/index`, the
index is inside it at `data/dovecot/data/index`; adjust the copy command below.

## 3. Stop the old containers

From the folder with the old compose file:

```bash
docker compose down
```

This keeps the volumes, so you can always go back.

## 4. Create the new stack without starting it, then copy the index

From the folder with the new `compose.yaml` and `.env`:

```bash
docker compose pull
docker compose create

OLD_VOLUME=email_solr-data1   # from step 2
docker run --rm --user root --entrypoint bash \
  -v "$OLD_VOLUME":/old:ro -v mailstack_solr-data:/var/solr \
  ghcr.io/jon6fingrs/mailstack-solr:latest -c '
    set -e
    mkdir -p /var/solr/data/dovecot/data/index
    cp -a /old/. /var/solr/data/dovecot/data/index/
    chown -R solr:solr /var/solr
    echo "copied $(du -sh /var/solr/data/dovecot/data/index | cut -f1)"'
```

The old volume is only read, never changed.

## 5. Start it

```bash
docker compose up -d
docker compose logs -f
```

Then check that search still answers from the old index:

```bash
docker compose exec dovecot doveadm search -u YOUR_MAIL_USER body SOMEWORD
```

## Going back

```bash
docker compose down        # in the new folder
docker compose up -d       # in the old folder
```

The new Dovecot keeps the mail folder in a format the old one reads.

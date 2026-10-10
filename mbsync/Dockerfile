# mbsync (isync) from Debian stable. Runs as an unprivileged user; set
# `user: "PUID:PGID"` in compose to match the owner of the mail archive.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends isync ca-certificates tini tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 entrypoint.sh /usr/local/bin/mailstack-mbsync

ENV HOME=/tmp
RUN mkdir -p /mail
VOLUME ["/mail"]
USER 1000:1000

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/mailstack-mbsync"]

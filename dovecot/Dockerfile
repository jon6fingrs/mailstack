# Dovecot's official image (built with Solr support), with mailstack's
# config and entrypoint. The -root variant lets Dovecot listen on 993 and
# access mail as whatever PUID owns the archive.
ARG DOVECOT_VERSION=2.4.5
FROM dovecot/dovecot:${DOVECOT_VERSION}-root

RUN rm -f /etc/dovecot/conf.d/* /etc/dovecot/vendor.d/*
COPY dovecot.conf /etc/dovecot/dovecot.conf
COPY --chmod=0755 entrypoint.sh /usr/local/bin/mailstack-entrypoint

RUN mkdir -p /mail
VOLUME ["/mail"]
EXPOSE 143 993

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD doveadm service status imap-login | grep -q '^listening: y' || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/mailstack-entrypoint"]

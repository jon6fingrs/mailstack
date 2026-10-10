# Solr with Dovecot's schema. Based on the slim image plus the one module
# the schema needs (ICU folding, so "cafe" also finds "Café").
ARG SOLR_VERSION=9.11.0
FROM solr:${SOLR_VERSION} AS full

FROM solr:${SOLR_VERSION}-slim
COPY --from=full /opt/solr/modules/analysis-extras /opt/solr/modules/analysis-extras

ENV SOLR_MODULES=analysis-extras \
    SOLR_HEAP=1g

COPY conf/ /opt/mailstack/solr-conf/
COPY init-dovecot-core.sh /docker-entrypoint-initdb.d/

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s \
  CMD curl -fs http://localhost:8983/solr/dovecot/admin/ping >/dev/null || exit 1

# Sourced by the Solr image before Solr starts (see /docker-entrypoint-initdb.d).
# Creates the "dovecot" core on first start, and on every start replaces its
# config with the one in this image, so updating the image updates the config
# while the index itself stays in the /var/solr volume.

mailstack_core=/var/solr/data/dovecot
mkdir -p "$mailstack_core/conf"
# Remove config files from older setups (managed schema, sample word lists).
find "$mailstack_core/conf" -mindepth 1 -delete
cp -r /opt/mailstack/solr-conf/. "$mailstack_core/conf/"
if [ ! -f "$mailstack_core/core.properties" ]; then
  echo "name=dovecot" > "$mailstack_core/core.properties"
  echo "mailstack: created the dovecot core"
fi
unset mailstack_core

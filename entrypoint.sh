#!/bin/sh
set -e

# The Nova listener binds $PORT (default 8080) via config/prod_sys.config.src;
# relx substitutes ${VAR} in the .src config at boot. Provide the DB via
# SEKISHO_DB_* and the secrets SEKISHO_MASTER_KEY + SEKISHO_ADMIN_TOKEN.
: "${PORT:=8080}"
export PORT
export RELX_REPLACE_OS_VARS=true

exec /app/bin/sekisho foreground

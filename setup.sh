#!/bin/bash
#
# First-run install, for the `setup` service in compose.yaml. Idempotent: a no-op
# once config.json exists, so it is safe on every `up`.
#
# Why first install needs a separate service at all:
# docs/USAGE.md#why-there-is-a-separate-setup-service

set -e

CONFIG="${CONFIG:-/opt/config/config.json}"

if [ -f "$CONFIG" ]; then
  echo "setup: $CONFIG already exists, nothing to do."
  exit 0
fi

for v in NODEBB_URL NODEBB_SECRET MONGO_HOST MONGO_PORT MONGO_USERNAME \
         MONGO_PASSWORD MONGO_DATABASE ADMIN_USERNAME ADMIN_EMAIL ADMIN_PASSWORD; do
  if [ -z "${!v:-}" ]; then
    echo "setup: $v is not set. Copy .env.example to .env and fill it in." >&2
    exit 1
  fi
done

echo "setup: installing NodeBB against ${MONGO_HOST}:${MONGO_PORT}/${MONGO_DATABASE}"

# node, not string concatenation: a password containing a quote or backslash has
# to survive into valid JSON. Colon key form here (mongo:host), not the
# double-underscore env form the running forum uses.
setup_json=$(node -e '
const e = process.env;
process.stdout.write(JSON.stringify({
  url: e.NODEBB_URL,
  secret: e.NODEBB_SECRET,
  // Pinned. nodebb setup otherwise copies the port out of url, leaving
  // NodeBB listening somewhere the port mapping does not target.
  port: "4567",
  database: "mongo",
  "mongo:host": e.MONGO_HOST,
  "mongo:port": e.MONGO_PORT,
  "mongo:username": e.MONGO_USERNAME,
  "mongo:password": e.MONGO_PASSWORD,
  "mongo:database": e.MONGO_DATABASE,
  "admin:username": e.ADMIN_USERNAME,
  "admin:email": e.ADMIN_EMAIL,
  "admin:password": e.ADMIN_PASSWORD,
  "admin:password:confirm": e.ADMIN_PASSWORD,
}));
')

cd /usr/src/app
./nodebb setup "$setup_json" --config="$CONFIG"

echo "setup: done. config.json written to $CONFIG"

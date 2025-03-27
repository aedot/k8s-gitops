#!/bin/bash

set -o nounset
set -o errexit

OUTPUT_FILE="/config/db_list"
export PGPASSWORD="$POSTGRES_PASSWORD"

# Query PostgreSQL, filter out empty lines, exclude specified databases, and save the result
psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -t -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false;" | \
    grep -v '^$' | \
    grep -v -E "$(echo "$EXCLUDE_DBS" | sed 's/ /|/g')" > "$OUTPUT_FILE"

unset PGPASSWORD

echo "Database list saved to $OUTPUT_FILE"
cat "$OUTPUT_FILE"

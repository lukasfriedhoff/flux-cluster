#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rewrite_script="$repo_root/scripts/matrix-server-name-rewrite.sh"

grep -Fq "restore-db-rewritten is disabled" "$rewrite_script"
grep -Fq "c.table_name = 'event_json'" "$rewrite_script"
grep -Fq "c.column_name = 'json'" "$rewrite_script"
grep -Fq "DatabaseCorruptionError" "$rewrite_script"
grep -Fq "MATRIX_TEST_ACCESS_TOKEN" "$rewrite_script"

if grep -Eq "pg_restore .*\\| sed .*old_server.*new_server" "$rewrite_script"; then
  echo "unsafe SQL-stream Matrix server-name rewrite found" >&2
  exit 1
fi

echo "Matrix rewrite safety checks passed."

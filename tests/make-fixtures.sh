#!/usr/bin/env bash
# make-fixtures.sh — (re)create the test files used by checkmany.sh
set -euo pipefail

FIX="$HOME/lab/fixtures"
mkdir -p "$FIX"

printf 'line one\nline two\n' > "$FIX/full.txt"   # regular file, has content
: > "$FIX/empty.txt"                              # regular file, zero bytes
mkdir -p "$FIX/adir"                              # a directory, not a file
printf 'secret\n'          > "$FIX/noread.txt"    # will be made unreadable
chmod 000 "$FIX/noread.txt"
rm -f "$FIX/nothing"                              # must NOT exist

echo "fixtures ready in $FIX"

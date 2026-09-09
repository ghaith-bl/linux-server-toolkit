#!/usr/bin/env bash
# backup.sh — creates a compressed tar.gz backup of a source directory
# into a destination directory.
# v1: no rotation/retention — intentional decision, documented in NOTES.md.

set -euo pipefail

# Find the directory this script lives in, so we can locate lib/
# regardless of where the user runs it from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# --- defaults ---
src=""
dest=""
verbose=false

usage() {
    echo "Usage: $0 -s <source_dir> -d <dest_dir> [-v]" >&2
    exit 1
}

# --- parse command-line flags ---
while getopts ":s:d:v" opt; do
    case "$opt" in
        s) src="$OPTARG" ;;
        d) dest="$OPTARG" ;;
        v) verbose=true ;;
        \?)
            log_error "Unknown option: -$OPTARG"
            usage
            ;;
        :)
            log_error "Option -$OPTARG requires a value"
            usage
            ;;
    esac
done
shift $((OPTIND - 1))

if [[ -z "$src" ]]; then
    log_error "Missing required -s <source_dir>"
    usage
fi

if [[ -z "$dest" ]]; then
    log_error "Missing required -d <dest_dir>"
    usage
fi

# --- pre-flight checks ---
require_cmd tar

if [[ ! -d "$src" ]]; then
    die "Source directory does not exist: $src"
fi

mkdir -p "$dest"

# --- build names ---
src_parent="$(dirname -- "$src")"
src_name="$(basename -- "$src")"

timestamp="$(date +'%Y%m%d-%H%M%S')"
final_name="backup-${src_name}-${timestamp}.tar.gz"
final_path="${dest}/${final_name}"

# --- create a temp file in the SAME directory as the destination ---
tmpfile="$(mktemp "${dest}/.tmp-backup-XXXXXX")"

trap 'rm -f "$tmpfile"' EXIT

# --- build the tar command as an array, so -v can be added conditionally ---
tar_opts=(-c -z -f "$tmpfile")

if [[ "$verbose" == true ]]; then
    tar_opts+=(-v)
fi

tar_opts+=(-C "$src_parent" "$src_name")

log_info "Creating archive from $src ..."
tar "${tar_opts[@]}"

mv "$tmpfile" "$final_path"

log_ok "Backup created: $final_path"

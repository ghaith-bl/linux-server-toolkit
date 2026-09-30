#!/usr/bin/env bash
# backup.sh — creates a compressed tar.gz backup of a source directory
# into a destination directory, with a .sha256 checksum file next to it.
# v1: no rotation/retention — intentional decision, documented in NOTES.md.
# v2: the archive and its checksum are group-readable (mode 640): in a
#     shared folder (setgid), a separate account can send them without
#     being able to change them.

set -euo pipefail

# Find the directory this script lives in, so we can locate lib/
# regardless of where the user runs it from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
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
require_cmd tar sha256sum

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

# --- create the temp files in the SAME directory as the destination ---
# One for the archive, one for its checksum. The leading dot keeps them
# out of the "backup-*" names that other tools look for.
tmpfile="$(mktemp "${dest}/.tmp-backup-XXXXXX")"
tmpsum="$(mktemp "${dest}/.tmp-backup-XXXXXX")"

trap 'rm -f "$tmpfile" "$tmpsum"' EXIT

# --- build the tar command as an array, so -v can be added conditionally ---
tar_opts=(-c -z -f "$tmpfile")

if [[ "$verbose" == true ]]; then
    tar_opts+=(-v)
fi

tar_opts+=(-C "$src_parent" "$src_name")

log_info "Creating archive from $src ..."
tar "${tar_opts[@]}"

# mktemp makes files for the owner only (600): let the group read them.
chmod 640 "$tmpfile"

# --- checksum, in the format "sha256sum -c" reads: <hash>, two spaces, name ---
# Read into a variable first: under set -e and pipefail, a failed
# sha256sum stops the script here.
checksum="$(sha256sum < "$tmpfile" | cut -d ' ' -f 1)"
if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
    die "sha256sum gave an unexpected value for $tmpfile"
fi
printf '%s  %s\n' "$checksum" "$final_name" > "$tmpsum"
chmod 640 "$tmpsum"

# --- put both in place: the archive first, its checksum last ---
# A checksum file therefore always means its archive is complete.
mv "$tmpfile" "$final_path"
mv "$tmpsum" "${final_path}.sha256"

log_ok "Backup created: $final_path"
log_ok "Checksum: ${final_path}.sha256"

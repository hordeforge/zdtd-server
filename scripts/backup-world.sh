#!/usr/bin/env bash
# Copy a zdtd world_dir to a timestamped backup and rotate old copies.
# Atomic save (temp+rename) is not a backup: instance or disk loss needs a
# tree outside world_dir. See docs/subsystems/persistence.md.
#
# Usage:
#   scripts/backup-world.sh <world_dir> [backup_root] [keep]
# Defaults: backup_root=<world_dir>/../backups, keep=7
# Exit non-zero on any failure (missing source, copy error, empty result).
#
# backup_root on the same filesystem as world_dir is refused: the default
# sibling directory shares the disk it is supposed to protect. Set
# ZDTD_BACKUP_ALLOW_SAME_FS=1 only for a deliberate same-host copy.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <world_dir> [backup_root] [keep]" >&2
  exit 2
fi

KEEP=${3:-7}
if ! [[ "$KEEP" =~ ^[1-9][0-9]*$ ]]; then
  echo "zdtd: keep must be a positive integer, got '$KEEP'" >&2
  exit 2
fi

# Resolve after the existence check so a missing path prints our message
# instead of a bare `cd: ... No such file or directory` from the shell.
if [[ ! -d "$1" ]]; then
  echo "zdtd: world_dir not a directory: $1" >&2
  exit 1
fi
WORLD_DIR=$(cd -- "$1" && pwd)

if [[ $# -ge 2 && -n "${2}" ]]; then
  mkdir -p -- "$2"
  BACKUP_ROOT=$(cd -- "$2" && pwd)
else
  BACKUP_ROOT=$(cd -- "$(dirname -- "$WORLD_DIR")" && pwd)/backups
  mkdir -p -- "$BACKUP_ROOT"
fi

# Refuse to write backups inside the live world tree (same failure domain as
# a deleted world_dir and easy to clobber on restore).
case "$BACKUP_ROOT" in
  "$WORLD_DIR"|"$WORLD_DIR"/*)
    echo "zdtd: backup_root must not be inside world_dir ($WORLD_DIR)" >&2
    exit 2
    ;;
  *)
    ;;
esac

# Device id of the filesystem holding $1, or empty when stat cannot say.
fs_device() {
  stat -c %d -- "$1" 2>/dev/null || stat -f %d -- "$1" 2>/dev/null || true
}

# A backup on the same filesystem dies with the disk it protects: the copy
# looks like a safety net while sharing the failure domain it is meant to
# cover. Fail closed and let the operator opt out explicitly.
world_dev=$(fs_device "$WORLD_DIR")
backup_dev=$(fs_device "$BACKUP_ROOT")
if [[ -n "$world_dev" && "$world_dev" == "$backup_dev" && "${ZDTD_BACKUP_ALLOW_SAME_FS:-0}" != "1" ]]; then
  echo "zdtd: backup_root is on the same filesystem as world_dir (device $world_dev): $BACKUP_ROOT" >&2
  echo "zdtd: a disk failure destroys both; pass a backup_root on another filesystem" >&2
  echo "zdtd: set ZDTD_BACKUP_ALLOW_SAME_FS=1 to accept that risk deliberately" >&2
  exit 2
fi

BASE=$(basename -- "$WORLD_DIR")
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$BACKUP_ROOT/${BASE}-${STAMP}"
# Same-second reruns must not land inside an existing DEST (mv into dir).
if [[ -e "$DEST" ]]; then
  DEST="$BACKUP_ROOT/${BASE}-${STAMP}.$$"
fi

# Staging dir then rename so a killed copy never looks like a complete backup.
STAGE="$DEST.partial.$$"
rm -rf -- "$STAGE"
mkdir -p -- "$STAGE"
trap 'rm -rf -- "$STAGE"' EXIT INT TERM

# Prefer cp -a for hardlinks-free portable trees; fall back without -a.
if ! cp -a -- "$WORLD_DIR"/. "$STAGE"/ 2>/dev/null; then
  cp -R -- "$WORLD_DIR"/. "$STAGE"/
fi

# Fail closed on empty copies (wrong path, permission, or source wiped).
file_count=$(find "$STAGE" -type f | wc -l)
if [[ "$file_count" -lt 1 ]]; then
  rm -rf -- "$STAGE"
  echo "zdtd: backup produced zero files from $WORLD_DIR" >&2
  exit 1
fi

mv -- "$STAGE" "$DEST"
trap - EXIT INT TERM
echo "zdtd: backup $DEST ($file_count files)"

# Clean up stale partial directories from past crashed runs to prevent disk
# leaks. A concurrent run (cron overlap, or an operator running this by hand
# during a scheduled one) is still copying into its own `${STAGE}`, named with
# its PID, so skip a staging dir whose PID is still alive.
for partial in "$BACKUP_ROOT/${BASE}-"*.partial.*; do
  if [[ ! -d "$partial" ]]; then
    continue
  fi
  partial_pid="${partial##*.}"
  if [[ "$partial_pid" =~ ^[0-9]+$ ]] && kill -0 "$partial_pid" 2>/dev/null; then
    echo "zdtd: skipping in-progress staging dir (pid $partial_pid): $partial"
    continue
  fi
  rm -rf -- "$partial"
  echo "zdtd: cleaned up stale staging dir $partial"
done

# Rotate: keep the newest KEEP complete backups for this world basename.
# Skip leftover `*.partial.*` staging dirs so an interrupted copy cannot
# inflate the count and rotate a finished backup out.
mapfile -t OLD < <(
  shopt -s nullglob
  for path in "$BACKUP_ROOT/${BASE}-"*; do
    case "$path" in
      *.partial.*) continue ;;
      *) printf '%s\n' "$path" ;;
    esac
  done | sort -r
)
if ((${#OLD[@]} > KEEP)); then
  for ((i = KEEP; i < ${#OLD[@]}; i++)); do
    rm -rf -- "${OLD[$i]}"
    echo "zdtd: rotated out ${OLD[$i]}"
  done
fi

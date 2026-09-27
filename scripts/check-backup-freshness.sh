#!/usr/bin/env bash
# Report whether the newest complete backup of a world is recent enough to be
# the recovery point. backup-world.sh exiting zero once says a copy was made;
# nothing else notices a job that stopped running, so alerting wraps this.
#
# Usage:
#   scripts/check-backup-freshness.sh <world_dir> [backup_root] [max_age_seconds]
# Defaults: backup_root=<world_dir>/../backups, max_age_seconds=86400
# Exit 0 when a complete backup is at most max_age_seconds old, 1 otherwise.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <world_dir> [backup_root] [max_age_seconds]" >&2
  exit 2
fi

MAX_AGE=${3:-86400}
if ! [[ "$MAX_AGE" =~ ^[0-9]+$ ]]; then
  echo "zdtd: max_age_seconds must be a non-negative integer, got '$MAX_AGE'" >&2
  exit 2
fi

if [[ ! -d "$1" ]]; then
  echo "zdtd: world_dir not a directory: $1" >&2
  exit 1
fi
WORLD_DIR=$(cd -- "$1" && pwd)

if [[ $# -ge 2 && -n "${2}" ]]; then
  if [[ ! -d "$2" ]]; then
    echo "zdtd: backup_root is not a directory: $2" >&2
    exit 1
  fi
  BACKUP_ROOT=$(cd -- "$2" && pwd)
else
  BACKUP_ROOT=$(cd -- "$(dirname -- "$WORLD_DIR")" && pwd)/backups
fi

BASE=$(basename -- "$WORLD_DIR")
shopt -s nullglob
NEWEST=""
NEWEST_MTIME=0
NEWEST_COUNT=0
for path in "$BACKUP_ROOT/${BASE}-"*; do
  # An interrupted copy leaves a .partial.* staging dir; it is not a backup.
  if [[ "$path" == *.partial.* ]]; then
    continue
  fi
  [[ -d "$path" ]] || continue
  NEWEST_COUNT=$((NEWEST_COUNT + 1))
  mtime=$(stat -c %Y -- "$path" 2>/dev/null || stat -f %m -- "$path" 2>/dev/null || echo 0)
  if [[ "$mtime" =~ ^[0-9]+$ ]] && ((mtime > NEWEST_MTIME)); then
    NEWEST_MTIME=$mtime
    NEWEST="$path"
  fi
done
shopt -u nullglob

if [[ -z "$NEWEST" ]]; then
  echo "zdtd: no complete backup of $BASE under $BACKUP_ROOT" >&2
  exit 1
fi

NOW=$(date -u +%s)
AGE=$((NOW - NEWEST_MTIME))
if ((AGE > MAX_AGE)); then
  echo "zdtd: newest backup of $BASE is ${AGE}s old, over the ${MAX_AGE}s budget: $NEWEST" >&2
  exit 1
fi

echo "zdtd: $NEWEST is ${AGE}s old ($NEWEST_COUNT backup(s) of $BASE under $BACKUP_ROOT)"

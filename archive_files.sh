#!/bin/bash
# archive_files.sh — monitor a folder and archive old files 
# Usage:
#   ./archive_files.sh <path_to_dir> <threshold> <nb_files> [<exclude_mask>...]
# Example:
#   ./archive_files.sh /log 80 5 "*.tmp" "*.lock"

set -euo pipefail

BACKUP_DIR="${HOME}/tmp/backup"

# ---------- 1. Check args ----------
if [[ $# -lt 3 ]]
then
    echo "Usage: $0 <path_to_dir> <threshold> <nb_files> [<exclude_mask>...]"
    echo ":      $0 /log 80 5 '*.tmp'"
    exit 1
fi

LOG_DIR="$1"
THRESHOLD="$2"
FILES_TO_ARCHIVE="$3"
shift 3

EXCLUDES=("$@")   # optional masks to exclude
if [[ ! -d "$LOG_DIR" ]]
then
    echo "Error: folder '$LOG_DIR' does not exist." >&2
    exit 1
fi

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || ! [[ "$FILES_TO_ARCHIVE" =~ ^[0-9]+$ ]]
then
    echo "Error: threshold and number of files must be positive numbers." >&2
    exit 1
fi

# ---------- 2. Size of folder in % of whole disc size ----------
# Folder size, in KB
FOLDER_SIZE_KB=$(du -sk "$LOG_DIR" | cut -f1)

# Total size of disc where the folder is located, in KB
DISK_TOTAL_KB=$(df -k --output=size "$LOG_DIR" | tail -1 | tr -d ' ')

PERCENT=$(( FOLDER_SIZE_KB * 100 / DISK_TOTAL_KB ))

# Convert to human readable form
FOLDER_SIZE_H=$(du -sh "$LOG_DIR" | cut -f1)

echo "Folder:             $LOG_DIR"
echo "Folder size:        $FOLDER_SIZE_H (${FOLDER_SIZE_KB} KB)"
echo "Total on disc:      $(( DISK_TOTAL_KB / 1024 )) MB"
echo "Occupied by folder: ${PERCENT}% (threshold ${THRESHOLD}%)"

# ---------- 3. Check threshold ----------
if (( PERCENT < THRESHOLD ))
then
    echo "Threshold is not reached — no need to archive. Exiting."
    exit 0
fi

echo "Threshold is reached! Archiving ..."

# ---------- 4. Filter out files to exclude ----------
mkdir -p "$BACKUP_DIR"

# Pick only ordinary files, sort them by modify time (older first)
# and apply excludes if they are given
FIND_ARGS=(-type f)
for pattern in "${EXCLUDES[@]}"
do
    FIND_ARGS+=(! -name "$pattern")
done

# Eclude files opened right now for writing (active log)
mapfile -t CANDIDATES < <(
    find "$LOG_DIR" "${FIND_ARGS[@]}" -printf '%T@ %p\n' \
    | sort -n \
    | awk '{ $1=""; sub(/^ /, ""); print }'
)

FILTERED=()
for f in "${CANDIDATES[@]}"
do
    # lsof returns 0, if file $f is kept opened by any process
    # so we skip such file
    if ! lsof "$f" >/dev/null 2>&1
    then
        FILTERED+=("$f")
    fi
done

# Here FILTERED contains only files not used by any processes
# Count number of these files to TOTAL
TOTAL=${#FILTERED[@]}
if (( TOTAL == 0 ))
then
    echo "No files to archive after filternig. Exiting."
    exit 0
fi

# Pick $FILES_TO_ARCHIVE files from $TARGETS
TARGETS=("${FILTERED[@]:0:$FILES_TO_ARCHIVE}")

echo "Nb candidates after filtering: $TOTAL"
echo "To archive (oldest ${#TARGETS[@]} files):"
printf '  %s\n' "${TARGETS[@]}"

# ---------- 5. Archiving with tar+gz ----------
STAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE="$BACKUP_DIR/${LOG_DIR##*/}_old_${STAMP}.tar.gz"

tar -czf "$ARCHIVE" "${TARGETS[@]}" > /dev/null 2>&1

if [[ $? -eq 0 ]]
then
    echo "Archive is created: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
else
    echo "Error creating archive!" >&2
    exit 1
fi

# chmod +x archive_logs.sh
# ./archive_files.sh /log 80 5 '*.tmp'

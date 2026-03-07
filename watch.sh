#!/bin/bash
set -euo pipefail

# Static
CONSUME_DIR="/consume"

# Configuration via env
IMMICH_SERVER="${IMMICH_SERVER:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
IMMICH_EXTRA_ARGS="${IMMICH_EXTRA_ARGS:-}"
# FAILED_DIR is always relative to the watched consume dir inside the container
FAILED_DIR="$CONSUME_DIR/${FAILED_DIR_NAME:-failed_uploads}"
IMMICH_SILENT="${IMMICH_SILENT:-1}"

if [ -z "$IMMICH_SERVER" ] || [ -z "$IMMICH_API_KEY" ]; then
  echo "IMMICH_SERVER and IMMICH_API_KEY must be provided via environment variables"
  exit 1
fi

is_image() {
  case "${1,,}" in
    *.jpg|*.jpeg|*.png|*.heic|*.heif|*.raw|*.cr2|*.nef|*.gif|*.webp|*.tiff|*.tif|*.bmp|*.mp4|*.mov|*.avi|*.mkv|*.m4v) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Watching directory: $CONSUME_DIR"

# Ensure failed uploads directory exists
mkdir -p "$FAILED_DIR"

# Move file to FAILED_DIR with collision avoidance
move_to_failed() {
  local src="$1"
  local dest="$FAILED_DIR/$(basename "$src")"
  if [ -e "$dest" ]; then
    dest="$FAILED_DIR/$(basename "$src").$(date +%s)"
  fi
  if mv -- "$src" "$dest"; then
    echo "Moved file to $dest"
    return 0
  else
    echo "Failed to move $src to $FAILED_DIR; leaving in place"
    return 1
  fi
}

# Upload helper: try upload, delete on success, move to FAILED_DIR on failure
upload_file() {
  local file="$1"
  echo "Processing file: $file"
  if [ "${IMMICH_SILENT}" = "1" ]; then
    out=$(immich-go upload from-folder --server="$IMMICH_SERVER" --api-key="$IMMICH_API_KEY" $IMMICH_EXTRA_ARGS "$file" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
      echo "Upload succeeded: $file - deleting local copy"
      rm -f -- "$file"
      return 0
    else
      echo "Upload failed for $file - moving to $FAILED_DIR"
      echo "immich-go output:" >&2
      echo "$out" >&2
      move_to_failed "$file"
      return 1
    fi
  else
    if immich-go upload from-folder --server="$IMMICH_SERVER" --api-key="$IMMICH_API_KEY" $IMMICH_EXTRA_ARGS "$file"; then
      echo "Upload succeeded: $file - deleting local copy"
      rm -f -- "$file"
      return 0
    else
      echo "Upload failed for $file - moving to $FAILED_DIR"
      move_to_failed "$file"
      return 1
    fi
  fi
}

# Process files that already exist at startup (only regular files, stable size)
for f in "$CONSUME_DIR"/*; do
  [ -e "$f" ] || continue
  # skip failed dir and directories
  if [ "$f" = "$FAILED_DIR" ]; then
    continue
  fi
  if [ -d "$f" ]; then
    continue
  fi
  if ! is_image "$f"; then
    echo "Skipping non-image at startup: $f - moving to $FAILED_DIR"
    move_to_failed "$f"
    continue
  fi
  # ensure file is not being written by checking size stability
  if [ ! -f "$f" ]; then
    continue
  fi
  size1=$(stat -c%s -- "$f" 2>/dev/null || echo 0)
  sleep 1
  size2=$(stat -c%s -- "$f" 2>/dev/null || echo 0)
  if [ "$size1" -ne "$size2" ]; then
    echo "File appears to be still writing, skipping for now: $f"
    continue
  fi
  upload_file "$f" || true
done

inotifywait -m -e close_write -e moved_to --format '%w%f' --quiet "$CONSUME_DIR" | while read -r file; do
  if [ -d "$file" ]; then
    continue
  fi
  if ! is_image "$file"; then
    echo "Skipping non-image: $file - moving to $FAILED_DIR"
    move_to_failed "$file"
    continue
  fi

  echo "Detected new file: $file"

  upload_file "$file" || true
done

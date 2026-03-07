#!/bin/bash
set -euo pipefail

# Configuration via env
CONSUME_DIR="${CONSUME_DIR:-/consume}"
IMMICH_SERVER="${IMMICH_SERVER:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
IMMICH_EXTRA_ARGS="${IMMICH_EXTRA_ARGS:-}"
FAILED_DIR="${FAILED_DIR:-$CONSUME_DIR/failed_uploads}"

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

inotifywait -m -e close_write -e moved_to --format '%w%f' --quiet "$CONSUME_DIR" | while read -r file; do
  if [ -d "$file" ]; then
    continue
  fi
  if ! is_image "$file"; then
    echo "Skipping non-image: $file - moving to $FAILED_DIR"
    dest="$FAILED_DIR/$(basename "$file")"
    if [ -e "$dest" ]; then
      dest="$FAILED_DIR/$(basename "$file").$(date +%s)"
    fi
    if mv -- "$file" "$dest"; then
      echo "Moved skipped file to $dest"
    else
      echo "Failed to move $file to $FAILED_DIR; leaving in place"
    fi
    continue
  fi

  echo "Detected new file: $file"

  # Try upload using immich-go. Use from-folder which accepts paths.
  if immich-go upload from-folder --server="$IMMICH_SERVER" --api-key="$IMMICH_API_KEY" $IMMICH_EXTRA_ARGS "$file"; then
    echo "Upload succeeded: $file - deleting local copy"
    rm -f "$file"
  else
    echo "Upload failed for $file - moving to $FAILED_DIR"
    dest="$FAILED_DIR/$(basename "$file")"
    if [ -e "$dest" ]; then
      dest="$FAILED_DIR/$(basename "$file").$(date +%s)"
    fi
    if mv -- "$file" "$dest"; then
      echo "Moved failed upload to $dest"
    else
      echo "Failed to move $file to $FAILED_DIR; leaving in place"
    fi
  fi
done

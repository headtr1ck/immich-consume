#!/bin/bash
set -euo pipefail

# Configuration via env
CONSUME_DIR="${CONSUME_DIR:-/consume}"
IMMICH_SERVER="${IMMICH_SERVER:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
IMMICH_EXTRA_ARGS="${IMMICH_EXTRA_ARGS:-}"

if [ -z "$IMMICH_SERVER" ] || [ -z "$IMMICH_API_KEY" ]; then
  echo "IMMICH_SERVER and IMMICH_API_KEY must be provided via environment variables"
  exit 1
fi

is_image() {
  case "${1,,}" in
    *.jpg|*.jpeg|*.png|*.heic|*.heif|*.raw|*.cr2|*.nef|*.mp4|*.mov|*.avi) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Watching directory: $CONSUME_DIR"

inotifywait -m -e close_write -e moved_to --format '%w%f' --quiet "$CONSUME_DIR" | while read -r file; do
  if [ -d "$file" ]; then
    continue
  fi
  if ! is_image "$file"; then
    echo "Skipping non-image: $file"
    continue
  fi

  echo "Detected new file: $file"

  # Try upload using immich-go. Use from-folder which accepts paths.
  if immich-go upload from-folder --server="$IMMICH_SERVER" --api-key="$IMMICH_API_KEY" $IMMICH_EXTRA_ARGS "$file"; then
    echo "Upload succeeded: $file - deleting local copy"
    rm -f "$file"
  else
    echo "Upload failed for $file - leaving file for retry"
  fi
done

#!/bin/bash
set -euo pipefail

# Static
CONSUME_DIR="/consume"
WORK_DIR="/workdir"

# Configuration via env
IMMICH_SERVER="${IMMICH_SERVER:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
IMMICH_EXTRA_ARGS="${IMMICH_EXTRA_ARGS:-}"
# New env var to define path to a static XMP sidecar template file
# For each scanned image, this file is copied to <image>.xmp
IMMICH_STATIC_SIDECAR="${IMMICH_STATIC_SIDECAR:-}"
# IMMICH_FAILED_DIR is always relative to the watched consume dir inside the container
IMMICH_FAILED_DIR="$CONSUME_DIR/${IMMICH_FAILED_DIR_NAME:-failed_uploads}"
IMMICH_ALBUM_MAP="${IMMICH_ALBUM_MAP:-}"
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

if [ -n "$IMMICH_STATIC_SIDECAR" ]; then
  if [ ! -f "$IMMICH_STATIC_SIDECAR" ]; then
    echo "XMP template not found: $IMMICH_STATIC_SIDECAR" >&2
    return 1
  fi
fi

echo "Watching directory: $CONSUME_DIR"

# Ensure directories exist
mkdir -p "$IMMICH_FAILED_DIR"
mkdir -p "$WORK_DIR"

# Move file to IMMICH_FAILED_DIR with collision avoidance
move_to_failed() {
  local src="$1"
  local dest="$IMMICH_FAILED_DIR/$(basename "$src")"
  if [ -e "$dest" ]; then
    dest="$IMMICH_FAILED_DIR/$(basename "$src").$(date +%s)"
  fi
  if mv -- "$src" "$dest"; then
    echo "Moved file to $dest"
    return 0
  else
    echo "Failed to move $src to $IMMICH_FAILED_DIR; leaving in place"
    return 1
  fi
}

# Return album name for a file based on IMMICH_ALBUM_MAP
# Format for IMMICH_ALBUM_MAP: "subdir1:Album Name,subdir2:Other Album"
# Album names may contain spaces but MUST NOT contain commas.
get_album_for_file() {
  local file="$1"
  # Extract immediate subdirectory under CONSUME_DIR, if any
  local rel="${file#$CONSUME_DIR/}"
  local subdir="${rel%%/*}"
  [ "$subdir" = "$rel" ] && subdir=""
  if [ -z "$subdir" ] || [ -z "$IMMICH_ALBUM_MAP" ]; then
    echo ""
    return
  fi

  # never map the failed uploads directory to an album
  failed_name="${IMMICH_FAILED_DIR##*/}"
  if [ "$subdir" = "$failed_name" ]; then
    echo ""
    return
  fi

  # normalize the map string by stripping outer quotes if present
  mapstr=$(printf '%s' "$IMMICH_ALBUM_MAP" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

  IFS=',' read -r -a pairs <<< "$mapstr"
  for p in "${pairs[@]}"; do
    # strip surrounding quotes from the pair and trim whitespace
    p=$(printf '%s' "$p" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/^ *//' -e 's/ *$//')
    # split at first ':'
    key="${p%%:*}"
    val="${p#*:}"
    # trim surrounding whitespace from key and val
    key=$(printf '%s' "$key" | sed -e 's/^ *//' -e 's/ *$//')
    val=$(printf '%s' "$val" | sed -e 's/^ *//' -e 's/ *$//')
    # strip surrounding single or double quotes from the album name
    val=$(printf '%s' "$val" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    if [ "$key" = "$subdir" ]; then
      echo "$val"
      return
    fi
  done
  echo ""
}

# Upload helper: try upload, delete on success, move to IMMICH_FAILED_DIR on failure
upload_file() {
  local file="$1"
  local filename=$(basename "$file")
  echo "Processing file: $file"

  # Determine per-file album if mapping provided and no album already in EXTRA_ARGS
  local album=""
  if ! echo "$IMMICH_EXTRA_ARGS" | grep -q -- --album; then
    album=$(get_album_for_file "$file")
  fi

  # move to work dir
  local file_work="${WORK_DIR}/${filename}"
  echo "Moving file: $file > $file_work"
  mv $file $file_work

  if [ -n "$IMMICH_STATIC_SIDECAR" ]; then
    echo "Adding sidecar info to image"
    exiftool -tagsfromfile "$IMMICH_STATIC_SIDECAR" -all:all "$file_work"
    local orig="${file_work}_original"
    if [ -f "$orig" ]; then
      rm -f -- "$orig"
    fi
  fi

  # Build command string safely quoting album and file
  local cmd
  cmd="immich-go upload from-folder --server=\"$IMMICH_SERVER\" --api-key=\"$IMMICH_API_KEY\""
  if [ -n "$IMMICH_EXTRA_ARGS" ]; then
    cmd="$cmd $IMMICH_EXTRA_ARGS"
  fi
  if [ -n "$album" ]; then
    # shell-escape the album name for safe inclusion in the eval command
    printf -v esc_album '%q' "$album"
    cmd="$cmd --into-album=$esc_album"
    # Log which album we're adding the image to
    echo "Adding to album: $album"
  fi
  cmd="$cmd \"$file_work\""

  if [ "${IMMICH_SILENT}" = "1" ]; then
    out=$(eval "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
      echo "Upload succeeded: $file_work - deleting local copy"
      rm -f -- "$file_work"
      return 0
    else
      echo "Upload failed for $file_work - moving to $IMMICH_FAILED_DIR"
      echo "immich-go output:" >&2
      echo "$out" >&2
      move_to_failed "$file_work"
      return 1
    fi
  else
    if eval "$cmd"; then
      echo "Upload succeeded: $file_work - deleting local copy"
      rm -f -- "$file_work"
      return 0
    else
      echo "Upload failed for $file_work - moving to $IMMICH_FAILED_DIR"
      move_to_failed "$file_work"
      return 1
    fi
  fi
}

# Process files that already exist at startup (recursive). Use find to handle subdirs.
find "$CONSUME_DIR" -type f -print0 | while IFS= read -r -d '' f; do
  [ -e "$f" ] || continue

  # skip files inside the failed dir
  case "$f" in
    "$IMMICH_FAILED_DIR"/*) continue ;;
  esac

  if ! is_image "$f"; then
    echo "Skipping non-image at startup: $f - moving to $IMMICH_FAILED_DIR"
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

inotifywait -m -r -e close_write -e moved_to --format '%w%f' --exclude '(_original|_exiftool_tmp)$' --quiet "$CONSUME_DIR" | while read -r file; do
  if [ -d "$file" ]; then
    continue
  fi
  # skip files inside the failed dir
  case "$file" in
    "$IMMICH_FAILED_DIR"/*) continue ;;
  esac

  if ! is_image "$file"; then
    echo "Skipping non-image: $file - moving to $IMMICH_FAILED_DIR"
    move_to_failed "$file"
    continue
  fi

  echo "Detected new file: $file"

  upload_file "$file" || true
done

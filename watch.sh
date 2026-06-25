#!/bin/bash
set -euo pipefail

# Static
CONSUME_DIR="/consume"
WORK_DIR="/workdir"

# Configuration via env
IMMICH_SERVER="${IMMICH_SERVER:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
IMMICH_DEVICE_ID="${IMMICH_DEVICE_ID:-immich-consume}"
# New env var to define path to a static XMP sidecar template file
# For each scanned image, this file is copied to <image>.xmp
IMMICH_STATIC_SIDECAR="${IMMICH_STATIC_SIDECAR:-}"
# IMMICH_FAILED_DIR is always relative to the watched consume dir inside the container
IMMICH_FAILED_DIR="$CONSUME_DIR/${IMMICH_FAILED_DIR_NAME:-failed_uploads}"
IMMICH_ALBUM_MAP="${IMMICH_ALBUM_MAP:-}"
IMMICH_SILENT="${IMMICH_SILENT:-1}"

declare -A ALBUM_SUBDIR_TO_NAME
declare -A ALBUM_ID_CACHE


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
    exit 1
  fi
fi

parse_album_map() {
  local mapstr
  mapstr=$(printf '%s' "$IMMICH_ALBUM_MAP" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

  IFS=',' read -r -a pairs <<< "$mapstr"
  for p in "${pairs[@]}"; do
    p=$(printf '%s' "$p" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/^ *//' -e 's/ *$//')
    key="${p%%:*}"
    val="${p#*:}"
    key=$(printf '%s' "$key" | sed -e 's/^ *//' -e 's/ *$//')
    val=$(printf '%s' "$val" | sed -e 's/^ *//' -e 's/ *$//')
    val=$(printf '%s' "$val" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    if [ -n "$key" ] && [ -n "$val" ]; then
      ALBUM_SUBDIR_TO_NAME["$key"]="$val"
      ALBUM_ID_CACHE["$val"]=""
    fi
  done
}

api_url() {
  local path="$1"
  printf '%s' "${IMMICH_SERVER%/}$path"
}

api_create_album() {
  local name="$1"
  local payload
  local body

  payload=$(jq -nc --arg name "$name" '{albumName: $name}')
  if ! body=$(curl -sS -f -H "x-api-key: $IMMICH_API_KEY" -H "Content-Type: application/json" -d "$payload" "$(api_url /api/albums)" 2>&1); then
    echo "Failed to create album '$name': $body" >&2
    return 1
  fi

  printf '%s' "$body" | jq -r '.id // .albumId // empty'
}

load_album_cache() {
  if [ -z "$IMMICH_ALBUM_MAP" ]; then
    echo "IMMICH_ALBUM_MAP is not configured; no album mappings loaded"
    return 0
  fi

  echo "Loading album cache for configured mappings"
  parse_album_map

  local body
  if ! body=$(curl -sS -f -H "x-api-key: $IMMICH_API_KEY" -H "Accept: application/json" "$(api_url /api/albums)" 2>&1); then
    echo "Failed to fetch album list: $body" >&2
    return 1
  fi

  while IFS=$'\t' read -r name id; do
    if [ -n "$name" ] && [ -n "$id" ]; then
      ALBUM_ID_CACHE["$name"]="$id"
    fi
  done < <(printf '%s' "$body" | jq -r '
    if type == "object" then
      if .data then .data[]
      elif .albums then .albums[]
      elif .items then .items[]
      else . end
    elif type == "array" then
      .[]
    else
      empty
    end
    | [.albumName, (.id // .albumId)] | @tsv
  ')

  local album_name
  for album_name in "${!ALBUM_ID_CACHE[@]}"; do
    if [ -z "${ALBUM_ID_CACHE[$album_name]}" ]; then
      echo "Album not found, creating: $album_name"
      local album_id
      album_id=$(api_create_album "$album_name") || return 1
      ALBUM_ID_CACHE["$album_name"]="$album_id"
    fi
  done

  local subdir
  for subdir in "${!ALBUM_SUBDIR_TO_NAME[@]}"; do
    local album_name="${ALBUM_SUBDIR_TO_NAME[$subdir]}"
    local album_id="${ALBUM_ID_CACHE[$album_name]:-}"
    echo "Configured album mapping: subdir='$subdir' -> album='$album_name' id='${album_id:-<missing>}'"
  done
}

echo "Watching directory: $CONSUME_DIR"
echo "IMMICH_ALBUM_MAP=${IMMICH_ALBUM_MAP:-<unset>}"

echo "Initializing album cache"

# Ensure directories exist
mkdir -p "$IMMICH_FAILED_DIR"
mkdir -p "$WORK_DIR"

# Preload album IDs from Immich and create any mapped albums that are missing
if ! load_album_cache; then
  echo "Failed to initialize album cache" >&2
  exit 1
fi

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

  printf '%s' "${ALBUM_SUBDIR_TO_NAME[$subdir]:-}"
}

parse_album_map() {
  local mapstr
  mapstr=$(printf '%s' "$IMMICH_ALBUM_MAP" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

  IFS=',' read -r -a pairs <<< "$mapstr"
  for p in "${pairs[@]}"; do
    p=$(printf '%s' "$p" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/^ *//' -e 's/ *$//')
    key="${p%%:*}"
    val="${p#*:}"
    key=$(printf '%s' "$key" | sed -e 's/^ *//' -e 's/ *$//')
    val=$(printf '%s' "$val" | sed -e 's/^ *//' -e 's/ *$//')
    val=$(printf '%s' "$val" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    if [ -n "$key" ] && [ -n "$val" ]; then
      ALBUM_SUBDIR_TO_NAME["$key"]="$val"
      ALBUM_ID_CACHE["$val"]=""
    fi
  done
}

load_album_cache() {
  if [ -z "$IMMICH_ALBUM_MAP" ]; then
    echo "IMMICH_ALBUM_MAP is not configured; no album mappings loaded"
    return 0
  fi

  echo "Loading album cache for configured mappings"
  parse_album_map

  local body
  if ! body=$(curl -sS -f -H "x-api-key: $IMMICH_API_KEY" -H "Accept: application/json" "$(api_url /api/albums)" 2>&1); then
    echo "Failed to fetch album list: $body" >&2
    return 1
  fi

  while IFS=$'\t' read -r name id; do
    if [ -n "$name" ] && [ -n "$id" ]; then
      ALBUM_ID_CACHE["$name"]="$id"
    fi
  done < <(printf '%s' "$body" | jq -r '
    if type == "object" then
      if .data then .data[]
      elif .albums then .albums[]
      elif .items then .items[]
      else . end
    elif type == "array" then
      .[]
    else
      empty
    end
    | [.albumName, (.id // .albumId)] | @tsv
  ')

  local album_name
  for album_name in "${!ALBUM_ID_CACHE[@]}"; do
    if [ -z "${ALBUM_ID_CACHE[$album_name]}" ]; then
      echo "Album not found, creating: $album_name"
      local album_id
      album_id=$(api_create_album "$album_name") || return 1
      ALBUM_ID_CACHE["$album_name"]="$album_id"
    fi
  done

  local subdir
  for subdir in "${!ALBUM_SUBDIR_TO_NAME[@]}"; do
    local album_name="${ALBUM_SUBDIR_TO_NAME[$subdir]}"
    local album_id="${ALBUM_ID_CACHE[$album_name]:-}"
    echo "Configured album mapping: subdir='$subdir' -> album='$album_name' id='${album_id:-<missing>}'"
  done
}

# API helpers
api_url() {
  local path="$1"
  printf '%s' "${IMMICH_SERVER%/}$path"
}

api_album_id_by_name() {
  local name="$1"
  local body

  if ! body=$(curl -sS -f -H "x-api-key: $IMMICH_API_KEY" -H "Accept: application/json" "$(api_url /api/albums)" 2>&1); then
    echo "Failed to list albums: $body" >&2
    return 1
  fi

  printf '%s' "$body" | jq -r --arg name "$name" '
    if type == "object" then
      if .data then .data[]
      elif .albums then .albums[]
      elif .items then .items[]
      else . end
    elif type == "array" then
      .[]
    else
      empty
    end
    | select(.albumName == $name) | .id // .albumId // empty
  ' | head -n 1
}

api_create_album() {
  local name="$1"
  local payload
  local body

  payload=$(jq -nc --arg name "$name" '{albumName: $name}')
  if ! body=$(curl -sS -f -H "x-api-key: $IMMICH_API_KEY" -H "Content-Type: application/json" -d "$payload" "$(api_url /api/albums)" 2>&1); then
    echo "Failed to create album '$name': $body" >&2
    return 1
  fi

  printf '%s' "$body" | jq -r '.id // .albumId // empty'
}

api_add_asset_to_album() {
  local album_id="$1"
  local asset_id="$2"
  local payload
  local body
  local url
  local attempt=1
  local max_attempts=5

  payload=$(jq -nc --arg assetId "$asset_id" '{ids: [$assetId]}')
  url=$(api_url /api/albums/$album_id/assets)

  while [ "$attempt" -le "$max_attempts" ]; do
    if body=$(printf '%s' "$payload" | curl -sS -X PUT -H "x-api-key: $IMMICH_API_KEY" -H "Content-Type: application/json" --data-binary @- "$url" 2>&1); then
      return 0
    fi

    echo "Album add attempt $attempt/$max_attempts failed: url=$url payload=$payload response=$body" >&2
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$max_attempts" ]; then
      sleep 5
    fi
  done

  return 1
}

api_upload_asset() {
  local file_path="$1"
  local device_asset_id="$2"
  local body
  local filename
  filename=$(basename "$file_path")
  local created_at
  local modified_at

  created_at=$(date -u -d "@$(stat -c %Y -- "$file_path")" +%Y-%m-%dT%H:%M:%SZ)
  modified_at=$(date -u -d "@$(stat -c %Y -- "$file_path")" +%Y-%m-%dT%H:%M:%SZ)

  if ! body=$(curl -sS -f -H "x-api-key: $IMMICH_API_KEY" -H "Accept: application/json" \
      -F "deviceId=$IMMICH_DEVICE_ID" \
      -F "deviceAssetId=$device_asset_id" \
      -F "filename=$filename" \
      -F "fileCreatedAt=$created_at" \
      -F "fileModifiedAt=$modified_at" \
      -F "assetData=@$file_path" \
      "$(api_url /api/assets)" 2>&1); then
    echo "Upload failed: $body" >&2
    return 1
  fi

  printf '%s' "$body" | jq -r '.id // .assetId // empty'
}

ensure_album_id() {
  local album_name="$1"
  if [ -z "$album_name" ]; then
    return 0
  fi

  local album_id="${ALBUM_ID_CACHE[$album_name]:-}"
  if [ -z "$album_id" ]; then
    echo "Album not cached, creating: $album_name"
    album_id=$(api_create_album "$album_name") || return 1
    ALBUM_ID_CACHE["$album_name"]="$album_id"
  fi

  if [ -z "$album_id" ]; then
    echo "Failed to resolve album id for '$album_name'" >&2
    return 1
  fi

  printf '%s' "$album_id"
}

# Upload helper: try upload, delete on success, move to IMMICH_FAILED_DIR on failure
upload_file() {
  local file="$1"
  local filename
  filename=$(basename "$file")
  echo "Processing file: $file"

  local album=""
  album=$(get_album_for_file "$file")

  local file_work="${WORK_DIR}/${filename}"
  echo "Moving file: $file > $file_work"
  mv -- "$file" "$file_work"

  if [ -n "$IMMICH_STATIC_SIDECAR" ]; then
    echo "Adding sidecar info to image"
    exiftool -tagsfromfile "$IMMICH_STATIC_SIDECAR" -all:all "$file_work"
    local orig="${file_work}_original"
    if [ -f "$orig" ]; then
      rm -f -- "$orig"
    fi
  fi

  local device_asset_id
  device_asset_id="${filename}-$(date +%s)"
  local asset_id
  if ! asset_id=$(api_upload_asset "$file_work" "$device_asset_id"); then
    echo "Upload failed for $file_work - moving to $IMMICH_FAILED_DIR"
    move_to_failed "$file_work"
    return 1
  fi

  if [ "${IMMICH_SILENT}" != "1" ]; then
    echo "Upload succeeded: $file_work -> asset $asset_id"
  fi

  if [ -n "$album" ]; then
    local album_id
    if ! album_id=$(ensure_album_id "$album"); then
      echo "Failed to resolve album for '$album' - moving to $IMMICH_FAILED_DIR"
      move_to_failed "$file_work"
      return 1
    fi

    if ! api_add_asset_to_album "$album_id" "$asset_id"; then
      echo "Failed to add asset $asset_id to album '$album' - moving to $IMMICH_FAILED_DIR"
      move_to_failed "$file_work"
      return 1
    fi

    if [ "${IMMICH_SILENT}" != "1" ]; then
      echo "Added asset $asset_id to album '$album'"
    fi
  fi

  echo "Upload succeeded: $file_work - deleting local copy"
  rm -f -- "$file_work"
  return 0
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

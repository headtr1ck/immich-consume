# immich-consume

Docker service that watches a directory and uploads new images to an Immich server using the Immich REST API directly.

## Usage

1. Create a folder `consume` next to this repo or use your own and put images there.
2. Provide `IMMICH_SERVER` and `IMMICH_API_KEY` as environment variables (for docker-compose create a .env file or export them).
3. Start the service:

```bash
docker compose up --build -d
```

By default the container watches `/consume` (mounted from `./consume`). When a new image/video is added the service uploads it directly to Immich using the server API, then optionally adds it to an album.

## Configuration

- `IMMICH_SERVER` - URL of your Immich server (e.g. http://immich.local:2283)
- `IMMICH_API_KEY` - API key for uploads
- `IMMICH_DEVICE_ID` - Device identifier sent with uploads. Defaults to `immich-consume`
- `IMMICH_SILENT` - when set to `1` (default) the script suppresses verbose output and only prints details on failure; set to `0` to allow normal status messages.
- `FAILED_DIR_NAME` - Name of the directory inside the consume dir where failed uploads will be moved to. Defaults to `failed_uploads`
- `IMMICH_ALBUM_MAP` - optional mapping of subfolder -> album name. Format: `folder:Album Name,other:Other Album` (album names may contain spaces but must not contain commas). If provided, files placed under `/consume/<folder>/...` will be uploaded and then added to the matched Immich album.

### Using a .env file

You can put environment variables in a `.env` file next to the `docker-compose.yml` so `docker compose` picks them up automatically. Example `.env`:

```env
IMMICH_SERVER=http://immich.local:2283
IMMICH_API_KEY=your_api_key_here
IMMICH_ALBUM_MAP=vacation:Vacation 2025,work:Work Photos
```

### Docker Compose volume mapping

By default the repository expects a `./consume` directory next to the `docker-compose.yml` and mounts it into the container at `/consume`. To change the host location, update the volume mapping in your `docker-compose.yml` for the service. Example:

```yaml
services:
  immich-consume:
	build: .
	restart: unless-stopped
    volumes:
      /path/on/host/to/consume:/consume  # change this line in the docker-compose.yml file to alternate host path
```

If you change the host path (left side of the `:`), ensure the directory exists and has appropriate permissions for the container to read/move files.
If it does not exist, it will be created with root only access rights.

## Notes

- This uses inotify; files must be fully written (close/write) before upload is attempted.
- 100% Vibe coded and untested. Use at your own risk!

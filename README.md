# immich-consume

Docker service that watches a directory and uploads new images to an Immich server using immich-go.

## Usage

1. Create a folder `consume` next to this repo or use your own and put images there.
2. Provide `IMMICH_SERVER` and `IMMICH_API_KEY` as environment variables (for docker-compose create a .env file or export them).
3. Start the service:

```bash
docker compose up --build -d
```

By default the container watches `/consume` (mounted from `./consume`). When a new image/video is added the service runs `immich-go upload from-folder <path>` and deletes the file on successful upload.

## Configuration

- `IMMICH_SERVER` - URL of your Immich server (e.g. http://immich.local:2283)
- `IMMICH_API_KEY` - API key for uploads
- `IMMICH_EXTRA_ARGS` - optional extra arguments passed to `immich-go` (for example `--album=my-album`)
- `IMMICH_SILENT` - when set to `1` (default) the script suppresses verbose output from `immich-go` and only prints its output when an upload fails; set to `0` to allow `immich-go` to print normally.
- `FAILED_DIR_NAME` - Name of the directory inside the consume dir where failed uploads will be moved to. Defaults to `failed_uploads`

### Using a .env file

You can put environment variables in a `.env` file next to the `docker-compose.yml` so `docker compose` picks them up automatically. Example `.env`:

```env
IMMICH_SERVER=http://immich.local:2283
IMMICH_API_KEY=your_api_key_here
IMMICH_EXTRA_ARGS=--album=my-album
IMMICH_SILENT=1
```

### Docker Compose volume mapping

By default the repository expects a `./consume` directory next to the `docker-compose.yml` and mounts it into the container at `/consume`. To change the host location, update the volume mapping in your `docker-compose.yml` for the service. Example:

```yaml
services:
	immich-consume:
		build: .
		environment:
			- IMMICH_SERVER=${IMMICH_SERVER}
			- IMMICH_API_KEY=${IMMICH_API_KEY}
		volumes:
			 /path/on/host/to/consume:/consume  # change this line in the docker-compose.yml file to alternate host path
```

If you change the host path (left side of the `:`), ensure the directory exists and has appropriate permissions for the container to read/move files.
If it does not exist, it will be created with root only access rights.

## Notes

- This uses inotify; files must be fully written (close/write) before upload is attempted.
- `immich-go` is built in the image during Docker build via `go install`.

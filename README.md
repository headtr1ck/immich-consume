# immich-consume

Docker service that watches a directory and uploads new images to an Immich server using immich-go.

Usage

1. Create a folder `consume` next to this repo or use your own and put images there.
2. Provide `IMMICH_SERVER` and `IMMICH_API_KEY` as environment variables (for docker-compose create a .env file or export them).
3. Start the service:

```bash
docker compose up --build -d
```

By default the container watches `/consume` (mounted from `./consume`). When a new image/video is added the service runs `immich-go upload from-folder <path>` and deletes the file on successful upload.

Configuration

- `IMMICH_SERVER` - URL of your Immich server (e.g. http://immich.local:2283)
- `IMMICH_API_KEY` - API key for uploads
- `IMMICH_EXTRA_ARGS` - optional extra arguments passed to `immich-go` (for example `--album=my-album`)

Notes

- This uses inotify; files must be fully written (close/write) before upload is attempted.
- `immich-go` is built in the image during Docker build via `go install`.

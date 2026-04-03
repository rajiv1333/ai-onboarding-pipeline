#!/bin/sh
# docker-entrypoint.sh
# Routes to the correct process based on APP_MODE environment variable.
# APP_MODE=api    → FastAPI (uvicorn)
# APP_MODE=worker → Background worker process

set -e

APP_MODE="${APP_MODE:-api}"

case "$APP_MODE" in
  api)
    echo "[entrypoint] Starting API gateway (uvicorn)..."
    exec uvicorn app.main:app \
      --host 0.0.0.0 \
      --port "${PORT:-8000}" \
      --workers 2 \
      --log-level info
    ;;
  worker)
    echo "[entrypoint] Starting job queue workers..."
    exec python -m app.workers.runner
    ;;
  migrate)
    echo "[entrypoint] Running database migrations..."
    exec alembic upgrade head
    ;;
  *)
    echo "[entrypoint] ERROR: Unknown APP_MODE='$APP_MODE'. Use 'api', 'worker', or 'migrate'."
    exit 1
    ;;
esac

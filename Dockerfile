# syntax=docker/dockerfile:1
FROM python:3.12-slim

# Don't buffer stdout (so `docker logs` shows output immediately) and don't
# write .pyc files.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install deps first so this layer caches across code changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY broker.py .

# Run as a non-root user, and pre-create the data dir it owns so a fresh named
# volume mounted at /data inherits writable ownership.
RUN useradd --create-home --uid 10001 broker \
    && mkdir -p /data && chown broker:broker /data
USER broker

# SQLite board + registry live here (mount a volume at /data to persist).
ENV BROKER_DB=/data/broker.db

EXPOSE 8000

# Liveness probe using the stdlib (slim has no curl). Hits the /healthz route.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import sys,urllib.request; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz', timeout=2).status==200 else 1)"

CMD ["python", "broker.py"]

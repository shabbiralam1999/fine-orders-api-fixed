FROM python:3.11-slim

# Don't buffer stdout/stderr (so logs show up immediately in `docker logs`)
# and don't write .pyc files (nothing in the container ever needs them).
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install only what's needed at runtime; curl is kept for the HEALTHCHECK below.
# --no-install-recommends + cleaning apt lists keeps the image small.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency manifest first so Docker can cache the pip install layer
# and only re-run it when requirements.txt actually changes.
COPY app/requirements.txt ./app/requirements.txt
RUN pip install --no-cache-dir -r app/requirements.txt

# Now copy the rest of the application code.
COPY app/ ./app/

# Run as a non-root user instead of root.
RUN useradd --create-home --shell /usr/sbin/nologin appuser
USER appuser

EXPOSE 5000

HEALTHCHECK --interval=60s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:5000/healthz || exit 1

# gunicorn instead of the Flask dev server: dev server is single-threaded,
# not hardened, and not meant for production traffic.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--chdir", "app", "app:app"]

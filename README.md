Welcome, and thanks for taking the time. This is a **fix-it exercise**, not a build-from-scratch one — closer to a real day on the job than a whiteboard puzzle.

## The scenario

The `orders-api` service below was thrown together in a hurry by someone who has since left. It's a small Flask app that's meant to run in a container, get built by CI, and deploy onto AWS. **Right now, most of it is broken, insecure, or wasteful.**

Your job is to get it working and make it something you'd be comfortable putting your name on.

## What's in the repo

```
app/                    the Flask application + requirements
tests/                  pytest tests for the Flask app
Dockerfile              containerises the app
docker-compose.yml      local run for app + database
.github/workflows/ci.yml   the CI pipeline
infra/main.tf           the AWS infrastructure (Terraform)
```

## Running locally

```
cp .env.example .env   # fill in real values, especially SECRET_KEY
docker compose up --build
curl http://localhost:5000/healthz
```

`SECRET_KEY` is required — the app fails fast on startup if it isn't set, rather than
silently using an insecure default.

## Running the tests

```
pip install -r app/requirements-dev.txt
SECRET_KEY=test-secret-key PYTHONPATH=app pytest
```

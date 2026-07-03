# NOTES.md — orders-api fix-it exercise

Reviewed every file in the repo. Below is each problem found, the fix applied, and why it mattered.
Grouped by file, in the order I worked through them.

## app/app.py

1. **App bound to `127.0.0.1` inside a container.** Flask listened only on localhost, so nothing outside the container (including the Docker host / `curl` from outside) could ever reach port 5000.
   **Fix:** bind to `0.0.0.0`. **Why it mattered:** the app was effectively unreachable — task 1 ("`curl http://localhost:5000/healthz` should work") would fail outright.

2. **`debug=True` hardcoded.** Flask's debug mode exposes the Werkzeug interactive debugger, which allows arbitrary code execution if an attacker can trigger an unhandled exception.
   **Fix:** debug now defaults to `False` and is only enabled via a `FLASK_DEBUG` env var. **Why it mattered:** running debug mode in anything reachable from the network is a known remote-code-execution risk.

3. **Hardcoded `SECRET_KEY = "supersecret123"`.** Committed secrets end up in git history forever and are identical across every deploy.
   **Fix:** read from `SECRET_KEY` env var, with an obviously-labeled insecure fallback for local runs only. **Why it mattered:** Flask uses this key to sign sessions/cookies; a known key lets an attacker forge them.

4. **App run via Flask's built-in dev server (`app.run(...)`).** The dev server is single-threaded and explicitly documented as unfit for production.
   **Fix:** added `gunicorn` and switched the container's `CMD` to run through it (kept `app.run()` only for local/manual use). **Why it mattered:** production traffic needs a real WSGI server for concurrency and stability.

## app/requirements.txt

5. **`flask` with no version pin.** An unpinned dependency means every build can silently pull a different version — a classic "works on my machine, breaks in CI" bug, and a supply-chain risk.
   **Fix:** pinned `flask==3.0.3`, added `gunicorn==22.0.0`. **Why it mattered:** reproducible builds and no surprise breaking changes.

## Dockerfile

6. **`FROM python:latest`.** Unpinned base image — different, unpredictable Python version on every build; also a much larger image than needed.
   **Fix:** pinned to `python:3.11-slim`. **Why it mattered:** reproducibility and a much smaller attack surface / image size.

7. **Installed `build-essential`, `gcc`, `vim` in the image.** None of these are needed at runtime for a pure-Python Flask app (no C extensions being compiled here). They bloat the image and hand an attacker who gets a shell a compiler and an editor for free.
   **Fix:** removed all three; kept only `curl` (used by the container `HEALTHCHECK`). Also added `--no-install-recommends` and cleaned up `apt` lists. **Why it mattered:** smaller image, faster builds, smaller attack surface.

8. **`COPY . .` before installing dependencies.** This busts Docker's layer cache on every single code change, because the dependency-install layer gets invalidated even when `requirements.txt` didn't change.
   **Fix:** copy `requirements.txt` first, install, *then* copy the rest of the app. **Why it mattered:** much faster rebuilds in CI and locally.

9. **Container ran as root.** No `USER` directive means the process inside the container runs as root by default — if the app is compromised, so is root inside the container.
   **Fix:** created and switched to a non-root `appuser`. **Why it mattered:** standard container-hardening practice; limits blast radius of a compromise.

10. **No `HEALTHCHECK`.** Nothing told Docker/orchestrators whether the container was actually serving traffic.
    **Fix:** added a `HEALTHCHECK` hitting `/healthz`. **Why it mattered:** lets Docker/ECS/Kubernetes detect and restart an unhealthy container automatically.

11. **`CMD ["python", "app/app.py"]`.** Runs the insecure dev server (see #4). **Fix:** now runs `gunicorn`.

12. **No `.dockerignore`.** `COPY . .` would have pulled in `.git`, `infra/` (Terraform state/secrets risk), and other files that don't belong in the image.
    **Fix:** added `.dockerignore`. **Why it mattered:** smaller images, and avoids accidentally shipping secrets or unrelated files into a container.

## docker-compose.yml

13. **Port mismatch: `"5000:8080"`.** The app listens on 5000 inside the container, but compose forwarded host port 5000 to container port 8080 — nothing was there. This alone breaks task 1.
    **Fix:** changed to `"5000:5000"`.

14. **`postgres:latest` unpinned.** Same reproducibility problem as the Python base image — an untested new major version could pull in and break local dev without warning.
    **Fix:** pinned to `postgres:16-alpine`.

15. **`POSTGRES_PASSWORD=postgres` hardcoded in plaintext in a committed file.** Trivial, well-known default credential.
    **Fix:** moved to an env var sourced from a local `.env` (added `.env.example` as a template; real `.env` should never be committed). Compose now fails fast with a clear error if `POSTGRES_PASSWORD` isn't set, instead of silently using a weak default.

16. **No persistent volume for Postgres data.** Every `docker compose down` (or container recreation) would silently wipe the database.
    **Fix:** added a named volume `db-data` mounted at Postgres's data directory.

17. **`depends_on: [db]` without a readiness check.** `depends_on` only waits for the container to *start*, not for Postgres to actually be ready to accept connections — a classic race condition where the app boots before the DB is usable.
    **Fix:** added a `healthcheck` (`pg_isready`) to `db` and changed `depends_on` to `condition: service_healthy`.

18. **Obsolete `version: "3"` key.** Modern Docker Compose (v2 CLI) ignores/warns on this field.
    **Fix:** removed it — low priority, just cleanup.

## .github/workflows/ci.yml

19. **No checkout step at all.** The workflow ran `pip install` and `docker build` against whatever was already on the runner — which is nothing. This pipeline would never have actually built *this* code; it was silently broken.
    **Fix:** added `actions/checkout@v4` as the first step. **Why it mattered:** this is the single most "the CI never actually tested the real code" bug in the whole repo.

20. **Hardcoded registry credentials in plaintext (`docker login -u admin -p Sup3rS3cr3tPassw0rd`).** A secret committed straight into version control, visible to anyone with read access to the repo, forever, in git history.
    **Fix:** moved to `${{ secrets.REGISTRY_USERNAME }}` / `${{ secrets.REGISTRY_PASSWORD }}` GitHub Actions secrets.

21. **`pytest || true`.** This makes the test step always "pass," even when tests fail — CI turns green regardless of whether the code actually works. That's worse than no CI, because it gives false confidence.
    **Fix:** removed `|| true` so failing tests fail the build.

22. **Every push builds *and pushes* the `:latest` image, from any branch.** No branch protection means a feature branch or a broken PR branch can overwrite the production image tag.
    **Fix:** image build/tests run on every push (fast feedback), but the login/push steps are gated to `github.ref == 'refs/heads/main'`, and images are tagged with the commit SHA (in addition to `latest`) so a specific build can always be traced and rolled back to.

23. **No dependency caching.** Every run re-downloaded pip packages from scratch.
    **Fix:** added `cache: "pip"` to `actions/setup-python`. Minor, but saves CI minutes on every run.

## infra/main.tf

24. **`aws_instance` sized `m5.4xlarge`** (16 vCPU / 64 GB RAM) for a small Flask API that returns three JSON endpoints. This is the single biggest cost problem in the repo — that instance class runs roughly 20-30x the cost of something appropriately sized, for zero benefit.
    **Fix:** resized to `t3.micro`.

25. **500 GB `gp2` root volume.** Wildly oversized for a container host with no persistent app data, and `gp2` is both slower and more expensive per-GB than `gp3` at the same performance tier.
    **Fix:** resized to 20 GB and switched to `gp3`.

26. **`aws_db_instance` sized `db.m5.2xlarge`** for what's clearly a small orders table. Same problem as #24, on the DB side — this is a very large, very expensive instance class for the workload implied by the app.
    **Fix:** resized to `db.t3.micro`, reduced `allocated_storage` from 100 GB to 20 GB.

27. **`multi_az = true`.** Multi-AZ roughly doubles RDS cost by running a synchronous standby replica. Reasonable for a real production database with an uptime SLA, but wasteful for what looks like a dev/test resource in this exercise.
    **Fix:** set to `false`, with a comment noting it's a deliberate trade-off to revisit if this becomes a real prod workload.

28. **Database password hardcoded in plaintext in a committed `.tf` file (`"MyDbPassword123"`).** Same class of problem as the CI credentials — a permanent, readable secret in version control.
    **Fix:** replaced with a `sensitive = true` Terraform variable with no default, meant to be supplied via `TF_VAR_db_password` or an untracked `*.tfvars` file.

29. **SSH (port 22) open to `0.0.0.0/0`.** Anyone on the internet could attempt to reach SSH on this instance.
    **Fix:** restricted to a configurable `admin_cidr` variable (placeholder value included, meant to be replaced with a real narrow range). Ideally this instance would use AWS SSM Session Manager instead of SSH entirely, but that's a bigger architectural change than this exercise's scope — noted here rather than implemented.

30. **RDS storage not encrypted at rest.** `storage_encrypted` wasn't set (defaults to `false`).
    **Fix:** set `storage_encrypted = true`.

31. **No backup retention configured for RDS.** Left at the implicit default, which can be `0` (no automated backups).
    **Fix:** set `backup_retention_period = 7`.

32. **Added `metadata_options { http_tokens = "required" }` on the EC2 instance** to enforce IMDSv2. Not something I "found broken" so much as a low-effort, high-value hardening step against SSRF-to-credential-theft — a well-known EC2 attack pattern.

## Explicitly not fixed (flagged, out of scope for this pass)

- **No VPC/subnet/ALB design.** The instance and RDS resource have no explicit VPC, so they'd land in the default VPC. A real deployment should put the EC2 instance and RDS behind a proper VPC with private subnets for the DB and a load balancer in front of the app, rather than exposing port 5000 directly on the instance. Left out because it's a genuinely bigger design task than the 2-3 hour box for this exercise, not because it doesn't matter.
- **App-level input validation / auth on `/orders`.** The endpoint is a hardcoded stub right now with no real data layer, so there's nothing to validate yet — flagging that once this connects to the real Postgres DB, it'll need proper query parameterization and auth.
- **Terraform state backend.** `main.tf` has no `backend` block (state would default to local). For a team, this should be a remote backend (S3 + DynamoDB lock) — skipped since there's no real AWS account for this exercise anyway.
- **Image vulnerability scanning in CI** (e.g., Trivy/Grype) — good next step, cut for time.

## What I'd do next with more time

- Move the DB password to AWS Secrets Manager / `manage_master_user_password` on the RDS resource instead of a plain Terraform variable.
- Add a load balancer / ALB in front of the API instance instead of exposing port 5000 directly.
- Add CI image vulnerability scanning (e.g. Trivy/Grype).

---

## Round 2 — follow-up review fixes

A second review pass flagged a few remaining gaps. Fixes below.

### 1. CI `pytest` step had no tests to run (real bug — CI would fail)
There was no `tests/` directory, so `pytest` would exit non-zero with "file or directory not found," breaking every CI run.
**Fix:** added `tests/test_app.py` covering `/`, `/healthz`, `/orders`, and a 404 case, plus `tests/conftest.py` with a Flask test-client fixture. Added `app/requirements-dev.txt` (installs `requirements.txt` + `pytest`) and pointed CI at it. CI now also sets a throwaway `SECRET_KEY` for the test job, since `app.py` requires one (see #2). `tests/` and `requirements-dev.txt` are excluded from the Docker build via `.dockerignore` so they don't ship in the runtime image.

### 2. `SECRET_KEY` silently fell back to an insecure default
`os.environ.get("SECRET_KEY", "dev-only-insecure-key")` meant a misconfigured deploy that forgot to set `SECRET_KEY` would start up fine with a well-known key instead of failing loudly.
**Fix:** `app.py` now does `os.environ["SECRET_KEY"]` and raises a clear `RuntimeError` with instructions if it's missing. `docker-compose.yml`'s `SECRET_KEY` line was updated the same way `POSTGRES_PASSWORD` already was (`${SECRET_KEY:?set SECRET_KEY in your .env file}`), and `.env.example` already documents it.

### 3. Terraform was still using the default VPC, with no IAM role or outputs
Flagged in round 1 as out-of-scope; addressed now.
**Fix:** `main.tf` now defines its own VPC, an internet gateway + public subnet for the API instance, two private subnets + a DB subnet group for RDS, and a dedicated `db_sg` that only accepts Postgres traffic from the API's security group (previously RDS had no security group attached at all). Added an IAM role + instance profile (SSM-managed, so the box can be reached via Session Manager instead of SSH). Pulled the hardcoded values out into `variable` blocks (region, environment, instance sizes, CIDRs, AMI) and added `output` blocks for the instance IP/ID, VPC ID, and DB endpoint. Left a commented-out `backend "s3"` block with instructions, since there's no real bucket/table to point at for this exercise.

### 4. Docker image hardening
**Fix:** added `ENV PYTHONUNBUFFERED=1` and `ENV PYTHONDONTWRITEBYTECODE=1` to the Dockerfile.

### 5. Healthcheck interval
**Fix:** bumped from `--interval=30s` to `--interval=60s` per reviewer preference — not a correctness issue, just a lighter polling cadence.

### 6. Postgres image pinned by floating minor tag
`postgres:16-alpine` can move to a new patch release on any rebuild.
**Fix:** pinned to `postgres:16.4-alpine` and left a comment with the exact `docker inspect` command to grab an immutable `@sha256` digest for a real production deploy (couldn't hardcode a digest here without a live registry pull).

### Not changed
- **Gunicorn as entrypoint** — this was already correct in the version reviewed (`CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--chdir", "app", "app:app"]`); the earlier review just couldn't see the full file due to truncation.

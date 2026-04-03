# Infrastructure Runbook

Operational procedures for the AI Client Onboarding Pipeline. Each section is a self-contained procedure — use the table of contents to jump to what you need.

---

## Table of Contents

1. [Initial Production Deployment](#1-initial-production-deployment)
2. [Supabase (PostgreSQL) Setup](#2-supabase-postgresql-setup)
3. [Cloudflare R2 (Object Store) Setup](#3-cloudflare-r2-object-store-setup)
4. [Upstash Redis Setup](#4-upstash-redis-setup)
5. [Render Deployment (API + Workers)](#5-render-deployment-api--workers)
6. [Vercel Deployment (Dashboard)](#6-vercel-deployment-dashboard)
7. [Rotating Secrets](#7-rotating-secrets)
8. [Handling a Dead-Letter Job](#8-handling-a-dead-letter-job)
9. [Restoring from a Database Backup](#9-restoring-from-a-database-backup)
10. [Scaling the Workers](#10-scaling-the-workers)
11. [Incident Response Checklist](#11-incident-response-checklist)

---

## 1. Initial Production Deployment

**Time required:** ~60 minutes for a first-time setup.

**Access needed:** Accounts on Supabase, Cloudflare, Upstash, Render, Vercel, SendGrid (or Resend).

### Order of operations

Complete these in order — each step produces credentials used by the next.

```
Supabase → R2 → Upstash → Render (API) → Render (Worker) → Vercel (Dashboard)
```

Proceed to sections 2–6 in sequence.

---

## 2. Supabase (PostgreSQL) Setup

### Create a project

1. Go to [supabase.com](https://supabase.com) → New project.
2. Name: `ai-onboarding-prod`, Region: closest to your Render region.
3. Set a strong database password — save it in your password manager immediately.
4. Wait ~2 minutes for provisioning.

### Get the connection string

1. Project Settings → Database → Connection string → URI.
2. Copy the `postgresql://...` string. Replace `[YOUR-PASSWORD]` with the password you set.
3. Store as `DATABASE_URL` in Render environment variables (section 5).

### Run migrations

Once Render is deployed (section 5), run migrations via a one-off job:

```bash
# From your local machine, with DATABASE_URL pointing to Supabase
alembic upgrade head
```

Or trigger it from Render as a one-off command after the first deploy.

### Enable pgvector (optional — for RAG over past proposals)

In the Supabase SQL editor:

```sql
create extension if not exists vector;
```

### Verify

```bash
psql $DATABASE_URL -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';"
```

You should see: `leads`, `lead_scores`, `proposals`, `alembic_version`.

---

## 3. Cloudflare R2 (Object Store) Setup

### Create a bucket

1. Cloudflare dashboard → R2 → Create bucket.
2. Name: `ai-onboarding-proposals`, Location: Auto.

### Create API credentials

1. R2 → Manage R2 API tokens → Create API token.
2. Permissions: **Object Read & Write** scoped to `ai-onboarding-proposals`.
3. Save `Access Key ID` and `Secret Access Key` — shown only once.

### Note your Account ID

Top-right of Cloudflare dashboard — 32-character hex string.

### Environment variables (add to Render)

```
R2_ACCOUNT_ID=<your-cloudflare-account-id>
R2_ACCESS_KEY_ID=<access-key-id>
R2_SECRET_ACCESS_KEY=<secret-access-key>
R2_BUCKET_NAME=ai-onboarding-proposals
```

### Optional: public access for proposal download links

If you want the admin dashboard to link directly to proposal files:
1. R2 bucket → Settings → Public Access → Allow access.
2. Set a custom domain (e.g. `proposals.yourdomain.com`) via the R2 custom domain feature.

---

## 4. Upstash Redis Setup

### Create a database

1. Go to [upstash.com](https://upstash.com) → Create database.
2. Name: `ai-onboarding-queue`, Region: match your Render region, Type: Regional.
3. Free tier supports 10,000 commands/day — sufficient for < 50 leads/week.

### Get the connection URL

1. Database page → REST API section → copy the `REDIS_URL` (`rediss://...`).

### Environment variable

```
REDIS_URL=rediss://default:<password>@<host>.upstash.io:6379
```

---

## 5. Render Deployment (API + Workers)

### Deploy the API service

1. Render dashboard → New → Web Service.
2. Connect your GitHub repo.
3. Configure:
   - **Name:** `ai-onboarding-api`
   - **Runtime:** Python 3
   - **Build command:** `pip install -r requirements.txt`
   - **Start command:** `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
   - **Instance type:** Starter ($7/month)

4. Add all environment variables (from sections 2–4 plus the keys below):

```
API_KEY=<generate with: openssl rand -hex 32>
LLM_PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...
SENDGRID_API_KEY=SG....
NOTIFICATION_EMAIL=you@yourdomain.com
QUALIFY_SCORE_THRESHOLD=70
QUALIFY_MIN_BUDGET_USD=3000
```

5. Deploy. Once live, visit `https://your-app.onrender.com/health` — expect `{"status": "ok", ...}`.

### Deploy the Worker service

1. Render → New → Background Worker.
2. Same repo, same environment variables as the API service.
3. **Start command:** `python -m app.workers.runner`
4. Deploy.

> **Note:** The API and Worker services share the same environment variables. Use Render's Environment Groups to manage them in one place: Dashboard → Environment Groups → Create group → attach to both services.

---

## 6. Vercel Deployment (Dashboard)

1. Vercel → New Project → Import from GitHub, select the `dashboard/` subdirectory.
2. Framework preset: **Next.js**.
3. Add environment variables:

```
NEXT_PUBLIC_API_BASE_URL=https://your-app.onrender.com
API_KEY=<same key as Render>
```

4. Deploy. Visit the Vercel URL to confirm the dashboard loads and connects to the API.

### Set up magic link auth (Supabase Auth)

1. Supabase → Authentication → Providers → Email → Enable "Magic Link".
2. Add `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` to Vercel environment variables.
3. In `dashboard/lib/auth.ts`, confirm the allowed email is set to your address.

---

## 7. Rotating Secrets

### Rotate the API key

1. Generate a new key: `openssl rand -hex 32`
2. Update `API_KEY` in Render (both API and Worker Environment Group).
3. Update `API_KEY` in Vercel dashboard environment variables.
4. Trigger a redeploy on Render and Vercel.
5. If you have Typeform webhooks set up, update the `X-API-Key` header in the Typeform webhook settings.
6. Verify: `curl -H "X-API-Key: <new-key>" https://your-app.onrender.com/health`

### Rotate LLM API keys

1. Generate a new key in the OpenAI / Anthropic console. **Do not revoke the old key yet.**
2. Add the new key to Render environment variables → trigger redeploy.
3. Confirm `/health` returns `ok` and send a test intake submission.
4. Revoke the old key in the LLM provider console.

### Rotate database password (Supabase)

1. Supabase → Project Settings → Database → Reset database password.
2. Copy the new password and update `DATABASE_URL` in Render.
3. Trigger a Render redeploy.
4. Verify with: `psql $NEW_DATABASE_URL -c "SELECT 1"`

---

## 8. Handling a Dead-Letter Job

A job lands in the dead-letter queue after 3 failed retries. You will receive an email notification.

### Diagnose

1. Open the admin dashboard → Dead Letter tab, or query directly:

```bash
redis-cli -u $REDIS_URL LRANGE "bull:classify:failed" 0 -1
```

2. Check Render logs for the worker service around the time of failure:

```bash
render logs --service ai-onboarding-worker --tail 100
```

3. Common causes:

| Symptom in logs | Likely cause | Fix |
|---|---|---|
| `AuthenticationError` | LLM API key expired/invalid | Rotate key (section 7) |
| `ConnectionRefusedError: redis` | Redis connection dropped | Check Upstash status page |
| `asyncpg.InvalidPasswordError` | DB credentials rotated without updating Render | Update `DATABASE_URL` in Render |
| `LLMRateLimitError` | Hit token rate limit | Check LLM provider dashboard; increase tier if needed |
| `ProposalGenerationError: template not found` | Missing `.docx` template in R2 | Upload template: `aws s3 cp templates/proposal_base.docx s3://ai-onboarding-proposals/templates/` |

### Retry a failed job

```python
# From a Python shell with the app environment loaded
from app.workers.queue import get_queue

q = get_queue("classify")
failed_jobs = await q.get_failed()
for job in failed_jobs:
    await job.retry()
```

Or from the Bull dashboard (if enabled): `https://your-app.onrender.com/admin/queues`

---

## 9. Restoring from a Database Backup

Supabase automatically takes daily backups. Point-in-time recovery is available on paid plans.

### Restore to a point in time (paid plan)

1. Supabase → Project → Database → Backups → Point in Time Recovery.
2. Select the timestamp. Note: this restores the **entire database** — coordinate with any active usage.

### Restore from a daily snapshot (free plan)

1. Supabase → Database → Backups → select the date.
2. Download the `.sql` dump.
3. Restore to a new Supabase project first to verify integrity:

```bash
psql $NEW_DATABASE_URL < backup.sql
```

4. Once verified, apply to production:

```bash
psql $PROD_DATABASE_URL < backup.sql
```

> ⚠️ **Warning:** Restoring overwrites all current data. Consider exporting recent rows first if there have been new leads since the backup.

---

## 10. Scaling the Workers

The worker service processes jobs sequentially by default. If queue depth climbs (visible in `/health`), scale up.

### Increase worker concurrency (within the same instance)

In `app/workers/runner.py`, increase the concurrency setting:

```python
worker = Worker(queue, concurrency=4)  # was 1
```

Redeploy the worker service.

### Add a second worker instance (Render)

1. Render → Worker service → Scaling → Increase instance count to 2.
2. BullMQ handles distributed workers natively — no config change needed.
3. Monitor queue depth in `/health` to confirm it drains.

### Scale trigger thresholds

| Metric | Threshold | Action |
|---|---|---|
| Queue depth > 10 for > 5 min | Throughput issue | Increase worker concurrency |
| LLM cost > $50/month | Usage spike | Review rate limits; consider cheaper models for classify |
| DB storage > 400 MB | Growth | Upgrade Supabase tier or archive old records |

---

## 11. Incident Response Checklist

### Pipeline is not processing leads

- [ ] Check `/health` endpoint — is `db` and `redis` both `"connected"`?
- [ ] Check Render worker service status — is it running?
- [ ] Check Upstash Redis dashboard — any connection errors or quota hit?
- [ ] Check dead-letter queue depth in `/health` response.
- [ ] Check Render logs for the last error.

### Proposals are not being generated

- [ ] Is the `generate_proposal` queue depth climbing? (visible in `/health`)
- [ ] Check worker logs for LLM errors — key expired? Rate limit hit?
- [ ] Verify the proposal base template exists in R2: `aws s3 ls s3://ai-onboarding-proposals/templates/`
- [ ] Test manually: trigger a classify+qualify for a known good lead, then re-queue proposal generation.

### Dashboard shows no leads

- [ ] Check browser console for API errors.
- [ ] Confirm `NEXT_PUBLIC_API_BASE_URL` in Vercel env is correct.
- [ ] Test the API directly: `curl -H "X-API-Key: <key>" https://your-app.onrender.com/leads`

### Duplicate leads being created

- [ ] Check the deduplication logic in `app/routers/intake.py` — leads with the same email within 24 hours should return `409`.
- [ ] If Typeform is sending duplicate webhook deliveries, enable idempotency key support in the webhook handler.

---

*Last updated: April 2026*

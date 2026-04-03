# Developer Onboarding Guide

Welcome to the AI Client Onboarding Pipeline. This guide gets you oriented — what exists, how it connects, and how to do the most common tasks without having to spelunk through the code.

**Time to complete:** ~30 minutes to a running local environment and your first test lead flowing through the pipeline.

---

## 1. What This System Does (in plain English)

When a prospective client fills in an intake form, the system:

1. Stores the lead in Postgres and puts a job on a Redis queue.
2. A **classifier worker** asks an LLM to categorise the lead (service type, urgency, complexity) and scores it.
3. A **qualifier worker** applies your business rules (budget thresholds, etc.) and decides whether to proceed.
4. A **proposal writer** uses an LLM plus a `.docx` template to generate a draft consulting proposal.
5. You get notified (email/Slack) and review the proposal in a simple web dashboard before sending it.

The pipeline is intentionally simple. There's no framework magic — it's FastAPI, a job queue, a few Python worker scripts, and a Next.js dashboard.

---

## 2. Set Up Your Local Environment

> **Prerequisites:** Python 3.11+, Node.js 20+, Docker Desktop, `git`.

### Clone and install

```bash
git clone https://github.com/your-org/ai-onboarding-pipeline.git
cd ai-onboarding-pipeline

# Python environment
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
pip install -r requirements-dev.txt   # dev tools: pytest, ruff, etc.

# Dashboard
cd dashboard && npm install && cd ..
```

### Start local infrastructure

```bash
docker compose up -d
```

This starts:
- **PostgreSQL** on `localhost:5432`
- **Redis** on `localhost:6379`

### Configure environment

```bash
cp .env.example .env
```

The minimum you need for local dev:

```dotenv
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/onboarding
REDIS_URL=redis://localhost:6379
API_KEY=dev-secret
LLM_PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...    # or set OPENAI_API_KEY and LLM_PROVIDER=openai
```

Everything else (R2, SendGrid, Slack) is optional locally — the app falls back to local file storage and skips notifications if those keys are absent.

### Run migrations

```bash
alembic upgrade head
```

### Start the services

```bash
# Terminal 1: API
uvicorn app.main:app --reload --port 8000

# Terminal 2: Workers
python -m app.workers.runner

# Terminal 3: Dashboard
cd dashboard && npm run dev
```

### Send a test lead

```bash
curl -X POST http://localhost:8000/intake \
  -H "X-API-Key: dev-secret" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Client",
    "email": "test@example.com",
    "company": "Acme Corp",
    "problem_description": "We manually process 200 invoices a month and want to automate the extraction and approval workflow.",
    "budget_range": "$8,000 - $12,000",
    "timeline": "3 months"
  }'
```

Watch Terminal 2 — you should see the three workers fire in sequence and a `.docx` written to `./uploads/` within ~60 seconds. The dashboard at `http://localhost:3000` will show the lead under "Ready for Review".

---

## 3. Codebase Map

Here's where everything lives and why:

```
app/
├── main.py                  Entry point. Registers routers, middleware, startup events.
│
├── routers/
│   ├── intake.py            POST /intake — validates payload, writes to DB, enqueues job.
│   │                        Also contains typeform_to_intake() for webhook transforms.
│   └── leads.py             GET /leads, GET /leads/{id}, PATCH /leads/{id}/status
│
├── models/
│   ├── lead.py              SQLAlchemy Lead model
│   ├── lead_score.py        LeadScore model
│   └── proposal.py          Proposal model
│
├── schemas/
│   ├── intake.py            Pydantic schema for POST /intake request body
│   └── lead.py              Response schemas
│
├── workers/
│   ├── runner.py            Starts all three worker processes. Entry point for the worker dyno.
│   ├── classifier.py        Job: classify lead type, urgency, complexity via LLM.
│   ├── qualifier.py         Job: apply rules + optional LLM fit score.
│   └── proposal.py          Job: generate .docx proposal, upload to storage.
│
├── services/
│   ├── llm.py               LLM abstraction layer. Call llm.complete(prompt) — it picks
│   │                        the right provider based on LLM_PROVIDER env var.
│   ├── storage.py           File storage abstraction. Uses R2 in production, local
│   │                        ./uploads/ folder in dev (auto-detected by env vars).
│   └── notify.py            Sends email (SendGrid) and/or Slack webhook. No-ops if
│                            keys are absent — safe to run without them locally.
│
├── prompts/
│   ├── classify_v1.txt      Prompt template for the classifier worker.
│   ├── qualify_v1.txt       Prompt template for the qualifier worker.
│   └── proposal_v1.txt      Prompt template for the proposal writer.
│                            Filename convention: {name}_v{version}.txt
│
└── templates/
    └── proposal_base.docx   Base Word template used by the proposal writer.
                             Modify this to change the proposal layout/branding.
```

---

## 4. Key Concepts

### The job queue

Jobs flow through three queues in order:

```
classify  →  qualify  →  generate_proposal
```

Each worker pulls from its queue, does its work, and if successful enqueues the next job. If a job fails, it retries up to `MAX_JOB_RETRIES` (default: 3) times with exponential backoff, then moves to the dead-letter queue.

You can inspect queue state via the `/health` endpoint or the Bull dashboard at `/admin/queues`.

### The LLM abstraction

`app/services/llm.py` exposes a single function:

```python
response = await llm.complete(
    prompt="...",
    system="...",
    output_format="json",   # or "text"
    model_tier="fast",      # "fast" = Haiku/GPT-4o-mini, "quality" = Sonnet/GPT-4o
)
```

`model_tier` is how the workers pick the right model without hardcoding names. The classifier uses `"fast"` (cheap). The proposal writer uses `"quality"` (better output). When you want to change which model is used, edit the tier mappings in `llm.py` — you don't need to touch the workers.

### Prompt versioning

All prompts live in `app/prompts/` as versioned text files. The workers always load the latest version unless pinned. Every LLM call logs the prompt version used alongside the response — this makes it easy to trace why a proposal came out a certain way.

To iterate on a prompt: duplicate the file with a bumped version number, test it locally, then swap the default in the worker.

### Qualification rules

Rules live as plain Python functions in `app/workers/qualifier.py`:

```python
def check_budget(lead: Lead) -> QualificationResult:
    if lead.budget_min and lead.budget_min >= MIN_BUDGET_USD:
        return QualificationResult(passed=True, reason="Budget meets threshold")
    return QualificationResult(passed=False, reason="Budget below threshold")
```

Rules run in order. First failure short-circuits the chain. If all rules pass, the LLM fit scorer runs (optional, controlled by `QUALIFY_SCORE_THRESHOLD`).

To add a new rule: write a function matching the signature above and add it to the `RULES` list at the top of `qualifier.py`.

---

## 5. Common Tasks

### Add a new intake form field

1. Add the field to `app/schemas/intake.py` (Pydantic model).
2. Add the column to `app/models/lead.py` (SQLAlchemy model).
3. Generate a migration: `alembic revision --autogenerate -m "add field_name to leads"`
4. Run: `alembic upgrade head`
5. Update the classifier prompt in `app/prompts/` if the field should influence classification.

### Change the proposal template

The base `.docx` template lives at `app/templates/proposal_base.docx`. Open it in Word, make your changes (styles, logo, layout), save, and restart the worker. In production, upload the new template to R2:

```bash
aws s3 cp app/templates/proposal_base.docx \
  s3://ai-onboarding-proposals/templates/proposal_base.docx \
  --endpoint-url https://<account-id>.r2.cloudflarestorage.com
```

### Change the qualification score threshold

Update `QUALIFY_SCORE_THRESHOLD` in your `.env` (local) or Render environment variables (production). No code change needed — it's read at worker startup.

### Re-run a failed proposal for a lead

```python
# From a Python shell in the app environment
from app.workers.queue import enqueue
await enqueue("generate_proposal", {"lead_id": "a3f7e291-..."})
```

Or use the dashboard: Leads → [lead] → Actions → Regenerate Proposal.

### Add a new notification channel

Implement the `NotificationChannel` protocol in `app/services/notify.py` and add it to the `CHANNELS` list. The existing `EmailChannel` and `SlackChannel` are good references.

### Run the test suite

```bash
pytest tests/ -v                      # All tests
pytest tests/workers/ -v              # Worker tests only
pytest tests/ -k "test_qualify" -v    # Tests matching a name
```

Tests mock all LLM calls and external services — no API keys needed.

---

## 6. Environments

| Environment | API URL | Dashboard URL | Database |
|---|---|---|---|
| Local dev | `localhost:8000` | `localhost:3000` | Docker Postgres |
| Production | `your-app.onrender.com` | `your-dashboard.vercel.app` | Supabase |

There is no staging environment at current scale. Test significant changes locally before deploying to production.

To deploy to production: push to `main` branch. Render and Vercel auto-deploy on push.

---

## 7. Observability

### Logs

- **Local:** stdout from all three terminals.
- **Production:** Render dashboard → Service → Logs. Filter by `[worker]`, `[api]`, or `[ERROR]`.

All log lines are structured JSON:

```json
{"level": "info", "service": "worker.classifier", "lead_id": "a3f7e291", "model": "claude-haiku-4-5", "duration_ms": 2341, "result": "automation"}
```

### Error tracking

Sentry is configured in `app/main.py` and `app/workers/runner.py`. Set `SENTRY_DSN` in env to enable. Errors surface in your Sentry project with full stack traces and lead IDs as context.

### Health check

```bash
curl https://your-app.onrender.com/health
```

The `queue_depth.dead_letter` field is the most important signal — it should be `0`. If it's climbing, check the worker logs immediately.

---

## 8. Architecture Reference

For a full component diagram, data model, trade-off analysis, and implementation roadmap, see the **System Design document**:

📄 `ai_onboarding_pipeline_design.docx` (in the project outputs folder)

---

*Last updated: April 2026*

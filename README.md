# AI Client Onboarding Pipeline

> Automates intake, qualification, and proposal generation for a small business AI consulting practice.

---

## What This Is

When a prospective client submits an intake form (or sends an email), this pipeline:

1. **Classifies** the lead — service category, urgency, and complexity — using an LLM.
2. **Qualifies** it using configurable business rules plus an optional LLM fit score.
3. **Generates a draft proposal** (`.docx`) tailored to the client's stated needs.
4. **Notifies you** via email or Slack so you can review, edit, and send — all from a lightweight admin dashboard.

**Stack at a glance:** Python / FastAPI · Redis + BullMQ · PostgreSQL (Supabase) · Cloudflare R2 · OpenAI / Anthropic · Next.js dashboard · Deployed on Render + Vercel.

---

## Quick Start (local dev, ~5 minutes)

### Prerequisites

- Python 3.11+
- Node.js 20+
- Docker (for local Redis + Postgres)

### 1. Clone & install

```bash
git clone https://github.com/your-org/ai-onboarding-pipeline.git
cd ai-onboarding-pipeline

# Python API + workers
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Dashboard
cd dashboard && npm install && cd ..
```

### 2. Start infrastructure

```bash
docker compose up -d   # starts Postgres + Redis locally
```

### 3. Configure environment

```bash
cp .env.example .env
```

Open `.env` and fill in:

```dotenv
# LLM (pick one or both — the pipeline switches via LLM_PROVIDER)
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
LLM_PROVIDER=anthropic          # or "openai"

# Database
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/onboarding

# Redis
REDIS_URL=redis://localhost:6379

# Object store (local dev: uses a local ./uploads folder if left blank)
R2_ACCOUNT_ID=
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
R2_BUCKET_NAME=

# Notifications
SENDGRID_API_KEY=
NOTIFICATION_EMAIL=you@yourdomain.com

# API auth
API_KEY=dev-secret-change-me
```

### 4. Run database migrations

```bash
alembic upgrade head
```

### 5. Start the services

In three separate terminals:

```bash
# Terminal 1 — API gateway
uvicorn app.main:app --reload --port 8000

# Terminal 2 — Workers
python -m app.workers.runner

# Terminal 3 — Dashboard
cd dashboard && npm run dev
```

The API is live at `http://localhost:8000`
The dashboard is at `http://localhost:3000`

### 6. Submit a test lead

```bash
curl -X POST http://localhost:8000/intake \
  -H "X-API-Key: dev-secret-change-me" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "rajiv sharma",
    "email": "rajiv@example.com",
    "company": "KryptonAI",
    "problem_description": "We spend 20 hours a week manually copying data between spreadsheets and our accounting system. We have 8 staff and want to automate this.",
    "budget_range": "$5,000 - $10,000",
    "timeline": "2-3 months",
    "source": "form"
  }'
```

Watch the workers terminal — classification, qualification, and proposal generation will run automatically. Check the dashboard at `http://localhost:3000` to see the result.

---

## Project Structure

```
ai-onboarding-pipeline/
├── app/
│   ├── main.py              # FastAPI entry point
│   ├── models/              # SQLAlchemy ORM models
│   ├── schemas/             # Pydantic request/response schemas
│   ├── routers/
│   │   ├── intake.py        # POST /intake
│   │   └── leads.py         # GET /leads, GET /leads/{id}
│   ├── workers/
│   │   ├── runner.py        # Worker process entry point
│   │   ├── classifier.py    # LLM classify job
│   │   ├── qualifier.py     # Rule engine + LLM qualify job
│   │   └── proposal.py      # Proposal generation job
│   ├── services/
│   │   ├── llm.py           # LLM abstraction (OpenAI / Anthropic)
│   │   ├── storage.py       # R2 / local file storage
│   │   └── notify.py        # Email + Slack notifications
│   ├── prompts/             # Prompt templates (versioned)
│   └── templates/           # Proposal .docx base templates
├── dashboard/               # Next.js admin dashboard
├── migrations/              # Alembic migrations
├── docker-compose.yml       # Local dev infrastructure
├── .env.example
├── requirements.txt
└── README.md
```

---

## Configuration Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `LLM_PROVIDER` | Yes | `anthropic` | `anthropic` or `openai` |
| `ANTHROPIC_API_KEY` | If provider=anthropic | — | Claude API key |
| `OPENAI_API_KEY` | If provider=openai | — | OpenAI API key |
| `DATABASE_URL` | Yes | — | PostgreSQL connection string |
| `REDIS_URL` | Yes | — | Redis connection string |
| `API_KEY` | Yes | — | Header auth key for the gateway |
| `QUALIFY_SCORE_THRESHOLD` | No | `70` | Min fit score (0–100) to auto-advance to proposal |
| `QUALIFY_MIN_BUDGET_USD` | No | `3000` | Min budget to auto-qualify without LLM scoring |
| `R2_BUCKET_NAME` | No | — | Leave blank to use local `./uploads` folder |
| `SENDGRID_API_KEY` | No | — | Leave blank to skip email notifications |
| `SLACK_WEBHOOK_URL` | No | — | Leave blank to skip Slack notifications |
| `MAX_JOB_RETRIES` | No | `3` | Max retries before dead-letter queue |

---

## Running Tests

```bash
pytest tests/ -v
```

Tests use a local SQLite database and mock LLM calls — no API keys needed.

---

## Deployment

See [RUNBOOK.md](./RUNBOOK.md) for full production deployment steps on Render + Supabase + Cloudflare R2.

---

## Contributing

This is a solo-operator project. To add a new LLM provider, implement the `LLMProvider` interface in `app/services/llm.py`. To change qualification rules, edit `app/workers/qualifier.py` — rules are plain Python functions, no framework needed.

# API Reference

Base URL: `https://your-app.onrender.com` (production) · `http://localhost:8000` (local)

---

## Authentication

All endpoints require an `X-API-Key` header.

```
X-API-Key: <your-api-key>
```

The key is set via the `API_KEY` environment variable. If the key is missing or incorrect, the API returns `401`.

---

## Endpoints

### `POST /intake`

Submit a new client lead. Triggers the full pipeline: classify → qualify → generate proposal.

**Request**

```http
POST /intake
Content-Type: application/json
X-API-Key: your-key
```

```json
{
  "name": "Priya Nair",
  "email": "priya@example.com",
  "company": "Nair Logistics",
  "problem_description": "We spend 20 hours a week manually copying data between spreadsheets and our accounting system.",
  "budget_range": "$5,000 - $10,000",
  "timeline": "2-3 months",
  "source": "form"
}
```

**Request fields**

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | Yes | Contact's full name |
| `email` | string | Yes | Contact email (must be valid format) |
| `company` | string | No | Company or organisation name |
| `problem_description` | string | Yes | Free-text description of the problem or goal |
| `budget_range` | string | No | e.g. `"$3,000 - $5,000"` or `"< $2,000"` |
| `timeline` | string | No | e.g. `"1 month"`, `"ASAP"`, `"Q3 2026"` |
| `source` | string | No | `"form"` \| `"email"` \| `"manual"` (defaults to `"form"`) |
| `raw_payload` | object | No | Pass-through of the original webhook body (stored, not processed) |

**Response `201 Created`**

```json
{
  "lead_id": "a3f7e291-1c4b-4d2e-b8a0-9f3d2c1e5f07",
  "status": "queued",
  "message": "Lead received and processing started."
}
```

**Response fields**

| Field | Description |
|---|---|
| `lead_id` | UUID for the lead — use this in subsequent `GET /leads/{id}` calls |
| `status` | Always `"queued"` on success |
| `message` | Human-readable confirmation |

**Example (curl)**

```bash
curl -X POST https://your-app.onrender.com/intake \
  -H "X-API-Key: your-key" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Priya Nair",
    "email": "priya@example.com",
    "company": "Nair Logistics",
    "problem_description": "We spend 20 hours a week manually copying data between spreadsheets.",
    "budget_range": "$5,000 - $10,000",
    "timeline": "2-3 months"
  }'
```

---

### `GET /leads`

List all leads with optional filtering. Intended for the admin dashboard and internal use only.

**Request**

```http
GET /leads?status=proposal_ready&limit=20&offset=0
X-API-Key: your-key
```

**Query parameters**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `status` | string | — | Filter by status (see status values below) |
| `source` | string | — | Filter by source (`form`, `email`, `manual`) |
| `limit` | int | `50` | Max records to return (max: 100) |
| `offset` | int | `0` | Pagination offset |
| `order` | string | `created_at_desc` | `created_at_asc` \| `created_at_desc` \| `score_desc` |

**Lead status values**

| Status | Meaning |
|---|---|
| `new` | Received, not yet classified |
| `classified` | LLM classification complete |
| `qualified` | Passed qualification, proposal pending |
| `disqualified` | Did not meet qualification criteria |
| `proposal_ready` | Draft proposal generated, awaiting review |
| `proposal_sent` | Proposal sent to client |
| `won` | Engagement confirmed |
| `lost` | Engagement declined or went cold |

**Response `200 OK`**

```json
{
  "total": 42,
  "limit": 20,
  "offset": 0,
  "leads": [
    {
      "lead_id": "a3f7e291-1c4b-4d2e-b8a0-9f3d2c1e5f07",
      "name": "Priya Nair",
      "email": "priya@example.com",
      "company": "Nair Logistics",
      "status": "proposal_ready",
      "source": "form",
      "fit_score": 85,
      "service_category": "automation",
      "urgency": "medium",
      "created_at": "2026-04-03T10:22:31Z",
      "proposal_url": "https://r2.yourdomain.com/proposals/a3f7e291.docx"
    }
  ]
}
```

**Example (curl)**

```bash
curl "https://your-app.onrender.com/leads?status=proposal_ready" \
  -H "X-API-Key: your-key"
```

---

### `GET /leads/{lead_id}`

Get full detail for a single lead, including classification scores, qualification result, and proposal status.

**Request**

```http
GET /leads/a3f7e291-1c4b-4d2e-b8a0-9f3d2c1e5f07
X-API-Key: your-key
```

**Response `200 OK`**

```json
{
  "lead_id": "a3f7e291-1c4b-4d2e-b8a0-9f3d2c1e5f07",
  "name": "Priya Nair",
  "email": "priya@example.com",
  "company": "Nair Logistics",
  "problem_description": "We spend 20 hours a week manually copying data between spreadsheets and our accounting system.",
  "budget_range": "$5,000 - $10,000",
  "timeline": "2-3 months",
  "source": "form",
  "status": "proposal_ready",
  "created_at": "2026-04-03T10:22:31Z",
  "score": {
    "service_category": "automation",
    "urgency": "medium",
    "complexity": "low",
    "fit_score": 85,
    "rationale": "Clear automation use case with defined scope, realistic budget, and reasonable timeline. Likely 4–8 hours of discovery + build.",
    "classifier_model": "claude-haiku-4-5",
    "scored_at": "2026-04-03T10:22:45Z"
  },
  "proposal": {
    "proposal_id": "d1e2f3a4-5b6c-7d8e-9f0a-1b2c3d4e5f6a",
    "version": 1,
    "status": "pending_review",
    "doc_url": "https://r2.yourdomain.com/proposals/a3f7e291-v1.docx",
    "generated_at": "2026-04-03T10:23:18Z",
    "generator_model": "claude-sonnet-4-6"
  }
}
```

**Example (curl)**

```bash
curl "https://your-app.onrender.com/leads/a3f7e291-1c4b-4d2e-b8a0-9f3d2c1e5f07" \
  -H "X-API-Key: your-key"
```

---

### `PATCH /leads/{lead_id}/status`

Manually update the status of a lead. Used by the dashboard when a consultant approves a proposal or marks a deal won/lost.

**Request**

```http
PATCH /leads/a3f7e291-1c4b-4d2e-b8a0-9f3d2c1e5f07/status
Content-Type: application/json
X-API-Key: your-key
```

```json
{
  "status": "proposal_sent",
  "note": "Sent via email on 3 April 2026"
}
```

**Request fields**

| Field | Type | Required | Description |
|---|---|---|---|
| `status` | string | Yes | Any valid status value (see status table above) |
| `note` | string | No | Optional audit note stored with the change |

**Response `200 OK`**

```json
{
  "lead_id": "a3f7e291-1c4b-4d2e-b8a0-9f3d2c1e5f07",
  "status": "proposal_sent",
  "updated_at": "2026-04-03T11:05:00Z"
}
```

---

### `GET /health`

Health check endpoint. Returns service status and queue depth. No auth required.

**Response `200 OK`**

```json
{
  "status": "ok",
  "db": "connected",
  "redis": "connected",
  "queue_depth": {
    "classify": 0,
    "qualify": 1,
    "generate_proposal": 0,
    "dead_letter": 0
  },
  "version": "1.0.0"
}
```

Returns `503` if the database or Redis is unreachable.

---

## Error Responses

All errors follow this shape:

```json
{
  "error": "validation_error",
  "message": "Field 'email' is not a valid email address.",
  "detail": [
    { "field": "email", "issue": "invalid_format" }
  ]
}
```

| HTTP Status | Error Code | When It Happens |
|---|---|---|
| `400` | `validation_error` | Request body fails schema validation |
| `401` | `unauthorized` | Missing or invalid `X-API-Key` |
| `404` | `not_found` | Lead ID does not exist |
| `409` | `duplicate_lead` | A lead with the same email was submitted within the last 24 hours |
| `422` | `unprocessable` | Request is syntactically valid but semantically invalid (e.g. unknown status value) |
| `500` | `internal_error` | Unexpected server error — check logs |
| `503` | `service_unavailable` | Database or Redis connection failure |

---

## Webhook Integration (Typeform)

To connect a Typeform intake form, configure a webhook pointing to `POST /intake` with the `X-API-Key` header. Map Typeform fields to the intake schema in `app/routers/intake.py` under the `typeform_to_intake()` transform function.

The `raw_payload` field is automatically populated with the original webhook body for debugging.

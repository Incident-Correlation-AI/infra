# 📜 API & Data Contracts Guide — The Canonical Source of Truth

> **Derived from** `docs/API_AND_DATA_CONTRACTS.md`. Contracts are the **integration backbone** of this project: collectors, the detector, the API, the worker, and the dashboard all agree on them, and CI enforces that agreement.

**Source of truth (canonical files — do not maintain conflicting duplicate definitions anywhere):**

```
contracts/schemas/event.schema.json
contracts/schemas/incident.schema.json
contracts/schemas/api-errors.schema.json
contracts/openapi.yaml
```

This guide **explains the rules and shows how to implement them**. Where this guide and the canonical files ever disagree, **the canonical files win** — then fix this guide in the same PR.

---

## 1. High-Level Overview & Goals

### 1.1 Why contracts-first

Three properties fall out of treating contracts as the source of truth:

1. **Parallel development** — collectors, detection, cloud, and frontend tracks build against fixtures simultaneously without waiting for each other. (Risk mitigation: "Integration delays: contract-first parallel development and runnable fixtures.")
2. **Honest compatibility** — schema versions + an explicit unknown-field policy mean a new collector cannot silently break an old API.
3. **Testable truth** — contract tests turn "it works on my machine" into a machine-checkable claim.

### 1.2 Goals

| # | Goal |
|---|---|
| T1 | A versioned **event envelope** that all sources normalize into, with strict missing-data semantics |
| T2 | An **incident contract** that separates observations from hypotheses and recommendations |
| T3 | A precise **OpenAPI** spec for all six endpoints, including errors, auth, pagination, limits, status codes |
| T4 | Documented **idempotency and queue semantics** (accepted ≠ analyzed) |
| T5 | Server-enforced **authentication boundaries** (collector vs. admin) |
| T6 | A **compatibility policy** that keeps schema, fixtures, OpenAPI, tests, and docs evolving together |

### 1.3 Non-goals

- ❌ No undocumented endpoints or fields "just for now."
- ❌ No duplicated field definitions in code comments, wiki pages, or the dashboard.
- ❌ No "missing means zero" shortcuts anywhere.

---

## 2. System / Component Architecture & Design Patterns

### 2.1 How a contract change propagates

Every contract change touches **five artifacts together**, in one PR:

```
1. contracts/schemas/*.json  and/or  contracts/openapi.yaml   ← edit first
2. contracts/fixtures/*                                    ← add/adjust valid + invalid examples
3. src/lad/contracts/*  (typed models / validators)        ← regenerate or update by hand
4. tests/contract/*                                        ← update assertions; add new cases
5. docs (this guide + any consumer docs)                   ← no stale field tables
```

If any of the five is missing, the change is **incomplete** and CI should fail. This is the concrete meaning of "Update schema, example fixtures, OpenAPI, contract tests, and documentation together."

### 2.2 Patterns

| Pattern | Application |
|---|---|
| **Schema-on-the-wire / typed-in-code** | JSON Schema is authoritative; pydantic/dataclasses mirror it; contract tests prove they agree |
| **Fixture-driven development** | valid + invalid fixtures written before producers/consumers |
| **Explicit versioning** | `schema_version` on every envelope; `SUPPORTED_SCHEMA_VERSIONS` gate on ingest |
| **Tolerant reader** | unknown-field policy decides accept/ignore/preserve — documented, not accidental |
| **Problem-details errors** | one shared error schema (`api-errors.schema.json`) so clients handle failures uniformly |
| **Cursor pagination** | opaque cursors; never expose raw scan semantics |
| **Idempotency keys** | stable `event_id` as the natural idempotency key across retries |

### 2.3 Where contracts are enforced

```
collector ── validates on build (dev) ──► POST /events/batch
                                             │
                        API: validate against event.schema.json
                        (reject w/ per-event reason before enqueue)
                                             │
                                             ▼
                                          queue
                                             │
                        worker: re-validate defensively (trust nothing)
                                             │
                        incident.schema.json ◄── persisted incidents
                                             │
dashboard ◄── typed client generated from / validated against openapi.yaml
```

**Both ends validate.** The API validates because collectors can be buggy or malicious; the worker re-validates because the queue is at-least-once and messages could be stale or hand-crafted. The dashboard validates shapes (via types) so a contract drift shows up as a loud failure, not a blank screen.

---

## 3. Environment Setup & Prerequisites (contract tooling)

```bash
# schema + OpenAPI validation tooling (verify versions during setup)
pip install jsonschema openapi-spec-validator pytest

# add a pre-commit hook or a make target
make contract          # validates all fixtures against schemas; validates openapi.yaml
```

Recommended ergonomics:

```makefile
contract:
	python scripts/validate_fixtures.py contracts/fixtures contracts/schemas
	python -m openapi_spec_validator contracts/openapi.yaml
	pytest tests/contract -q
```

Optional but high-value: generate TypeScript types for the dashboard from `openapi.yaml` in CI, and fail the build if regeneration produces a diff that wasn't committed. That makes "the dashboard matches the contract" a mechanical property rather than a review hope.

---

## 4. Step-by-Step Implementation Guide

### 4.1 Event envelope

**Core fields (conceptual — the JSON Schema is authoritative):**

| Field | Type | Required | Rules |
|---|---|---|---|
| `schema_version` | string | ✅ | Must be in the supported list (e.g. `"1.0"`) |
| `event_id` | string | ✅ | **Stable across retries**; UUIDv7 recommended (time-ordered, sortable) |
| `event_ts` | string (date-time) | ✅ | **Timezone-aware**; normalized to **UTC** at the contract boundary |
| `observed_ts` | string (date-time) | ✅ | When the collector saw it; tz-aware UTC |
| `host` | string | ✅ | Host identity |
| `source` | string | ✅ | e.g. `journald`, `windows-eventlog`, `app-nginx` |
| `service` | string | ⬜ | Service name if known |
| `category` | string | ✅ | e.g. `http`, `auth`, `db`, `process` |
| `type` | string | ✅ | e.g. `http_5xx`, `auth_failure`, `service_restart` |
| `severity` | string enum | ✅ | `info` \| `warning` \| `error` \| `critical` |
| `message` | string | ✅ | Human-readable; **treated as untrusted data downstream** |
| `template` | string | ⬜ | Extracted pattern; `null` when infeasible |
| `attributes` | object | ⬜ | Source-specific **structured** fields; numeric attrs used by features |
| `trace_id` / `request_id` | string | ⬜ | Correlation identifiers when available |
| `depends_on` | array[string] | ⬜ | Known dependencies |
| `evidence_ref` | string | ⬜ | Pointer to **redacted** evidence, if any |

**Envelope rules (each has a test):**

1. **Timezone-aware timestamps**, normalized to UTC at the contract boundary. An event with a naive timestamp is **invalid** — never silently assume local time.
2. **Missing is not zero.** Optional numerics are `null`/absent; downstream code must skip, not default to `0`. (This is the rule that keeps `http_5xx_ratio = null` from becoming a fabricated `0.0`.)
3. **Stable IDs survive retries.** The same underlying event resent after a network failure carries the same `event_id`; the API/worker dedupe on it.
4. **Unknown optional fields** follow the documented compatibility policy (§4.6).
5. **Source-specific fields stay optional and structured** under `attributes` — never flattened into `message`.
6. **Never require every source to provide HTTP or database fields.** The envelope must be satisfiable by a journald collector that has no notion of HTTP status.
7. **Field and payload limits** enforced at ingestion (batch ≤ 100 events / ≤ 256 KB; per-field length caps).
8. **Raw evidence is optional and redacted.**

```jsonc
// contracts/fixtures/valid/http_5xx.json (illustrative)
{
  "schema_version": "1.0",
  "event_id": "0192f0c1-5c3e-7b2a-9f4e-0a1b2c3d4e5f",
  "event_ts": "2026-10-17T10:15:42.123Z",
  "observed_ts": "2026-10-17T10:15:42.400Z",
  "host": "host-alpha",
  "source": "app-nginx",
  "service": "svc-pay",
  "category": "http",
  "type": "http_5xx",
  "severity": "error",
  "message": "GET /pay/checkout returned 502",
  "template": "GET {path} returned {status}",
  "attributes": { "status": 502, "duration_ms": 812.4, "route": "/pay/checkout" },
  "trace_id": "8b3c1f0a9d2e47f5",
  "request_id": "req_7f3a",
  "depends_on": ["db-pay-primary"],
  "evidence_ref": null
}
```

### 4.2 Incident contract

Incident records include identity, lifecycle, severity, affected entities, anomalies, evidence, hypotheses, diagnostic checks, and audit/model versions.

**The single most important rule:**

> **Distinguish observations from hypotheses and recommendations.**

| Group | Fields | Nature |
|---|---|---|
| Identity | `incident_id`, `schema_version`, `created_at`, `updated_at` | observation |
| Lifecycle | `status`: `open` / `acknowledged` / `resolved` | workflow |
| Impact | `severity`, `affected_entities[]` | **estimated** impact (documented rules) |
| Detection | `anomaly_score`, `detector`, `model_versions{}`, windows | observation (detector-specific; **not** a probability) |
| Evidence | `evidence[]` with `supporting_event_ids`, `contradicting_event_ids` | observation |
| Hypotheses | `hypotheses[]`: `statement`, `confidence`, support/contradict/missing | **hypothesis** — may be `"Unknown"` |
| Actions | `diagnostic_checks[]`: specific, evidence-linked, **non-executing** | **recommendation** |
| Audit | `acknowledged_by/at`, `resolved_by/at`, actor identity | workflow record |

```jsonc
// contracts/fixtures/valid/incident_open.json (illustrative)
{
  "incident_id": "inc_01J8Z5K0R7",
  "schema_version": "1.0",
  "status": "open",
  "severity": "high",
  "affected_entities": [{ "host": "host-alpha", "service": "svc-pay", "source": "app-nginx" }],
  "anomaly_score": 0.93,
  "detector": "statistical_baseline",
  "model_versions": { "statistical_baseline": "rule-set-0002" },
  "windows": [{ "start": "2026-10-17T10:14:00Z", "end": "2026-10-17T10:16:00Z" }],
  "evidence": {
    "supporting_event_ids": ["evt_a", "evt_b", "evt_c"],
    "contradicting_event_ids": [],
    "redacted_refs": []
  },
  "hypotheses": [
    {
      "statement": "Database timeouts on db-pay-primary are associated with the HTTP 502 spike on svc-pay.",
      "confidence": "high",
      "supporting_event_ids": ["evt_a", "evt_b"],
      "contradicting_event_ids": [],
      "missing_evidence": ["No DB metrics from host-beta; db logs may not be collected there."]
    }
  ],
  "diagnostic_checks": [
    {
      "instruction": "Check whether db-pay-primary recorded connection-pool exhaustion between 10:14 and 10:16 UTC.",
      "evidence_links": ["evt_a"],
      "executes": false
    }
  ],
  "audit": []
}
```

- `supporting` **and** `contradicting` references are both stored — a hypothesis that only ever cites supporting evidence is not honest.
- **"Unknown" is a valid outcome:** `hypotheses[0].statement = "Unknown"`, with `missing_evidence` explaining what would be needed.
- Diagnostic checks carry `"executes": false` structurally, so the contract itself encodes "non-executing."

### 4.3 API surface (the six endpoints)

| Method | Path | Actor | Notes |
|---|---|---|---|
| `POST` | `/api/v1/events/batch` | **collector** | Returns a receipt with `accepted`/`rejected` counts |
| `GET` | `/api/v1/health` | anyone | No secrets/internal config leakage |
| `GET` | `/api/v1/incidents` | **admin** | Pagination + filters |
| `GET` | `/api/v1/incidents/{incident_id}` | **admin** | Full incident |
| `POST` | `/api/v1/incidents/{incident_id}/acknowledge` | **admin** | Lifecycle; writes audit |
| `POST` | `/api/v1/incidents/{incident_id}/resolve` | **admin** | Lifecycle; writes audit |

> "The OpenAPI spec defines exact request/response/error shapes, authentication, pagination, filtering, limits, and status codes. **Do not implement undocumented behavior.**"

**Ingestion receipt (shape lives in OpenAPI):**

```jsonc
{
  "receipt_id": "rcpt_01J...",
  "accepted": 97,
  "rejected": 3,
  "results": [
    { "index": 0,  "event_id": "evt_...", "status": "accepted" },
    { "index": 12, "event_id": null,       "status": "rejected",
      "reason": "invalid_timestamp", "detail": "event_ts must be timezone-aware" }
  ],
  "note": "Accepted events are queued for asynchronous processing; detection may not have completed."
}
```

⚠️ The receipt must make clear which events were accepted and which rejected — and that **API acceptance into the queue does not mean detection has completed.**

### 4.4 Shared error schema

All endpoints return the same error shape (from `api-errors.schema.json`):

```jsonc
{
  "error": {
    "code": "validation_failed",          // machine-readable, stable
    "message": "Human-readable summary",  // safe to log; no secrets
    "details": [                          // optional, structured
      { "index": 12, "field": "event_ts", "reason": "must be timezone-aware" }
    ],
    "request_id": "req_..."               // for support/debugging correlation
  }
}
```

**Status codes to document and test:**

| Code | When |
|---|---|
| `202` | Batch accepted into the queue (partial acceptance allowed with per-event outcomes) |
| `400` | Malformed request (bad JSON, missing batch wrapper) |
| `401` | Missing/invalid authentication |
| `403` | Authenticated but not authorized (e.g., collector hitting `/incidents`) |
| `404` | Unknown incident id |
| `413` | Payload too large (over batch/event limits) |
| `422` | Schema validation failed (whole-batch, when partial acceptance doesn't apply) |
| `429` | Throttled |
| `500` | Unexpected server error (should be rare; include `request_id`) |
| `503` | Dependency unavailable (queue/storage down) — retryable client-side |

Document **retryable vs. non-retryable** failures explicitly so collector backoff logic knows what to retry. Rule of thumb: `408/429/5xx` retryable; `4xx` (except 408/429) non-retryable.

### 4.5 Idempotency and queue semantics

- **Duplicate stable IDs must not create duplicate incidents.** Enforced at ingestion (dedupe) and again in the worker (idempotent upsert), because SQS is at-least-once.
- **Accepted ≠ analyzed.** The receipt reflects queue acceptance only. There is no synchronous detection path.
- **Partial batch acceptance is allowed** (recommended): per-index results make collector retry logic simple and prevent one bad event from poisoning a good batch.
- **Retryable vs non-retryable** is part of the contract, not an implementation detail.

### 4.6 Compatibility policy (decide once, test always)

An ADR must pick and document, per field class:

| Decision | Options | Recommendation |
|---|---|---|
| Unknown **optional** fields on input | accept / ignore / preserve | **accept and preserve** (forward-compat for newer collectors) — but never pass them into detection features unless documented |
| Unknown **required** fields | reject | reject — a required field is required |
| New **enum** values (e.g. new `severity`) | reject / accept | start **rejecting**; a coordinated rollout is safer than silently mis-classifying |
| Removing a field | major schema version bump | requires fixture + doc + consumer updates in lockstep |

Compatibility policy is tested with **specific fixtures**: `valid/unknown_optional_field.json`, `invalid/unknown_required_field.json`, etc.

### 4.7 Versioning

- Every envelope carries `schema_version`.
- The API **supports a documented set** (`SUPPORTED_SCHEMA_VERSIONS`) and rejects others with a clear error.
- Version bumps require: schema change → fixtures → OpenAPI → typed models → contract tests → docs → **and a note in the decision log** about collector rollout (older collectors in the field may lag).

---

## 5. Data Models & State Management (contracts track)

### 5.1 Typed models in code (mirror, don't diverge)

```python
# src/lad/contracts/event.py (illustrative)
SUPPORTED_SCHEMA_VERSIONS = ("1.0",)

class Severity(str, Enum):
    INFO = "info"; WARNING = "warning"; ERROR = "error"; CRITICAL = "critical"

@dataclass(frozen=True, slots=True)
class Event:
    schema_version: str
    event_id: str
    event_ts: datetime          # tz-aware; UTC
    observed_ts: datetime       # tz-aware; UTC
    host: str
    source: str
    category: str
    type: str
    severity: Severity
    message: str
    service: str | None = None
    template: str | None = None
    attributes: Mapping[str, Any] = field(default_factory=dict)
    trace_id: str | None = None
    request_id: str | None = None
    depends_on: tuple[str, ...] = ()
    evidence_ref: str | None = None

def validate_event(payload: Mapping[str, Any]) -> Event:
    """Validate against the JSON Schema, then construct the typed model.
    Failures raise a structured error with a JSON-path-style location."""
```

The typed model is a **convenience**; the JSON Schema is the **authority**. A contract test asserts equivalence: every valid fixture constructs a model, and every model serializes back to a schema-valid payload.

### 5.2 State the contracts imply

| Concept | Contract implication |
|---|---|
| Idempotency | `event_id` is the key; storage must enforce uniqueness (dedupe table/unique constraint) |
| Ordering | `event_ts` (source) vs `observed_ts` (us) — both stored; windows use one **documented** choice (recommend `event_ts` for semantics, `observed_ts` for ingestion-lag signals) |
| Lifecycle | `status` transitions are part of the incident contract; audit entries are appended, not overwritten |
| Uncertainty | `hypotheses[].confidence` and `missing_evidence` are first-class — the schema makes honesty easy |
| Non-execution | `diagnostic_checks[].executes: false` is structural |

### 5.3 Pagination & filtering (incident list)

- **Cursor-based** pagination (`next_cursor`), opaque to clients.
- Filters: `status`, `severity`, `time_from`, `time_to`, `host`.
- Document default page size and max page size in OpenAPI.
- Never expose `scan`-like semantics; every filter maps to a documented query.

---

## 6. Security, Testing, and Deployment Considerations (contracts track)

### 6.1 Security encoded in the contract

- 🔐 **Authentication boundaries:** collectors submit events **only**; administrators read incidents and change lifecycle state. **Authorization is enforced server-side**, not just hidden in the UI. (Tests: collector token → `403` on any `/incidents` path; no token → `401` on ingestion.)
- 🔐 **Error messages never leak secrets or internal configuration** (no ARNs, no env dumps, no stack traces in `message`).
- 🔐 **`request_id` correlation** supports auditing without exposing payload contents.
- 🔐 **Size limits in the contract** (`413`) are a DoS control, not just hygiene.
- 🔐 **Message text is untrusted data** — the contract marks it as display-only; downstream must escape it (XSS test required).
- 🔐 **Redaction upstream** means the contract never *requires* raw sensitive values; `evidence_ref` is a pointer to **redacted** evidence.

### 6.2 Contract testing (the enforcement layer)

```python
# tests/contract/test_event_fixtures.py (illustrative)
import json, glob, jsonschema, pathlib

SCHEMA = json.loads(pathlib.Path("contracts/schemas/event.schema.json").read_text())

def test_all_valid_fixtures_pass():
    for path in glob.glob("contracts/fixtures/valid/*.json"):
        with open(path) as f:
            payload = json.load(f)
        jsonschema.validate(payload, SCHEMA)          # raises on failure

def test_all_invalid_fixtures_fail_with_expected_reason():
    for path in glob.glob("contracts/fixtures/invalid/*.json"):
        meta = json.loads(pathlib.Path(path + ".meta.json").read_text())  # expected reason
        with open(path) as f:
            payload = json.load(f)
        with pytest.raises(jsonschema.ValidationError) as exc:
            jsonschema.validate(payload, SCHEMA)
        assert meta["expected_reason"] in str(exc.value)
```

**Fixture matrix (build these first):**

| Fixture | Proves |
|---|---|
| `valid/http_5xx.json` | rich HTTP event with trace id |
| `valid/journald_minimal.json` | envelope satisfiable **without** HTTP/DB fields |
| `valid/windows_event.json` | Windows metadata preserved |
| `valid/unknown_optional_field.json` | compatibility policy for unknown optionals |
| `invalid/naive_timestamp.json` | timezone-aware rule |
| `invalid/missing_event_id.json` | stable ID required |
| `invalid/unknown_required_field.json` | reject unknown required |
| `invalid/bad_severity.json` | enum enforcement |
| `invalid/oversized_field.json` | field/payload limits |

Plus OpenAPI validation of every **response** example, and a schema-drift check that regenerating client types produces no uncommitted diff.

### 6.3 Deployment considerations

- Contract validation runs in **CI on every PR** (fast, no cloud needed).
- Contract tests also run in the **integration smoke** path so drift between local and deployed behavior is caught.
- When deploying a contract change: **roll out collectors and API in a compatible order.** E.g., add an optional field → deploy API first (accepts unknown optionals) → then collectors. Remove/rename → major version + coordinated rollout.
- The deployed `/health` must stay contract-valid **and** leak nothing.

### 6.4 Compatibility in practice — a worked example

**Adding an optional field `geo_region` to the event envelope:**

1. PR #1: add `geo_region` to `event.schema.json` (optional), add `valid/with_geo_region.json` + update OpenAPI docs, update typed model, update contract tests, update this guide. **All in one PR.** Old collectors keep working (they simply omit it).
2. Deploy the API/worker (which now accept and preserve it).
3. PR #2 (later): collectors start populating `geo_region`.
4. Only once collectors are emitting it does the detection track consider it a feature (and only if documented — no accidental features).

**Removing/renaming a field:** major `schema_version` bump, both versions supported for a documented window, fixture updates for both, and an explicit collector-upgrade note in the decision log.

---

## 7. Definition of Done (contracts track)

- [ ] The four canonical files are the **only** definitions; no conflicting duplicates anywhere (grep-enforced in review).
- [ ] Every envelope rule (§4.1) has at least one passing fixture-backed test.
- [ ] Incident contract separates observations/hypotheses/recommendations; `"Unknown"` and `executes: false` are structurally supported and tested.
- [ ] All six endpoints are in `openapi.yaml` with shapes, auth, pagination, filters, limits, and status codes — and **nothing undocumented is implemented**.
- [ ] Receipt semantics (`accepted`/`rejected`, accepted ≠ analyzed) are tested.
- [ ] Authz boundaries tested: collector → `403` on incidents; no credential → `401` on ingestion.
- [ ] Compatibility policy decided (ADR), documented, and fixture-tested.
- [ ] CI enforces: schema validation, OpenAPI validation, fixture matrix, response-example validation, (optional) client-type regeneration diff.
- [ ] A contract change cannot merge with fewer than the five artifacts (schema, fixtures, models, tests, docs) updated together.

---

*End of Phase 2.* → Awaiting confirmation before Phase 3 (the seven learning modules).

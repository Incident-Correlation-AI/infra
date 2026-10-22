# 📚 Learning Module 2 — Contracts & Validation: JSON Schema, OpenAPI, FastAPI, Pydantic

> **Module goal:** Learn to turn "we agreed on this shape" into *executable, testable truth* — the discipline that lets four teams build in parallel without breaking each other.
> **Project tie-in:** You will author `contracts/schemas/*.json`, `contracts/openapi.yaml`, and the ingestion/incident API, and prove it all with contract tests.

**Estimated study time:** 25–35 hours. **Prereq:** Module 1 (typed models, `Result`, boundaries).

---

## Table of Contents

1. [Core Theory & In-Depth Explanation](#1-core-theory--in-depth-explanation)
   - 1.1 The "contract" idea and why distributed systems need it
   - 1.2 JSON Schema: the vocabulary of shape
   - 1.3 OpenAPI: describing a whole HTTP API
   - 1.4 Pydantic & FastAPI: annotations as executable contracts
   - 1.5 The schema boundary: validate once, trust typed objects
   - 1.6 Versioning, evolution, and the compatibility policy
   - 1.7 Errors as a first-class contract
   - 1.8 Idempotency, receipts, and asynchronous semantics
2. [Practical Examples & Code Walkthroughs](#2-practical-examples--code-walkthroughs)
3. [Common Pitfalls & Debugging](#3-common-pitfalls--debugging)
4. [Curated Resources](#4-curated-resources)

---

## 1. Core Theory & In-Depth Explanation

### 1.1 The "contract" idea

Two components integrate safely when each can rely on a **fixed set of guarantees** about the other: what fields exist, their types, which are optional, what errors mean, and how versions evolve. That guarantee set is a **contract**.

Without a contract, integration is by folklore: someone reads the producer's code, writes a consumer, and it "works." Then the producer adds a field, or renames one, or changes a `string` to a `number`, and the consumer breaks in production. Contracts convert folklore into **artifacts a machine can check** — JSON Schema files, an OpenAPI document, fixtures, and tests.

Three properties matter for this project:

- **Parallelism.** Collectors, detector, cloud, and frontend build against fixtures simultaneously. No one waits for "the real API" to exist.
- **Safety at boundaries.** Attack surface lives at boundaries. Schema validation, size limits, and explicit errors are the boundary's immune system.
- **Evolvability.** With `schema_version` and an explicit unknown-field policy, a new collector can ship without breaking an old API, and vice versa.

#### Historical context

- **XML/SOAP** (late 1990s–2000s) pushed schema-first design hard (XSD), but with heavy ceremony.
- **REST + JSON** (2005–2012) traded rigor for speed. JSON had no schema for years; "documentation" was prose (or a wiki page that rotted).
- **JSON Schema** (drafts from ~2010, standardized, ongoing spec work) gave JSON a formal validation vocabulary.
- **Swagger → OpenAPI** (2010 → 2015 OpenAPI Initiative) standardized HTTP API description.
- **Pydantic + FastAPI** (2018–2019) made annotations *executable*: one type declaration generated validation, docs, and OpenAPI.

The arc bends toward **one description, many uses**. That is exactly the discipline this project enforces: define once in `contracts/`, generate/validate everywhere.

### 1.2 JSON Schema: the vocabulary of shape

A JSON Schema is itself JSON describing valid instances. You will use these keywords constantly:

| Keyword | Meaning | Project use |
|---|---|---|
| `type` | data type (`object`,`string`,`number`,`integer`,`boolean`,`array`,`null`) | core shapes |
| `properties` | named members of an object | envelope fields |
| `required` | which properties must be present | `event_id`, timestamps |
| `additionalProperties` | policy for unknown members (`true`/`false`/schema) | the unknown-field compatibility policy |
| `enum` | finite allowed values | `severity`, `status` |
| `format` | semantic hint (`date-time`, `uuid`, `uri`) | timestamps, IDs |
| `pattern` | regex on strings | ID formats |
| `maxLength`, `maximum`, `maxItems` | size bounds | **payload limits** (security) |
| `minItems`, `maxItems` | array bounds | batch size limits |
| `allOf`/`anyOf`/`oneOf`/`not` | composition | conditional shapes |
| `$ref` + `$defs` | reuse & recursion | shared definitions |
| `if`/`then`/`else` | conditional validation | "if source=app-nginx then attributes.status required" |

**A schema is not a class.** It describes *instances*, so the same schema can validate a Python dict, a TypeScript object, or bytes from a queue. That universality is why the canonical contract lives in JSON, not in Python.

#### A worked schema fragment

```jsonc
// contracts/schemas/event.schema.json (excerpt)
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://example.org/lad/event.schema.json",
  "title": "Log Event Envelope",
  "type": "object",
  "additionalProperties": true,              // policy: accept & preserve unknown optionals
  "required": [
    "schema_version", "event_id", "event_ts", "observed_ts",
    "host", "source", "category", "type", "severity", "message"
  ],
  "properties": {
    "schema_version": { "type": "string", "enum": ["1.0"] },
    "event_id":       { "type": "string", "minLength": 8, "maxLength": 128 },
    "event_ts":       { "type": "string", "format": "date-time" },
    "observed_ts":    { "type": "string", "format": "date-time" },
    "host":           { "type": "string", "minLength": 1, "maxLength": 255 },
    "source":         { "type": "string", "minLength": 1, "maxLength": 64 },
    "service":        { "type": ["string", "null"], "maxLength": 128 },
    "category":       { "type": "string", "minLength": 1, "maxLength": 64 },
    "type":           { "type": "string", "minLength": 1, "maxLength": 64 },
    "severity":       { "type": "string", "enum": ["info", "warning", "error", "critical"] },
    "message":        { "type": "string", "maxLength": 8192 },
    "template":       { "type": ["string", "null"], "maxLength": 2048 },
    "attributes":     { "type": "object" },
    "trace_id":       { "type": ["string", "null"], "maxLength": 128 },
    "request_id":     { "type": ["string", "null"], "maxLength": 128 },
    "depends_on":     { "type": "array", "items": { "type": "string", "maxLength": 128 }, "maxItems": 32 },
    "evidence_ref":   { "type": ["string", "null"], "maxLength": 512 }
  }
}
```

**Reading the design decisions:**
- `additionalProperties: true` encodes the compatibility policy: **newer collectors may add optional fields; the API accepts and preserves them** (and detection must not use them unless documented — accidental features are leakage).
- `format: "date-time"` is only a *hint*; many validators don't enforce it strongly. **Timezone-aware** enforcement needs either a `pattern` with an offset or an application-level check (we do both). This is a classic JSON Schema subtlety.
- `"type": ["string", "null"]` makes optionality explicit. Prefer this over simply omitting the key so that "present but null" and "absent" are distinguishable — and never conflate either with `0`.
- `maxLength`/`maxItems` are **security controls** (payload limits), not cosmetics.

> ⚠️ **OpenAPI 3.0 vs. JSON Schema draft differences.** OpenAPI 3.0 uses a *subset* of JSON Schema draft-04 with tweaks (`nullable: true` instead of `type: ["string","null"]`). OpenAPI 3.1 aligns with JSON Schema 2020-12. **Pick one version for `openapi.yaml`, document it, and don't mix `nullable` and `["x","null"]` styles.** Mismatches here cause confusing validator disagreements.

#### `$ref` and reuse

```jsonc
{
  "$defs": {
    "timestamp": { "type": "string", "format": "date-time" },
    "severity":  { "type": "string", "enum": ["info","warning","error","critical"] }
  },
  "properties": {
    "event_ts":    { "$ref": "#/$defs/timestamp" },
    "observed_ts": { "$ref": "#/$defs/timestamp" },
    "severity":    { "$ref": "#/$defs/severity" }
  }
}
```

Reuse keeps `event.schema.json` and `incident.schema.json` consistent (both cite the same `severity`) and makes a change a one-line edit.

### 1.3 OpenAPI: describing a whole HTTP API

JSON Schema describes *data*. **OpenAPI** describes an *API*: paths, methods, parameters, request/response bodies (referencing JSON Schemas), status codes, auth schemes, and error shapes. It is the machine-readable spec that clients generate from, servers validate against, and docs render.

**Minimal skeleton (OpenAPI 3.0-style):**

```yaml
openapi: 3.0.3
info:
  title: Log Anomaly Detector API
  version: "1.0.0"
servers:
  - url: http://localhost:8080
  - url: https://{apiId}.execute-api.{region}.amazonaws.com
components:
  securitySchemes:
    CollectorToken:
      type: http
      scheme: bearer
    AdminSession:
      type: apiKey
      in: cookie
      name: lad_session
  schemas:
    Error:
      $ref: './schemas/api-errors.schema.json#/$defs/error'
    Event:
      $ref: './schemas/event.schema.json'
    Incident:
      $ref: './schemas/incident.schema.json'
    BatchReceipt:
      type: object
      required: [receipt_id, accepted, rejected, results, note]
      properties:
        receipt_id: { type: string }
        accepted:   { type: integer, minimum: 0 }
        rejected:   { type: integer, minimum: 0 }
        note:       { type: string }
        results:
          type: array
          items:
            type: object
            required: [index, status]
            properties:
              index:    { type: integer, minimum: 0 }
              event_id: { type: ["string","null"] }
              status:   { type: string, enum: [accepted, rejected] }
              reason:   { type: ["string","null"] }
              detail:   { type: ["string","null"] }
paths:
  /api/v1/health:
    get:
      summary: Health check (no secrets)
      responses:
        "200": { description: ok }
  /api/v1/events/batch:
    post:
      summary: Ingest a batch of events
      security: [{ CollectorToken: [] }]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [events]
              properties:
                events:
                  type: array
                  minItems: 1
                  maxItems: 100
                  items: { $ref: '#/components/schemas/Event' }
      responses:
        "202": { description: Accepted into queue }
        "401": { description: Unauthenticated }
        "413": { description: Payload too large }
        "422": { description: Validation failed }
  /api/v1/incidents:
    get:
      summary: List incidents (admin)
      security: [{ AdminSession: [] }]
      parameters:
        - { name: status, in: query, schema: { type: string, enum: [open, acknowledged, resolved] } }
        - { name: severity, in: query, schema: { type: string, enum: [low, medium, high, critical] } }
        - { name: cursor, in: query, schema: { type: string } }
        - { name: limit, in: query, schema: { type: integer, minimum: 1, maximum: 100, default: 25 } }
      responses:
        "200": { description: Page of incidents }
        "403": { description: Collector tokens cannot read incidents }
  /api/v1/incidents/{incident_id}:
    get:
      security: [{ AdminSession: [] }]
      parameters:
        - { name: incident_id, in: path, required: true, schema: { type: string } }
      responses:
        "200": { description: Incident }
        "404": { description: Not found }
  /api/v1/incidents/{incident_id}/acknowledge:
    post:
      security: [{ AdminSession: [] }]
      parameters:
        - { name: incident_id, in: path, required: true, schema: { type: string } }
      responses:
        "200": { description: Acknowledged }
  /api/v1/incidents/{incident_id}/resolve:
    post:
      security: [{ AdminSession: [] }]
      parameters:
        - { name: incident_id, in: path, required: true, schema: { type: string } }
      responses:
        "200": { description: Resolved }
```

**What OpenAPI buys us here:**
- **Client generation.** The dashboard can generate TypeScript types from this file (see Module 7), so a contract drift becomes a *compile error*, not a blank screen.
- **Server validation.** Requests/responses can be validated against it in tests.
- **Docs.** Swagger UI/Redoc can render it for the team.
- **Explicit auth per route.** `CollectorToken` vs `AdminSession` is declared here, making the collector/admin boundary visible at the API-description level.

**"Do not implement undocumented behavior."** If a route, field, or status code isn't in the OpenAPI file, it doesn't exist. This rule forces the spec to be updated *first*, which is what keeps it truthful.

### 1.4 Pydantic & FastAPI: annotations as executable contracts

**Pydantic** validates Python objects at runtime from type annotations. **FastAPI** uses pydantic for request/response validation and *derives* OpenAPI from the same models. This is the "one description, many uses" payoff.

```python
# services/api/models.py
from datetime import datetime
from typing import Any, Literal
from pydantic import BaseModel, Field, field_validator

Severity = Literal["info", "warning", "error", "critical"]

class EventIn(BaseModel):
    schema_version: str
    event_id: str = Field(min_length=8, max_length=128)
    event_ts: datetime
    observed_ts: datetime
    host: str = Field(min_length=1, max_length=255)
    source: str = Field(min_length=1, max_length=64)
    service: str | None = None
    category: str = Field(min_length=1, max_length=64)
    type: str = Field(min_length=1, max_length=64)
    severity: Severity
    message: str = Field(max_length=8192)
    template: str | None = None
    attributes: dict[str, Any] = Field(default_factory=dict)
    trace_id: str | None = None
    request_id: str | None = None
    depends_on: list[str] = Field(default_factory=list, max_items=32)
    evidence_ref: str | None = None

    @field_validator("event_ts", "observed_ts")
    @classmethod
    def must_be_tz_aware(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            raise ValueError("timestamp must be timezone-aware")
        return v

class BatchIn(BaseModel):
    events: list[EventIn] = Field(min_length=1, max_length=100)
```

```python
# services/api/main.py
from fastapi import FastAPI, Request, status
from fastapi.responses import JSONResponse
from .models import BatchIn
from .auth import require_collector, require_admin

app = FastAPI(title="Log Anomaly Detector API", version="1.0.0")

@app.get("/api/v1/health")
def health():
    return {"status": "ok", "version": "0.3.0"}     # no ARNs, no env dumps

@app.post("/api/v1/events/batch", status_code=status.HTTP_202_ACCEPTED)
def ingest(batch: BatchIn, request: Request, collector=require_collector(request)):
    # NOTE: validation above means the whole batch is schema-valid.
    # For *partial* acceptance we validate per-event instead (see §2.4).
    accepted, rejected, results = queue_and_receipt(batch.events, collector)
    return {"receipt_id": new_receipt_id(), "accepted": accepted,
            "rejected": rejected, "results": results,
            "note": "Accepted events are queued; detection may not have completed."}

@app.get("/api/v1/incidents")
def list_incidents(request: Request, status: str | None = None,
                   cursor: str | None = None, limit: int = 25):
    require_admin(request)
    return incident_store.page(status=status, cursor=cursor, limit=limit)
```

**Key ideas:**
- `@field_validator` extends annotation-based checks with custom logic — how we enforce tz-awareness that JSON Schema only hints at.
- FastAPI turns `BatchIn` into request validation **and** into OpenAPI docs, automatically. The spec and the code cannot drift if you generate the spec from the models — but our project keeps `openapi.yaml` **hand-authored and canonical**, so a CI check must confirm the generated spec is a **subset/compatible** with the canonical one. (Record this decision in an ADR: "canonical OpenAPI hand-authored; generated spec used to detect drift.")

> ⚠️ **Decision point:** There are two valid philosophies: (a) **code-first** — generate OpenAPI from FastAPI models and treat it as canonical; (b) **spec-first** — hand-author `openapi.yaml` and validate code against it. This project's baseline files live in `contracts/`, implying **spec-first** canon. Choose explicitly, or you'll have two sources of truth (the exact thing the baseline warns against: "do not maintain conflicting duplicate field definitions").

### 1.5 The schema boundary: validate once, trust typed objects

**Validate at the boundary; trust inside.** Validation has a cost, and re-validating at every layer hides bugs (if every layer validates, you never learn which layer violated the contract). The pattern:

```
bytes ──(schema/pydantic)──► typed object ──► core pipeline (trusts types)
   ▲                                                │
   └──────────── reject with structured reason ◄────┘
```

Exceptions to "trust inside":
- **Returning data to the outside** (responses) — validate/serialize explicitly so you don't leak internal fields.
- **Defense in depth at trust boundaries** — the worker re-validates events from the queue because the queue can carry stale or hand-crafted messages. That's a *boundary*, not an internal layer.

### 1.6 Versioning, evolution, and the compatibility policy

`schema_version` on every envelope. The API supports a documented set and rejects others. The **compatibility policy** must be an explicit ADR, tested with fixtures:

| Change | Rule | Rollout order |
|---|---|---|
| Add **optional** field | allowed within a version | deploy API/worker first, collectors second |
| Add **required** field | new `schema_version` | coordinated rollout |
| Rename/remove field | new `schema_version` | support both versions for a window |
| Add **enum** value | currently **reject** unknown enums | coordinate consciously |
| Widen a type (`int`→`number`) | allowed if consumers can handle | document |

**Why reject unknown enums?** Silently accepting a new `severity` value means downstream severity rules silently mis-classify it. Rejecting forces a conscious decision.

**Worked example (recap from the API guide):** adding `geo_region` optional → schema + fixtures + models + tests + docs in one PR → deploy API → deploy collectors → *then* consider it a feature (if documented).

### 1.7 Errors as a first-class contract

A shared error schema (`api-errors.schema.json`) means every client handles failures uniformly:

```jsonc
{
  "$defs": {
    "error": {
      "type": "object",
      "required": ["code", "message"],
      "properties": {
        "code":    { "type": "string" },
        "message": { "type": "string", "maxLength": 512 },
        "details": { "type": "array", "items": { "type": "object" } },
        "request_id": { "type": "string" }
      },
      "additionalProperties": false
    }
  }
}
```

**Rules:**
- `code` is **machine-readable and stable** (`validation_failed`, `unauthenticated`, `forbidden`, `not_found`, `payload_too_large`, `throttled`, `dependency_unavailable`).
- `message` is **safe to log and show** — never a stack trace, never an ARN, never a secret.
- `details` is structured and per-item (e.g., per-event rejection reasons for a partial batch).
- `request_id` correlates a client error to a server log line **without** exposing payloads.
- **Retryable vs. non-retryable** is part of the contract: `408/429/5xx` retryable; other `4xx` not.

### 1.8 Idempotency, receipts, and asynchronous semantics

The ingestion contract encodes three subtle truths:

1. **Accepted ≠ analyzed.** The `202` receipt reflects *queue acceptance only*. The `note` field states this explicitly, and the UI must not imply an incident exists yet.
2. **Partial acceptance is allowed.** Per-index results let one bad event be rejected without poisoning 99 good ones, and make collector retry logic trivial.
3. **Duplicates are expected.** Stable `event_id` is the idempotency key. Duplicate IDs must not create duplicate incidents — enforced at ingestion (dedup) and again in the worker (idempotent upsert).

```python
# a receipt builder that makes partial acceptance legible
def build_receipt(results: list[dict], note: str) -> dict:
    accepted = sum(1 for r in results if r["status"] == "accepted")
    rejected = len(results) - accepted
    return {"receipt_id": new_receipt_id(), "accepted": accepted,
            "rejected": rejected, "results": results, "note": note}
```

---

## 2. Practical Examples & Code Walkthroughs

### 2.1 Writing an incident schema with honest semantics

```jsonc
// contracts/schemas/incident.schema.json (excerpt)
{
  "$id": "https://example.org/lad/incident.schema.json",
  "type": "object",
  "required": ["incident_id","schema_version","status","severity","anomaly_score",
               "detector","hypotheses","evidence","diagnostic_checks","audit"],
  "properties": {
    "incident_id":   { "type": "string", "minLength": 8 },
    "schema_version":{ "type": "string", "enum": ["1.0"] },
    "status":        { "type": "string", "enum": ["open","acknowledged","resolved"] },
    "severity":      { "type": "string", "enum": ["low","medium","high","critical"] },
    "anomaly_score": { "type": "number" },          // NOT a probability — no [0,1] claim
    "detector":      { "type": "string" },
    "model_versions":{ "type": "object", "additionalProperties": { "type": "string" } },
    "affected_entities": {
      "type": "array",
      "items": { "type": "object",
        "required": ["host"],
        "properties": { "host": {"type":"string"}, "service": {"type":["string","null"]},
                        "source": {"type":["string","null"]} } }
    },
    "evidence": {
      "type": "object",
      "required": ["supporting_event_ids","contradicting_event_ids"],
      "properties": {
        "supporting_event_ids":     { "type": "array", "items": {"type":"string"} },
        "contradicting_event_ids":  { "type": "array", "items": {"type":"string"} },
        "redacted_refs":            { "type": "array", "items": {"type":"string"} }
      }
    },
    "hypotheses": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["statement","confidence","supporting_event_ids","contradicting_event_ids","missing_evidence"],
        "properties": {
          "statement":  { "type": "string", "maxLength": 1024 },   // "Unknown" is valid
          "confidence": { "type": "string", "enum": ["low","medium","high"] },
          "supporting_event_ids":   { "type": "array", "items": {"type":"string"} },
          "contradicting_event_ids":{ "type": "array", "items": {"type":"string"} },
          "missing_evidence":       { "type": "array", "items": {"type":"string"} }
        }
      }
    },
    "diagnostic_checks": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["instruction","executes"],
        "properties": {
          "instruction":  { "type": "string", "maxLength": 1024 },
          "evidence_links": { "type": "array", "items": {"type":"string"} },
          "executes": { "type": "boolean", "const": false }        // structurally non-executing
        }
      }
    },
    "audit": { "type": "array", "items": { "type": "object" } }
  }
}
```

**Semantics encoded in shape:**
- `anomaly_score` has **no `minimum`/`maximum`**, deliberately — we make **no** claim it's a probability. (Adding `minimum: 0, maximum: 1` would *assert* that meaning.)
- `"const": false` on `executes` makes it impossible to express an auto-executing check.
- `contradicting_event_ids` is **required** (can be empty) so a hypothesis always states whether it considered counter-evidence.

### 2.2 Per-event partial acceptance (endpoint that actually does it)

```python
# services/api/ingest.py
from fastapi import APIRouter, Request, status
from pydantic import ValidationError
from .models import EventIn
from lad.contracts import to_core_event

router = APIRouter()

@router.post("/api/v1/events/batch", status_code=status.HTTP_202_ACCEPTED)
async def ingest_batch(request: Request):
    require_collector(request)
    raw = await request.json()
    if not isinstance(raw, dict) or "events" not in raw or not isinstance(raw["events"], list):
        raise ApiError.code("bad_request", "body must be {events: [...]}")
    batch = raw["events"]
    if len(batch) == 0:
        raise ApiError.code("validation_failed", "events must be non-empty")
    if len(batch) > 100:
        raise ApiError.code("payload_too_large", "at most 100 events per batch")

    results, accepted_events = [], []
    for i, item in enumerate(batch):
        try:
            ev = EventIn.model_validate(item)              # per-event validation
            accepted_events.append(to_core_event(ev))
            results.append({"index": i, "event_id": ev.event_id, "status": "accepted"})
        except ValidationError as e:
            first = e.errors()[0]
            field = ".".join(str(p) for p in first["loc"])
            results.append({"index": i, "event_id": None, "status": "rejected",
                            "reason": "validation_failed",
                            "detail": f"{field}: {first['msg']}"})

    # enqueue accepted events; dedupe on stable id
    accepted_events = dedupe_by_event_id(accepted_events)
    await queue.send_batch(accepted_events)

    accepted = sum(1 for r in results if r["status"] == "accepted")
    return {**build_receipt(results, "Accepted events are queued; detection may not have completed."),
            "accepted": accepted, "rejected": len(results) - accepted}
```

**Walkthrough:**
- We read the raw body to retain **index positions** for per-event reporting. Validating the whole batch as one model would either accept all or reject all, breaking partial acceptance.
- `model_validate` per item gives us the exact `loc` (field path) for a helpful `detail`.
- `dedupe_by_event_id` collapses duplicate IDs **within** a batch (collectors can be buggy) — one more layer before the durable dedup store.

### 2.3 Contract tests: enforcing the fixtures matrix

```python
# tests/contract/test_event_contract.py
import json, glob, pathlib
import jsonschema
import pytest

SCHEMA = json.loads(pathlib.Path("contracts/schemas/event.schema.json").read_text())
VALID = glob.glob("contracts/fixtures/valid/*.json")
INVALID = glob.glob("contracts/fixtures/invalid/*.json")

@pytest.mark.parametrize("path", VALID, ids=lambda p: pathlib.Path(p).name)
def test_valid_fixtures_pass(path):
    payload = json.loads(pathlib.Path(path).read_text())
    jsonschema.validate(payload, SCHEMA)      # raises jsonschema.ValidationError

@pytest.mark.parametrize("path", INVALID, ids=lambda p: pathlib.Path(p).name)
def test_invalid_fixtures_fail_with_reason(path):
    payload = json.loads(pathlib.Path(path).read_text())
    meta = json.loads(pathlib.Path(path + ".meta.json").read_text())
    with pytest.raises(jsonschema.ValidationError) as exc:
        jsonschema.validate(payload, SCHEMA)
    assert meta["expected_reason"] in str(exc.value)

def test_roundtrip_typed_model():
    from lad.contracts import Event
    for path in VALID:
        payload = json.loads(pathlib.Path(path).read_text())
        ev = Event.from_json(payload)
        jsonschema.validate(ev.to_json(), SCHEMA)     # model serialization stays valid
```

**Walkthrough:** parametrizing over the fixture directory means adding a fixture automatically adds a test case. The `.meta.json` sidecar documents the *expected* failure reason, turning "it failed" into "it failed for the right reason." The roundtrip test is what keeps the typed model and the schema from diverging.

### 2.4 OpenAPI validation in CI

```python
# tests/contract/test_openapi.py
from openapi_spec_validator import validate
import yaml, pathlib

def test_openapi_is_valid():
    spec = yaml.safe_load(pathlib.Path("contracts/openapi.yaml").read_text())
    validate(spec)

def test_every_response_references_error_schema_for_4xx():
    spec = yaml.safe_load(pathlib.Path("contracts/openapi.yaml").read_text())
    for path, methods in spec["paths"].items():
        for method, op in methods.items():
            for code, resp in op.get("responses", {}).items():
                if str(code).startswith("4") or str(code).startswith("5"):
                    # every error response must reference the shared Error schema
                    content = resp.get("content", {}).get("application/json", {})
                    assert "schema" in content, f"{method.upper()} {path} {code} lacks error schema"
```

**Walkthrough:** the second test is a *policy* test — it encodes the rule "errors are uniform" as an assertion, so a new endpoint can't quietly return a bespoke error shape.

### 2.5 Drift check: canonical spec vs. generated spec

```bash
# in CI: fail if the framework-generated spec diverges from the canonical hand-authored one
python scripts/export_openapi.py > /tmp/generated.json
python scripts/compare_openapi.py contracts/openapi.yaml /tmp/generated.json
```

```python
# scripts/compare_openapi.py (illustrative: check generated ⊆ canonical for paths/methods/fields)
import json, sys, yaml

def main(canonical_path, generated_path):
    canonical = yaml.safe_load(open(canonical_path))
    generated = json.load(open(generated_path))
    problems = []
    for path, methods in generated.get("paths", {}).items():
        if path not in canonical.get("paths", {}):
            problems.append(f"generated path not in canonical: {path}")
        else:
            for method in methods:
                if method not in canonical["paths"][path]:
                    problems.append(f"generated method not in canonical: {method} {path}")
    if problems:
        print("\n".join(problems)); sys.exit(1)
    print("openapi drift check: OK")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
```

**Walkthrough:** this resolves the code-first/spec-first tension pragmatically — the canonical file remains authoritative, and CI proves the implementation didn't wander off. If the team later decides generated-is-canonical, this script flips direction. Either way, **the drift is detected mechanically**.

### 2.6 Idempotency test at the contract level

```python
def test_duplicate_event_ids_do_not_duplicate_incidents(client, pipeline, store):
    ev = make_event(event_id="evt_dup", category="db", type="db_timeout",
                    attributes={"duration_ms": 5000})
    r1 = client.post("/api/v1/events/batch", json={"events": [ev.to_json()]}, headers=collector_hdr())
    r2 = client.post("/api/v1/events/batch", json={"events": [ev.to_json()]}, headers=collector_hdr())
    assert r1.status_code == r2.status_code == 202
    run_worker_once(pipeline, store)                     # process the queue
    incidents = store.list_incidents()
    related = [i for i in incidents if "evt_dup" in i.evidence.supporting_event_ids]
    assert len(related) <= 1, "duplicate submission created duplicate incidents"
```

**Walkthrough:** the test exercises the **whole boundary** — HTTP, dedupe, queue, worker, store — not just a unit. It's exactly the acceptance gate "duplicate submissions do not duplicate incidents."

---

## 3. Common Pitfalls & Debugging

### 3.1 The "null vs zero vs missing" trap

The most dangerous data bug in this domain. A schema that permits `"duration_ms": null` and a consumer that does `duration = event.attributes.get("duration_ms", 0)` fabricates a zero. **Fix:** never use `get(k, 0)` for metrics; represent missing as absent/`None`, and let the feature layer skip it. Test it: a fixture with no `duration_ms` must yield **no latency feature**.

### 3.2 `format: date-time` is not enforced by every validator

Many JSON Schema validators treat `format` as an annotation. A string `"not-a-date"` may pass `type: string`. **Fix:** add a `pattern` for a timezone offset *and* a pydantic `field_validator`. Redundant checks at the boundary are fine; relying on one silent hint is not.

### 3.3 OpenAPI `nullable` vs. JSON Schema unions

Mixing `nullable: true` (OpenAPI 3.0) with `type: ["string","null"]` (JSON Schema) makes validators disagree. **Fix:** pick one style, document it, and lint for the other.

### 3.4 Validating in too many places

If the API, the worker, *and* the core all validate, you lose track of where a bad value originated and pay triple cost. **Fix:** validate at boundaries (API ingress, queue boundary, response egress); trust inside.

### 3.5 Silent truncation instead of rejection

Truncating an over-long `message` at the collector hides the fact that the event was larger than the contract allows. **Fix:** enforce limits and **reject** (or record a truncation flag + metric) — never silent shrink. Silent shrink is a data-integrity bug.

### 3.6 The receipt that lies

`"accepted": 100` when 98 were actually queued (2 failed dedup or SQS chunking) erodes trust. **Fix:** derive `accepted` from the *actual enqueue result*, not the *validated count*, and test the discrepancy path (e.g., a batch exceeding SQS message size must be chunked; the receipt still tells the truth).

### 3.7 Error `code` churn

If `code` strings drift (`validation_failed` → `validation-error` → `invalid`), clients can't handle them. **Fix:** treat `code` as an enum in the error schema and test that every thrown code is in the set.

### 3.8 CORS surprises

If the dashboard gets opaque network errors, the API CORS config likely lacks the origin. **Fix:** verify `AllowOrigins` against the *actual* dashboard origin in local **and** AWS modes; never `*` with credentials.

### 3.9 Debugging toolkit

```bash
# validate a single payload quickly
python -c "import json,jsonschema,sys; jsonschema.validate(json.load(open(sys.argv[1])), json.load(open('contracts/schemas/event.schema.json'))); print('ok')" payload.json

# pretty-print the generated OpenAPI and diff against canonical
python scripts/export_openapi.py | jq . > gen.json && diff <(yq . contracts/openapi.yaml) gen.json

# inspect the validator's exact failure path
python -c "import json,jsonschema; jsonschema.validate(json.load(open('bad.json')), json.load(open('contracts/schemas/event.schema.json')))" 2>&1 | tail -5
```

- **`jsonschema.ValidationError`** exposes `.absolute_path` and `.message` — use them to build the per-event `detail` string.
- **`openapi-spec-validator`** gives line-ish errors for malformed specs; run it in pre-commit so spec errors never reach CI.
- **`pytest --pdb`** on a failing contract test lets you inspect the offending payload interactively.

---

## 4. Curated Resources

### 4.1 Books (with chapter guidance)

- **"Implementing Service Level Objectives" — Alex Hidalgo.** Not about schemas directly, but Ch. on *measurement* and *error budgets* frames *why* contracts and truthful receipts matter operationally.
- **"Designing Data-Intensive Applications" — Martin Kleppmann.**
  - Ch. 4 *Encoding and Evolution* — the definitive treatment of schema evolution, backward/forward compatibility, and why explicit versions matter. Read this for §1.6.
  - Ch. 11 *Stream Processing* — idempotency, exactly-once illusion, and at-least-once semantics (§1.8).
- **"Building Microservices" (2nd ed.) — Sam Newman.**
  - Ch. on *Contracts and versioning* and *Consumer-driven contracts* — the philosophy behind the fixtures matrix.
- **"API Design Patterns" — JJ Geewax.**
  - Ch. on *Idempotency*, *Pagination* (cursor style), and *Standard errors* — maps to §1.7/§1.8.
- **"The Design of Web APIs" — Arnaud Lauret.** Practical OpenAPI authoring patterns.

### 4.2 Videos, talks, courses

- **"Designing Quality APIs" — Google Cloud Tech (YouTube series).** Excellent on errors, pagination, and versioning.
- **FastAPI official *Tutorial — Advanced User Guide*** (pydantic validators, dependency injection): read the sections on `field_validator`, `Field`, and response models.
- **"JSON Schema — The Basics" (json-schema.org *Learn* site)** and the *Understanding JSON Schema* guide (free e-book).
- **"OpenAPI 3.0/3.1 — What changed and why" (OpenAPI Initiative talks on YouTube).**
- **"Stop Writing Your OpenAPI By Hand"** and counterpoint talks on the webpage-spec-first debate — pick a side *deliberately* (§1.4).

### 4.3 Exercises to internalize this module

1. Author `event.schema.json` from scratch and add five valid + five invalid fixtures with `.meta.json` expected reasons.
2. Write a `field_validator` that rejects naive timestamps; prove it with a parametrized test.
3. Implement partial batch acceptance and a test asserting a 100-event batch with 3 bad events returns `accepted=97, rejected=3` with correct per-index reasons.
4. Add the "every 4xx/5xx references the Error schema" policy test.
5. Write the OpenAPI drift-check script and run it in a pre-commit hook.
6. Write the duplicate-`event_id` end-to-end contract test.

---

*Next module:* **[Module 3 — Log Collection & Parsing: journald, Windows Event Log, Templates, Redaction](learning_module_3.md)** — getting real bytes off real hosts, safely.

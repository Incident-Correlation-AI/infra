# 🧠 Detection & AI Guide — Features, Baselines, Isolation Forest, Correlation, Incidents

> **Derived from** `docs/AI_SPECIFICATION.md`. Detection must be **transparent and evaluable**; it must **not** depend on an LLM. Every claim in this guide is a design to be implemented and measured — not a measured result.

**North star for this track:**
> Detect meaningful deviations and build **evidence-backed incidents**. An alert that cannot point at the events that produced it is not finished.

---

## 1. High-Level Overview & Goals

### 1.1 What "detection" means here

We are not building a generic "AI for logs." We are building a **measurable, explainable anomaly pipeline** with three deliberate properties:

1. **Transparency** — the primary detector is a statistical baseline whose formula, update cadence, minimum samples, and thresholds are all documented. A human can recompute any score by hand.
2. **Evidence** — every incident references the concrete event IDs that support it, the ones that contradict it, and the ones that are missing.
3. **Honesty** — anomaly score ≠ probability ≠ severity ≠ hypothesis confidence. "Unknown" is a valid conclusion. No unsupported root-cause statements, ever.

### 1.2 Goals for this track

| # | Goal |
|---|---|
| D1 | Compute windowed features per host/service/source/dependency, with `None` (not `0`) for missing telemetry |
| D2 | Run a transparent statistical baseline detector with cold-start and contamination protections |
| D3 | Evaluate Isolation Forest as a **complementary, experiment-flagged** detector |
| D4 | Correlate anomalies into incidents using relationship evidence, not just timing |
| D5 | Produce incidents with separated `anomaly_score`, `severity`, and `hypothesis confidence` |
| D6 | Generate deterministic synthetic ground truth and evaluate reproducibly |
| D7 | Emit deterministic, evidence-linked explanations and diagnostic checks |

### 1.3 Non-goals for this track

- ❌ No LLM in the detection path. An external model is **deferred** and must never receive sensitive raw logs by default.
- ❌ K-means is **not** the default detector (§4.3). Algorithms are not collected for their own sake.
- ❌ No claimed causation from timing alone.
- ❌ No accuracy-only reporting for imbalanced detection.
- ❌ No tuning on the test set. Ever.

---

## 2. System / Component Architecture & Design Patterns

### 2.1 Detection sub-pipeline (steps 3–9 of the main pipeline)

```
   events (validated, deduped, normalized)
        │
        ▼
 ┌─────────────────────┐
 │ Pattern/template    │  best-effort; None when infeasible
 │ extraction          │
 └─────────┬───────────┘
           ▼
 ┌─────────────────────┐
 │ Window aggregation  │  per (host, service, source, dependency, window)
 └─────────┬───────────┘
           ▼
 ┌─────────────────────┐
 │ Feature computation │  values: float|None · sample_counts · cold_start
 └─────────┬───────────┘
           ▼
 ┌─────────────────────┐      ┌──────────────────────────┐
 │ Statistical baseline│─────▶│ Anomaly candidates       │
 │ (primary detector)  │      │ (score, entity, window)  │
 └─────────┬───────────┘      └────────────┬─────────────┘
           │                               │
           │        ┌──────────────────────┴──────────────┐
           │        │ Isolation Forest (experiment/flag) │
           │        └──────────────────────┬─────────────┘
           ▼                               ▼
 ┌─────────────────────────────────────────────────────────┐
 │ Correlator: relationship evidence → incident groupings  │
 └────────────────────────────┬────────────────────────────┘
                              ▼
 ┌─────────────────────────────────────────────────────────┐
 │ Incident builder: score/severity/confidence, hypotheses │
 │ explanations, diagnostic checks, audit + model versions │
 └─────────────────────────────────────────────────────────┘
```

### 2.2 Design patterns used

| Pattern | Application |
|---|---|
| **Strategy** | `Detector` interface with `StatisticalBaselineDetector` and `IsolationForestDetector` implementations; both return the same `AnomalyCandidate` shape so the correlator is detector-agnostic |
| **Pipeline** | Each stage is a pure function over immutable value objects; only persistence and clock are injected |
| **Repository** | `BaselineRepository`, `ModelArtifactRepository` — durable state, swappable local/AWS |
| **Snapshot/Versioned artifact** | Isolation Forest model artifacts carry version, seed, feature list, data version |
| **Explainable result object** | `Hypothesis` with support/contradict/missing lists; deterministic template rendering |
| **Guard/Quarantine** | Baseline contamination guard pauses updates during active anomalies |
| **Explicit cold-start state** | `cold_start=True` propagates to features and incidents so the UI can say "warming up" |

### 2.3 Core interfaces (illustrative)

```python
# src/lad/detection/base.py
from typing import Protocol, Sequence
from dataclasses import dataclass
from datetime import datetime

@dataclass(frozen=True)
class AnomalyCandidate:
    entity: "EntityKey"
    window_start: datetime
    window_s: int
    feature: str
    observed: float
    baseline: float | None
    score: float                 # detector-specific unusualness; NOT a probability
    detector: str                # "statistical_baseline" | "isolation_forest"
    details: dict                # detector-specific explain payload (robust z, etc.)

class Detector(Protocol):
    name: str
    def score(self, fv: "FeatureVector") -> Sequence[AnomalyCandidate]: ...


# src/lad/correlate/base.py
class Correlator(Protocol):
    def group(
        self,
        candidates: Sequence[AnomalyCandidate],
        events: Sequence["Event"],
        *,
        window_s: int,           # default 120
        quiet_s: int,            # default 600
    ) -> Sequence["IncidentDraft"]: ...
```

The correlator consumes **candidates + the events that back them**; it never consumes raw log text. That keeps correlation deterministic and testable.

---

## 3. Environment Setup & Prerequisites (detection track)

```bash
# from repo root, with the Python env from guide 01 §3.2 active
pip install -e ".[dev,detector]"     # numpy, scikit-learn (verify pins), pytest, hypothesis

# quick sanity checks before writing detection logic
make contract                       # fixtures still valid
pytest tests/unit/features -q
pytest tests/unit/detection -q
pytest tests/eval -q --scenario=normal   # must produce ZERO incidents on normal traffic
```

**Track-specific prerequisites:**
- [ ] scikit-learn (or an equivalent) available for Isolation Forest; **version pinned after compatibility verification**.
- [ ] Evaluation harness runnable with fixed seeds.
- [ ] Synthetic scenario generators implemented (§6).
- [ ] Decision recorded: thresholding approach for Isolation Forest scores.

⚠️ The `normal` scenario producing zero incidents is a **hard gate**. If normal traffic alerts, fix the baseline/thresholds before building correlation on top of it.

---

## 4. Step-by-Step Implementation Guide

### Step 4.1 — Feature computation

**Rules:**
- **Only compute a feature when the relevant source provides it.** Absence of a metric ≠ value zero. A `None` must remain `None` all the way to the detector, which must skip (not score) that feature for that window.
- Compute per **entity** = `(host, service, source, dependency)` where applicable.
- Record `sample_counts` alongside values so minimum-sample gating is possible.

**Candidate feature list:**

| Feature | Source needed | Notes |
|---|---|---|
| `event_count` / `event_rate` | any | by category and severity |
| `http_5xx_count`, `http_5xx_ratio` | HTTP/app logs | ratio needs a denominator |
| `latency_median`, `latency_p95` | app logs with duration | **only with enough samples** |
| `db_timeout_rate`, `db_conn_failure_rate` | db logs or controlled simulator | |
| `service_restart_frequency` | journald / event log | |
| `auth_failure_rate` | auth/journald/app | |
| `log_template_freq_change` | any with templates | needs template extraction |
| `ingest_delay`, `telemetry_gap` | collector metadata | **operational signals**, separate from "service is broken" |

```python
# src/lad/features/compute.py (illustrative)
def compute_features(
    events: Sequence[Event],
    *,
    window_start: datetime,
    window_s: int,
    entity: EntityKey,
) -> FeatureVector:
    values: dict[str, float | None] = {}
    counts: dict[str, int] = {}

    # only touch http_* when HTTP events actually exist in this window
    http_events = [e for e in events if e.category == "http"]
    if http_events:
        statuses = [e.attributes.get("status") for e in http_events if e.attributes.get("status") is not None]
        if statuses:
            values["http_5xx_ratio"] = sum(1 for s in statuses if 500 <= int(s) < 600) / len(statuses)
            counts["http_5xx_ratio"] = len(statuses)
        durations = [e.attributes.get("duration_ms") for e in http_events if e.attributes.get("duration_ms") is not None]
        if len(durations) >= MIN_SAMPLES_LATENCY:            # minimum-sample gate
            values["latency_p95"] = percentile(durations, 95)
            counts["latency_p95"] = len(durations)
        # else: latency feature simply absent — not zero
    # ... other categories analogous ...

    return FeatureVector(
        window_start=window_start, window_s=window_s, entity=entity,
        values=values, sample_counts=counts,
        cold_start=is_cold_start(entity),
    )
```

**Tests:** assert (a) `http_5xx_ratio` is absent (not `0.0`) for a non-HTTP fixture, (b) latency features absent below `MIN_SAMPLES_LATENCY`, (c) `sample_counts` correct.

### Step 4.2 — Statistical baseline detector (the MVP detector)

This is the **primary** detector. Document, in the implementation and in `docs/decisions/`:

1. **Baseline form:** rolling window **or** time-of-day profile (e.g., same 5-minute slot over N days). Start with rolling; add time-of-day if diurnal patterns cause false positives.
2. **Update cadence:** per window, per entity-feature.
3. **Minimum samples:** a feature with fewer than `MIN_SAMPLES` historical points is **cold-start** — no alerting, status "warming up."
4. **Robust summary:** **median and MAD** (median absolute deviation), not mean/std, because log data has heavy tails.
   - robust z-score: `z = 0.6745 * (x - median) / MAD` (0.6745 scales MAD to σ-equivalent for normal data; document that this is a convention, not a guarantee for log data).
5. **Thresholds:** configurable, calibrated on training/validation data. Record calibration method.
6. **Contamination guard:** during an active anomaly, **pause, gate, or robustly limit** baseline updates. A system must not rapidly learn an attack as normal.
7. **Durability:** baseline state lives in the store. **Never rely on Lambda process memory for persistence.**

```python
# src/lad/detection/statistical/baseline.py (illustrative)
from dataclasses import dataclass
import statistics as stats

MAD_SCALE = 0.6745  # convention; documented in the decision log

@dataclass
class BaselineState:
    entity_feature: str
    history: list[float]
    min_samples: int = 30
    cold_start: bool = True
    paused_updates: int = 0          # auditability: how often the guard fired

    def consider(self, x: float) -> "BaselineState":
        if len(self.history) < self.min_samples:
            return self._replace(history=self.history + [x], cold_start=len(self.history) + 1 < self.min_samples)
        return self._replace(history=(self.history + [x])[-WINDOW:], cold_start=False)

    def robust_z(self, x: float) -> float | None:
        if self.cold_start or len(self.history) < self.min_samples:
            return None                       # caller must skip — not "0"
        med = stats.median(self.history)
        mad = stats.median([abs(h - med) for h in self.history])
        if mad == 0:
            return None                       # degenerate; skip and log
        return MAD_SCALE * (x - med) / mad


def update_baseline(
    state: BaselineState, value: float, *, anomaly_active: bool
) -> BaselineState:
    """Contamination guard: do not learn an active anomaly as normal."""
    if anomaly_active:
        return state.with_paused_updates()      # record pause for audit
    return state.consider(value)
```

**Required tests:**
- No alerts during cold start (and `cold_start=True` surfaces in the incident/feature state).
- Baseline does **not** move during an injected anomaly (contamination guard test).
- State survives a simulated process restart (durability test).
- Degenerate `MAD == 0` handled without divide-by-zero.

**Calibration:** choose thresholds by sweeping on **validation** data and plotting the precision/recall vs. false-alerts/hour tradeoff. Record the chosen point and why. Recalibrate when features change.

### Step 4.3 — Isolation Forest (experiment; complementary)

**Status:** experiment, flagged. It may **not** create user-visible incidents until the team records a go decision backed by held-out metrics. In `shadow` mode it computes and logs scores for comparison.

**What Isolation Forest actually is (and is not):**
- It isolates points by recursively random feature splits. Points isolatable in few splits get high anomaly scores.
- Its score is **not automatically a probability.** Decide how to threshold scores using training/validation data, then evaluate on held-out data. **Do not tune on the test set.**

**Procedure:**
1. **Features:** engineered numeric/window features only. Document preprocessing and missing-value behavior (e.g., impute-with-median fit on **training** data only, plus a missingness indicator — never impute using validation/test statistics).
2. **Split:** train on the training portion; **no leakage across adjacent windows from the same incident.** Split by time/host/scenario.
3. **Train:** fixed `random_state`. Record parameters, seed, feature list, data version, and model artifact/version.
4. **Threshold:** pick on training/validation. Common approaches — pick one and document it:
   - contamination parameter set from the expected anomaly rate in training data, or
   - score threshold at a chosen percentile of validation scores.
5. **Evaluate:** compare to the statistical baseline on **identical held-out scenarios**.
6. **Decide:** if it does not improve useful metrics **or** consumes too much integration time, **document the experiment and keep the statistical detector as the MVP detector.** That is a successful outcome, not a failure.

```python
# src/lad/detection/isolation_forest/experiment.py (illustrative)
from dataclasses import dataclass
from sklearn.ensemble import IsolationForest   # version pinned in pyproject

@dataclass(frozen=True)
class ModelArtifactMeta:
    version: str
    seed: int
    features: tuple[str, ...]
    data_version: str
    trained_at: str
    threshold: float
    preprocessing: str   # e.g. "median-impute-fit-on-train + missing-indicator"

def train(features_train, *, seed: int = 42, contamination: float = 0.01) -> "IsolationForest":
    clf = IsolationForest(n_estimators=200, contamination=contamination, random_state=seed)
    clf.fit(features_train)
    return clf

def shadow_score(clf, fv_vector) -> float:
    """shadow mode: returns a score for logging/comparison; never raises incidents."""
    return float(-clf.score_samples(fv_vector)[0])
```

**Shadow-mode logging** (structured, no secrets):
```json
{"mode":"shadow","detector":"isolation_forest","entity":"host-alpha/svc-pay/api",
 "window_start":"2026-10-17T10:15:00Z","score":0.61,"threshold":0.58,
 "statistical_triggered":true,"model_version":"if-0003","seed":42}
```
This lets Gate 4 build a real comparison without shipping the second detector to users prematurely.

### Step 4.4 — Why not K-means (and other algorithms)

**K-means is not the default detector.** It clusters data into K groups; K is the number of clusters, **not** the number of anomaly classes. Distance from a centroid can be a heuristic, but clusters are **not** inherently labeled normal/anomalous. Choosing K, handling high-dimensional sparse features, and interpreting "cluster 3 is the anomaly one" are all judgment calls that make the system *less* transparent, not more.

LOF, One-Class SVM, and friends require **separate justification and evaluation**. Do not add algorithms to increase an algorithm count. If someone proposes one, require: (a) the hypothesis it addresses that the baseline/IF miss, (b) the evaluation that will decide, (c) the maintenance cost. Usually the answer is "measure the baseline better."

### Step 4.5 — Correlation

**Use (in rough strength order):**
1. Explicit **request/trace IDs** when available — strongest.
2. Common **host/service identity**.
3. **Known dependency metadata** (service X depends on db Y).
4. Compatible **event categories**.
5. **Event ordering** within the window.
6. Repeated evidence + incident **lifecycle state**.

**Weak evidence:** timestamp proximity **alone**. It is a *filter*, not a *link*.

**Rules:**
- Distinguish **correlation from causation.** Never let the correlator emit a causal statement.
- Keep **unrelated simultaneous anomalies separate** (synthetic scenario 4 tests exactly this).
- Handle **late/out-of-order events**, duplicate messages, quiet periods, and reopening.
- Defaults: **correlation window = 120 s**, **quiet period = 600 s** (both configurable). Quiet period elapsing ≠ proof of recovery.

```python
# src/lad/correlate/correlator.py (illustrative)
def link_strength(a: AnomalyCandidate, b: AnomalyCandidate, events_by_id: dict) -> int:
    """0 = no link; higher = stronger relationship evidence."""
    score = 0
    if share_trace_or_request_id(a, b, events_by_id): score += 4
    if a.entity.host == b.entity.host and a.entity.service == b.entity.service: score += 2
    if known_dependency(a.entity, b.entity): score += 2
    if compatible_categories(a, b): score += 1
    if ordering_consistent(a, b): score += 1
    return score

def group(candidates, events, *, window_s=120, quiet_s=600, min_link=3):
    incidents = []
    for c in sorted(candidates, key=lambda c: c.window_start):
        match = find_open_incident(c, incidents, window_s=window_s, quiet_s=quiet_s)
        if match and link_strength(match.representative, c, events) >= min_link:
            match.absorb(c, evidence=events_for(c))
        else:
            incidents.append(IncidentDraft.from_candidate(c, evidence=events_for(c)))
    return incidents
```

`min_link` ensures timestamp proximity alone cannot merge incidents. Tune it on synthetic scenarios and record the value.

**Tests (required):**
- DB timeout + HTTP 500 spike sharing a trace → **one** incident with supporting evidence.
- Two unrelated anomalies in the same minute, same host, **no** trace/dependency link → **two** incidents.
- Late-arriving related event within the window → attaches to the existing incident, does not create a duplicate.
- Related event after the quiet period → new incident (documented behavior), with the prior incident referenced in audit.

### Step 4.6 — Incident building, hypotheses, explanations

Keep three quantities **separate**:

```
anomaly_score      detector-specific unusualness (float; not a probability)
severity           estimated operational impact (documented rules: e.g. auth-failure
                   surge on a prod host = high; latency blip on a dev box = low)
hypo_confidence    strength of support for a proposed explanation
                   (use levels: low/medium/high — NOT a probability unless calibrated)
```

**Each hypothesis must reference:**
- `supporting_event_ids`
- `contradicting_event_ids`
- `missing_evidence` (e.g., "no db timeout events found; db logs may not be collected from host-beta")
- statement, confidence level

**"Unknown" is a valid outcome.** If the evidence does not support any specific explanation, the hypothesis is `statement: "Unknown"`, `confidence: low`, and the missing-evidence list explains what would be needed.

**Diagnostic recommendations:**
- **Specific** ("Check whether `postgresql.service` restarted on host-beta between 10:14–10:16" — not "check the database").
- **Evidence-linked** (each check cites the event IDs or features that motivated it).
- **Non-executing** — the system never runs anything. No remediation, no scanning.

**Deterministic explanations** (template, not generation):

```
Incident {id}: {severity} — {summary_template}
  Entity:        {host}/{service}/{source}
  Window:        {window_start} → {window_end} UTC
  Detector:      {detector} (score {anomaly_score:.3f})
  Observed vs baseline:
    - {feature}: observed {obs} vs baseline {base} (robust z={z})
  Supporting events:  {n} (e.g. {first_ids}…)
  Contradicting:      {m} event ids
  Missing evidence:   {missing list}
  Hypotheses:
    1. {statement} [{confidence}] — supported by {ids}; contradicted by {ids}
  Recommended diagnostics (non-executing):
    - {check 1, linked to evidence}
```

⚠️ **Never generate unsupported root-cause statements.** No free-form text model in this path.

### Step 4.7 — LLM policy (explicit)

An external model is **deferred**. If ever added:
- It must **never receive sensitive raw logs by default.**
- It may only *suggest phrasings* over the **structured** hypothesis/evidence object — and the UI must show the structured evidence as the source of truth.
- It must be optional and off by default.

---

## 5. Data Models & State Management (detection track)

### 5.1 AnomalyCandidate / IncidentDraft / Incident

```python
@dataclass(frozen=True)
class IncidentDraft:
    entity: EntityKey
    window_start: datetime
    window_s: int
    anomaly_score: float
    detector: str
    candidate_ids: tuple[str, ...]
    supporting_event_ids: tuple[str, ...]

@dataclass
class Hypothesis:
    statement: str                       # or "Unknown"
    confidence: str                      # low | medium | high
    supporting_event_ids: tuple[str, ...]
    contradicting_event_ids: tuple[str, ...]
    missing_evidence: tuple[str, ...]

@dataclass
class Incident:
    incident_id: str
    schema_version: str
    status: str                          # open | acknowledged | resolved
    severity: str
    affected_entities: tuple[EntityKey, ...]
    anomaly_score: float
    detector: str
    model_versions: dict[str, str]
    hypotheses: tuple[Hypothesis, ...]
    diagnostic_checks: tuple[DiagnosticCheck, ...]
    audit: list[AuditEntry]
    created_at: datetime
    updated_at: datetime
```

### 5.2 Durable detection state

| State | Where | Durability rule |
|---|---|---|
| Baseline per (entity, feature) | Store (`BaselineRepository`) | **Mandatory durable.** Never Lambda memory. Simulated-restart test required. |
| Cold-start flags | Store | Same as baseline |
| Contamination-guard pause counters | Store / incident audit | Auditable |
| Isolation Forest artifact + meta | Store / file / S3 | Versioned; `ModelArtifactMeta` recorded per incident that used it |
| Shadow-mode scores | Logs / eval store | For Gate 4 comparison |
| Window aggregates | Store (compact) | Only as long as justified |

### 5.3 Versions and reproducibility (audit fields on every incident)

- `detector` name(s) that produced the score(s)
- `model_versions` (e.g., `{"statistical_baseline": "rule-set-0002", "isolation_forest": "if-0003"}`)
- baseline config id / threshold id
- For eval runs: commit SHA, dataset/scenario, seed, split, parameters

---

## 6. Synthetic Scenarios & Evaluation

### 6.1 The five required deterministic scenarios

Build these with **fixed seeds** and **documented parameters**. Each generated event must be **traceable to a scenario/incident label** in evaluation metadata that is **not accidentally included as a model feature** (leakage!).

| # | Scenario | Proves |
|---|---|---|
| 1 | Normal operation | Zero/false-minimal alerts; false alerts/hour measurable |
| 2 | Service restart burst **or** failed-authentication surge | Single-source detection works |
| 3 | DB timeout **followed by** HTTP 500 spike | Correlation with dependency/trace evidence |
| 4 | Two unrelated anomalies at similar times | Correlator does **not** falsely merge |
| 5 | Delayed/out-of-order events, duplicates, retries, disconnection, recovery | Reliability + correlation robustness |

```python
# evaluation/scenarios/restart_burst.py (illustrative)
SCENARIO_ID = "restart-burst-v1"
SEED = 1234

def generate(rng, *, host="host-alpha", normal_minutes=30, burst_count=8):
    events = normal_traffic(rng, minutes=normal_minutes, host=host)   # labeled normal
    burst = [
        make_event(rng, host=host, category="process", type="service_restart",
                   service=f"svc-{i%2}", ts=burst_start + i * timedelta(seconds=7))
        for i in range(burst_count)
    ]
    truth = {"incident_label": SCENARIO_ID, "anomaly_start": burst_start.isoformat()}
    return events + burst, truth     # truth stored in eval metadata, NOT in features
```

### 6.2 Datasets

Public log datasets (**LogHub, HDFS, BGL**) are **optional evaluation inputs** — candidates to investigate, not assumed ready-to-use dependencies. Before adopting any:
- verify **source, license, labels, size, relevance**
- distinguish **raw logs** from **labeled anomaly windows**
- document **parsing assumptions and label quality**

If a dataset's labels are weak, say so in the report; do not present its metrics as ground truth.

### 6.3 Evaluation protocol

**Split by time, host, or scenario/incident — never random adjacent windows** (near-duplicates leak). Fit preprocessing and thresholds on training/validation only.

**Report at minimum:**

| Metric | Definition | Caveat |
|---|---|---|
| Precision | TP / (TP + FP) | only where labels justify event/incident matching |
| Recall | TP / (TP + FN) | |
| F1 | harmonic mean | |
| **False alerts / hour** | false incident count ÷ evaluated normal hours | the operational number that matters most |
| **Detection delay** | first valid detection − anomaly start | document clock assumptions |
| Correlation false merges | unrelated ground-truth incidents combined | |
| Correlation missed links | related ground-truth events left uncorrelated | |
| Event loss / duplication | expected unique vs received/processed unique | ingestion, not detector |
| Processing latency | observation/ingest → incident visible | document clock assumptions |
| Performance by scenario & source | sliced metrics | avoid averages that hide a broken source |

⚠️ **Do not report accuracy alone** for imbalanced anomaly detection. Show **counts and the denominator**. Do **not claim generalization from a tiny synthetic test.**

**Matching rule (document it before computing):** e.g., "a predicted incident matches ground truth if it overlaps the true anomaly window on the same entity and is created within the reporting horizon." No matching rule → no metric.

### 6.4 Detector comparison (Gate 4 deliverable)

Run **both** detectors on **identical held-out scenarios** and produce a table:

| Scenario | Detector | Precision | Recall | F1 | False alerts/h | Detection delay (s) | Notes |
|---|---|---|---|---|---|---|---|
| … | statistical_baseline | | | | | | |
| … | isolation_forest (shadow) | | | | | | |

Include parameters, seed, feature list, data version, model version. If Isolation Forest doesn't win meaningfully, **document and keep the baseline as the MVP detector.**

---

## 7. Security, Testing, and Deployment Considerations (detection track)

### 7.1 Security & privacy in detection

- **Redaction** happens upstream (collector + ingestion) — detection operates on already-redacted envelopes. Do not add new raw-text capture in this layer.
- **Baseline contamination is a security issue**, not just an accuracy issue: an attacker who can generate traffic could poison a naive baseline to make an attack look normal. The guard in §4.2 is a **control**, and its pause behavior must have a **test**.
- **No secrets in eval reports or logs.** Shadow-mode logs contain scores and entities, not message bodies.
- **Logs are data, never instructions.** Template extraction and message parsing must never `eval`, shell out, or interpret log content as commands.
- **No automatic remediation** from detection output. Diagnostic checks are read-only suggestions.

### 7.2 Testing matrix for this track

| Layer | Must cover |
|---|---|
| Unit | feature computation (`None` propagation, min-samples), robust z, cold start, contamination guard, template extraction, severity rules |
| Contract | candidates/incidents validate against `incident.schema.json` |
| Integration | candidates → correlator → incident persistence; baseline durability across restart |
| Reliability | late/out-of-order events (scenario 5), duplicate events do not double-score, worker restart mid-window |
| Security | contamination-guard behavior; no secrets in outputs; log-content-is-data parsing |
| Detector eval | scenarios 1–5, both detectors, reproducible seeds |
| E2E | a real injected anomaly appears in the dashboard with evidence, baseline-vs-observed, and checks |

**Hard gates:**
- [ ] Normal scenario produces **zero** incidents (or a documented, reviewed threshold change).
- [ ] Scenario 3 correlates into **one** incident with supporting evidence.
- [ ] Scenario 4 stays as **two** incidents.
- [ ] Replaying the same queue batch twice does not duplicate incidents.
- [ ] Baseline state survives a restart and is **not** updated during an injected anomaly.

### 7.3 Deployment considerations for detection code

- **Cold starts:** keep the import graph lean; lazy-load scikit-learn **only if** the experiment flag is on. If Isolation Forest is off, its dependencies ideally aren't even imported.
- **Model artifacts:** if the experiment ships, artifacts are versioned objects (S3 or a build artifact), loaded explicitly, with the version recorded per incident. Never "whatever file is on disk."
- **State sizing:** baseline history is bounded (`history[-WINDOW:]`); unbounded history is a memory leak that will eventually OOM a Lambda.
- **Configuration:** thresholds, window sizes, min-samples, correlation window, quiet period are **environment-specific config**, not constants. Document each, default them sanely, and log the active set at startup.
- **Determinism:** seed everything (`random_state`, generator seeds). A metric without a seed is not reproducible.

### 7.4 Reporting discipline (applies to every result produced by this track)

Every reported number must carry:
`commit · dataset/scenario · seed · split · parameters · event counts · metric definition · measured result · limitations`

**Never claim tests passed unless they were run. Never claim generalization from a tiny synthetic test. Never call an anomaly score a probability.**

---

## 8. Definition of Done (detection track)

- [ ] Features computed with correct `None` (not zero) semantics; min-sample gates in place.
- [ ] Statistical baseline documented (formula, cadence, min-samples, thresholds) and tested, including cold start + contamination guard + durability.
- [ ] Isolation Forest experiment implemented behind a flag, with recorded seed/params/feature list/data version/model version; shadow-mode comparison runs.
- [ ] K-means rejected with rationale recorded in the decision log.
- [ ] Correlator links on relationship evidence; timestamp-only merging is impossible (`min_link`).
- [ ] Incidents separate score/severity/hypothesis confidence; hypotheses carry support/contradict/missing; "Unknown" allowed.
- [ ] Diagnostic checks are specific, evidence-linked, and non-executing.
- [ ] Scenarios 1–5 generated deterministically; leakage checks pass (labels not in features).
- [ ] Evaluation report produced with full reproducibility metadata and honest limitations.
- [ ] No LLM in the path; no unsupported root-cause statements anywhere.

---

*Next:* `03_CLOUD_AND_BACKEND_GUIDE.md` (SQS/DynamoDB/Lambda/SAM, auth, cost) → `04_DEVOPS_...` → `05_API_AND_DATA_CONTRACTS_GUIDE.md`.

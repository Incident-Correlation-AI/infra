# 📚 Learning Module 4 — Statistical Anomaly Detection: Windows, Baselines, Robust Statistics & Correlation

> **Module goal:** Turn windowed event counts into **trustworthy, explainable, reproducible** alerts — and merge those alerts into incidents using evidence, not just timing.
> **Project tie-in:** You will build `src/lad/features/`, `src/lad/detection/statistical/`, `src/lad/correlate/`, and the evaluation harness.

**Estimated study time:** 30–40 hours. **Prereq:** Modules 1–3; comfort with basic probability.

---

## Table of Contents

1. [Core Theory & In-Depth Explanation](#1-core-theory--in-depth-explanation)
   - 1.1 What "anomaly" means, and why definitions matter
   - 1.2 Windows: tumbling, sliding, and the aggregation decision
   - 1.3 Features that actually indicate problems
   - 1.4 Baseline families: rolling, time-of-day, adaptive
   - 1.5 Robust statistics: why mean/σ lie, and what to use instead
   - 1.6 Thresholding, scores, and calibrating to a false-positive budget
   - 1.7 Cold start, minimum samples, and honest uncertainty
   - 1.8 Contamination: how a baseline can be poisoned, and how to guard
   - 1.9 Correlation: evidence graphs, windows, quiet periods, reopening
   - 1.10 Incident semantics: score vs. severity vs. confidence, explanations
2. [Practical Examples & Code Walkthroughs](#2-practical-examples--code-walkthroughs)
3. [Common Pitfalls & Debugging](#3-common-pitfalls--debugging)
4. [Curated Resources](#4-curated-resources)

---

## 1. Core Theory & In-Depth Explanation

### 1.1 What "anomaly" means, and why definitions matter

There is no universal anomaly. There are only **operational definitions**, and each one implies a different detector, a different evaluation, and a different failure mode.

Three common definitions:

1. **Point anomaly** — an individual observation far from the norm (one huge latency). Detectors: robust z-score, Isolation Forest (Module 5).
2. **Contextual anomaly** — normal in one context, abnormal in another (high traffic at 9am is normal; at 3am it is not). Detectors: time-of-day baselines.
3. **Collective anomaly** — a *sequence* is abnormal even if each point is individually fine (a slow ramp in 5xx rate). Detectors: windowed/aggregate features, changepoint methods.

**This project's stance:** the primary detector is a **contextual, windowed, statistical baseline**. We define an anomaly as:

> A window's feature value deviating from a **robust, context-aware baseline** by more than a threshold calibrated on **validation** data, with enough samples and a non-cold-start baseline.

**Why this definition?** It is transparent (a human can recompute it), evaluable (precision/recall/FP-per-hour), robust to outliers, and honest (cold start and sample counts are explicit). The Isolation Forest is a **complementary, held-out-validated** experiment and may not replace the baseline until it demonstrably improves useful metrics.

#### The Anomaly Detection literature, briefly

Chandola, Banerjee & Kumar's 2009 survey taxonomy: **classification-based, nearest-neighbor, clustering, statistical, information-theoretic, spectral**. Our baseline is *statistical*; Isolation Forest is *ensemble/nearest-neighbor-flavored*. The survey's key lesson for practitioners: **choose the method to match the anomaly definition and the evaluation you can afford.** Adding methods without matching definitions is how projects accumulate unmaintainable complexity — exactly the "do not add them merely to increase algorithm count" warning.

### 1.2 Windows: tumbling, sliding, and aggregation

You cannot detect "the error rate went up" without first defining **over what**. Windows are how time-series are discretized.

- **Tumbling window** — fixed, non-overlapping: `[10:00,10:01)`, `[10:01,10:02)`, … Simple, no double-counting, easy to persist. **Our default for rates and counts.**
- **Sliding window** — overlapping, advancing by a step: compute over the last 60 s every 10 s. Smoother, catches slow ramps, but each event lands in multiple windows (careful with leakage in evaluation).
- **Session/adaptive windows** — grouped by activity rather than clock time. Out of scope for MVP.

```
Tumbling (60s):      |----|----|----|----|
Sliding (60s, 10s):  |--------|
                       |--------|
                         |--------|
```

**The double-counting trap:** if you *sum* counts over overlapping windows you inflate them. Overlapping windows are for *detection statistics*, not for totals. Persist aggregates per **tumbling** window; derive sliding views from them if needed.

**Window size selection** is a design trade-off:

| Smaller window | Larger window |
|---|---|
| Faster detection (lower delay) | More samples per window (better stats) |
| Noisier (fewer samples → unstable rates) | Smoother (lag on onset) |
| More windows to persist/score | Fewer |

The project's defaults: **60 s tumbling** for counts/rates, **5 min tumbling** for latency percentiles (needs enough samples). Both configurable. Revisit with data.

**Alignment:** align windows to epoch boundaries (`start = floor(ts / 60) * 60`) so independent workers agree on window identity without coordination. This is critical for idempotency: two workers scoring the same window must key it identically.

### 1.3 Features that actually indicate problems

From the spec's candidate list, with rationale:

| Feature | Why it signals trouble | Traps |
|---|---|---|
| `event_count` / `event_rate` by category & severity | volume shifts | seasonal load; deploy spikes |
| `http_5xx_ratio` | user-facing failures | needs a *denominator*; zero-traffic windows are `null`, not `0` |
| `latency_median`, `latency_p95` | degraded service | needs enough samples; p95 is unstable at low n |
| `db_timeout_rate`, `db_conn_failure_rate` | dependency trouble | only if DB logs are collected |
| `service_restart_frequency` | crashes/deploys | deploys look like anomalies (policy decision) |
| `auth_failure_rate` | attacks / user errors | legit lockouts |
| `log_template_freq_change` | novel errors | requires template extraction (Module 3) |
| `ingest_delay`, `telemetry_gap` | *operational* signals | distinguish "broken metric" from "broken service" |

**The null vs. zero rule, restated because it is the most common bug:** if there are no HTTP events in a window, `http_5xx_ratio` is **absent/cold**, not `0.0`. A fabricated zero would (a) drag the baseline toward zero and (b) look like a *recovery* anomaly. The feature layer must emit `None`, and the detector must **skip**, not score.

**Per-entity features:** compute per `(host, service, source, dependency)`. A global error rate can be flat while one host is on fire — a well-known "the average hides the fire" failure. Entities make anomalies localizable, which also makes evidence smaller and explanations sharper.

### 1.4 Baseline families

A **baseline** is an estimate of "what's normal" for a feature at an entity. Families:

1. **Rolling/static baseline.** Estimate from the last *N* windows (e.g., last 30 non-anomalous windows). Simple, adapts slowly. Good default.
2. **Time-of-day profile.** Estimate per slot-of-day (e.g., same 5-minute slot across the last *D* days). Handles diurnal patterns (business hours vs. night). Costs more state and needs more history.
3. **Adaptive/EWMA.** Exponentially weighted moving average — recent data weighted more. Responds faster but is *more susceptible to contamination* (it "learns" the anomaly quickly). If used, pair with the contamination guard and dampen during anomalies.
4. **Robust location/scale.** Whatever the family, summarize with **median + MAD** rather than mean + std (see §1.5).

**Choosing:** start rolling. Add time-of-day **only if** false positives cluster by hour-of-day in evaluation. Each added sophistication must earn its keep against a measured metric, and the chosen formula, cadence, minimum samples, and threshold calibration must be **documented** (the spec requires this explicitly).

**Update cadence:** update the baseline once per scored window, *after* deciding whether the window is anomalous (so an anomaly doesn't contaminate the update). Persist state durably — **never Lambda memory.**

### 1.5 Robust statistics: why mean/σ lie

Log metrics have **heavy tails** and **outliers**. Consider latencies: `[10, 11, 12, 13, 14, 2000]`. 

- mean = 343.3, std ≈ 812 → the outlier dominates both.
- median = 12.5; MAD (median absolute deviation) = 1.5.

A z-score using mean/std would need a latency of 343 + k·812 to alert — the outlier **masks** future anomalies (it inflated σ). A robust z-score using median/MAD alerts on the *next* 2000 comfortably.

**Definitions:**

```
median(x) = middle value (even n → average of two middles)
MAD(x)    = median( |x_i − median(x)| )
robust_z(x) = 0.6745 · (x − median) / MAD         # 0.6745 ≈ Φ⁻¹(0.75), σ-scaling for normal data
```

⚠️ **The 0.6745 constant is a *convention* for consistency with the standard deviation under normality.** Log data is not normal, so treat the robust z as a *relative* deviation score, not a probability or a literal number of sigmas. Document this; it prevents the classic mistake of claiming "3.5σ" as if it were Gaussian.

**Degenerate MAD:** if `MAD == 0` (e.g., a perfectly constant feature like a counter that never moved), the robust z is undefined (divide-by-zero). Handle it explicitly: skip, or fall back to a minimum scale, and log it. Silent `inf`/`NaN` leaking into scores is a real bug.

**Other robust tools worth knowing:**
- **Trimmed mean / winsorization** — drop or clamp extreme values before summarizing.
- **Interquartile range (IQR)** — `Q3 − Q1`; `x > Q3 + 1.5·IQR` is the classic boxplot outlier rule.
- **Quantile-based thresholds** — alert if a value exceeds the 99th percentile of history (with enough history).
- **Robust regression / Theil–Sen** — for trend estimation resistant to outliers.

### 1.6 Thresholding, scores, and calibrating to a false-positive budget

You need a decision rule: `is_anomalous = robust_z(x) > τ` (optionally with direction: high and/or low).

**How to choose τ?** Not by gut. Calibrate on **validation** data:

1. Compute robust z for every window in the validation set.
2. Sweep τ and compute **precision**, **recall**, and **false alerts per hour (FAPH)**.
3. Pick the τ that meets a target FAPH budget (e.g., "≤ 1 false alert/hour on normal traffic") while maximizing recall — because operations tolerate *missing* a subtle anomaly less than being paged constantly. That trade-off is a *product decision*; record it.

```
              τ too low                 τ too high
   many false alerts (alert fatigue)    misses real anomalies
   ← FAPH high                            FAPH low → recall low →
```

**Directionality matters:** some features are one-sided (5xx rate only goes "up" badly). Others are two-sided (event volume can collapse → collector down). Encode direction per feature in config.

**Hysteresis / persistence:** a single window above τ may be noise. Require `k` consecutive anomalous windows (or an area-under-threshold integral) before opening an incident. This directly reduces FAPH. But it *increases detection delay* — another explicit trade-off. Default: require 2 consecutive windows; document it.

### 1.7 Cold start, minimum samples, and honest uncertainty

A brand-new entity has no history. Any detector that "alerts on day one" is guessing. Therefore:

- **Minimum samples** per (entity, feature) before alerting (e.g., ≥30 windows). Until then: **cold start**, no alerts.
- **Cold-start status propagates** to features and incidents so the UI can honestly say "warming up." This is a feature, not a bug.
- **Minimum-denominator rules** for ratios: `http_5xx_ratio` also needs enough *requests*; 1 error out of 1 request is not a 100% error rate worth alerting on.

Cold-start interacts with deployment: after the collector is installed, there is a **silent learning period**. Communicate this in the demo and UI so it doesn't look like "the detector doesn't work."

### 1.8 Contamination: how a baseline can be poisoned, and how to guard

**Contamination** is when anomalous data is absorbed into the baseline, making the anomaly look normal. Two causes:

1. **Accidental:** a slow-onset failure gets "learned" as the new normal.
2. **Adversarial:** an attacker generates lots of "normal-looking" traffic to shift the baseline, then attacks — a **baseline poisoning attack** (this is a security issue, not just accuracy).

**Guards (all three in the design):**
- **Pause updates during active anomalies:** if a window is flagged anomalous, do **not** include it in the baseline update. Record `paused_updates` for auditability.
- **Robust updates:** use median/MAD and bounded drift, so a few extreme points can't move the baseline far.
- **Rate-limit / cap drift:** limit how much the baseline can move per unit time (e.g., EWMA with a small α, or a per-window delta cap), so a sustained attack can't instantly redefine normal.

```python
def update_baseline(state, value, *, anomaly_active: bool):
    if state.cold_start:
        return state.consider(value)          # still filling the minimum sample count
    if anomaly_active:
        return state.with_paused_updates()    # contamination guard
    return state.robust_update(value)         # median/MAD, bounded drift
```

**Test it:** inject a 10-window anomaly and assert the baseline stays within a small bound of the pre-anomaly value (i.e., it did **not** learn the attack).

### 1.9 Correlation: evidence graphs, windows, quiet periods, reopening

Detection produces **candidates**. Correlation groups candidates + their backing events into **incidents**.

**The cardinal rule:** timestamp proximity alone is **weak evidence**. It is a *filter*, not a *link*.

**Evidence strength hierarchy (link weight):**

```
strongest   explicit shared request/trace ID
             │  common host/service identity
             │  known dependency (X depends on Y)
             │  compatible event categories
             │  event ordering within window
weakest      timestamp proximity alone
```

**Windows and quiet periods:**
- **Correlation window** (default 120 s): candidates within this span *may* belong together.
- **Quiet period** (default 600 s): no related evidence for this long → the incident is considered quiet; elapsing is **not proof of recovery** (the spec is emphatic).
- Both configurable.

**Merging rule:** merge only when `link_strength ≥ min_link`, where `link_strength` sums evidence beyond time. This makes "two unrelated anomalies in the same minute" **provably separate** (scenario 4).

**Handling edge cases:**
- **Late/out-of-order events:** a related event arriving after the window but within the quiet period attaches to the existing incident (no duplicate).
- **Duplicates/retries:** dedup by stable ID before correlation (Module 2/3).
- **Reopening:** if new related evidence arrives after resolution, **append** a new incident that references the old one (never mutate history silently). Decide resolve-without-acknowledge and reopen rules in an ADR.
- **Quiet periods with no recovery evidence:** the incident can be marked resolved-by-quiet-period, but the UI must say "resolved by quiet period, not confirmed recovery."

**Graph framing (optional but clarifying):** model candidates as nodes and evidence links as weighted edges; incidents are connected components under `edge_weight ≥ min_link`. This is a clean way to implement and reason about correlation, and it makes "false merge" and "missed link" directly measurable.

### 1.10 Incident semantics: score vs. severity vs. confidence

Three **orthogonal** concepts the spec insists on separating:

| Concept | Meaning | Range | Never |
|---|---|---|---|
| **anomaly_score** | detector-specific unusualness | unbounded float | call it a probability |
| **severity** | estimated operational impact (documented rules) | low/medium/high/critical | imply it's the score |
| **hypothesis confidence** | strength of support for an explanation | low/medium/high | call it a probability unless calibrated |

**Severity rules (example policy, document yours):**
```
critical: auth-failure surge on prod host; or 5xx_ratio>0.5 sustained; or DB outage + user-facing errors
high:     restart burst; or 5xx_ratio breach with traffic; or dependency failure without user impact yet
medium:   elevated latency; isolated errors; degraded (not down) dependency
low:      single-window blips; non-prod hosts; informational
```

**Hypotheses** must cite `supporting_event_ids`, `contradicting_event_ids`, and `missing_evidence`. **"Unknown" is valid.** Explanations are **deterministic templates** over structured fields — never free-form generation. Diagnostic checks are specific, evidence-linked, and **non-executing**.

**Explaining "why":** for each alert show observed vs. baseline (with the robust deviation), the window, the entity, the detector, the supporting events, the possible alternatives, and what evidence is missing. This is the difference between an alert and an investigation aid.

---

## 2. Practical Examples & Code Walkthroughs

### 2.1 Feature vector and the null-not-zero rule

```python
# src/lad/features/types.py
from dataclasses import dataclass, field
from datetime import datetime
from typing import Mapping

@dataclass(frozen=True, slots=True)
class EntityKey:
    host: str
    service: str | None
    source: str | None
    dependency: str | None = None
    def key(self) -> str:
        return "|".join(x or "-" for x in (self.host, self.service, self.source, self.dependency))

@dataclass(frozen=True, slots=True)
class FeatureVector:
    entity: EntityKey
    window_start: datetime
    window_s: int
    values: Mapping[str, float | None]      # None = source didn't provide it
    sample_counts: Mapping[str, int]
    cold_start: bool
    def __post_init__(self):
        assert self.window_s > 0
```

```python
# src/lad/features/compute.py
from collections import Counter
from datetime import datetime, timedelta
from lad.contracts import Event

MIN_SAMPLES_LATENCY = 20

def align_window(ts: datetime, size_s: int) -> datetime:
    epoch = int(ts.timestamp())
    return datetime.fromtimestamp(epoch - (epoch % size_s), tz=ts.tzinfo)

def compute_window(events: list[Event], *, window_start: datetime, window_s: int,
                   entity: EntityKey, cold_start: bool) -> FeatureVector:
    vals: dict[str, float | None] = {}
    counts: dict[str, int] = {}

    # ---- volume ----
    vals["event_count"] = float(len(events))
    counts["event_count"] = len(events)

    # ---- HTTP ----
    http = [e for e in events if e.category == "http"]
    statuses = [int(e.attributes["status"]) for e in http
                if e.attributes.get("status") is not None]
    if statuses:                                    # only if the source provides status
        vals["http_5xx_ratio"] = sum(1 for s in statuses if 500 <= s < 600) / len(statuses)
        counts["http_5xx_ratio"] = len(statuses)
    # else: key absent → None-equivalent; detector will skip

    durations = [float(e.attributes["duration_ms"]) for e in http
                 if e.attributes.get("duration_ms") is not None]
    if len(durations) >= MIN_SAMPLES_LATENCY:       # minimum-denominator gate
        vals["latency_p95"] = percentile(durations, 95)
        counts["latency_p95"] = len(durations)

    # ---- DB ----
    db = [e for e in events if e.category == "db"]
    if db:
        vals["db_timeout_rate"] = sum(1 for e in db if e.type == "db_timeout") / len(db)
        counts["db_timeout_rate"] = len(db)

    # ---- auth ----
    auth = [e for e in events if e.category == "auth"]
    if auth:
        vals["auth_failure_rate"] = sum(1 for e in auth if e.type == "auth_failure") / len(auth)
        counts["auth_failure_rate"] = len(auth)

    return FeatureVector(entity=entity, window_start=window_start, window_s=window_s,
                         values=vals, sample_counts=counts, cold_start=cold_start)

def percentile(xs: list[float], p: float) -> float:
    xs = sorted(xs)
    k = (len(xs) - 1) * (p / 100.0)
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)
```

**Walkthrough:** every feature is computed **only if the source provided the needed data**. No defaulting to zero. `sample_counts` travels with values so the detector can enforce minimum samples. `cold_start` is passed through, not recomputed here.

**Test (the rule that saves you):**
```python
def test_non_http_source_yields_no_http_features():
    ev = make_event(category="process", type="service_restart")
    fv = compute_window([ev], window_start=W0, window_s=60, entity=E, cold_start=False)
    assert "http_5xx_ratio" not in fv.values          # absent, not 0.0
    assert fv.values["event_count"] == 1.0
```

### 2.2 Robust baseline with contamination guard (full)

```python
# src/lad/detection/statistical/baseline.py
from __future__ import annotations
from dataclasses import dataclass, field
import statistics as st

MAD_SCALE = 0.6745
DEFAULT_MIN_SAMPLES = 30
DEFAULT_HISTORY = 200

@dataclass
class BaselineState:
    key: str
    history: list[float] = field(default_factory=list)
    min_samples: int = DEFAULT_MIN_SAMPLES
    max_history: int = DEFAULT_HISTORY
    paused_updates: int = 0

    @property
    def cold_start(self) -> bool:
        return len(self.history) < self.min_samples

    def consider(self, x: float) -> "BaselineState":
        hist = (self.history + [x])[-self.max_history:]
        return BaselineState(self.key, hist, self.min_samples, self.max_history, self.paused_updates)

    def pause(self) -> "BaselineState":
        return BaselineState(self.key, list(self.history), self.min_samples,
                             self.max_history, self.paused_updates + 1)

    def robust_z(self, x: float) -> float | None:
        if self.cold_start:
            return None                                  # caller must skip
        med = st.median(self.history)
        mad = st.median([abs(h - med) for h in self.history])
        if mad == 0:
            return None                                  # degenerate; skip + log
        return MAD_SCALE * (x - med) / mad

    def median(self) -> float | None:
        return st.median(self.history) if not self.cold_start else None
```

```python
# src/lad/detection/statistical/detector.py
from __future__ import annotations
from lad.detection.base import AnomalyCandidate

# direction: +1 alerts only on high, -1 only on low, 0 two-sided
FEATURE_CONFIG = {
    "http_5xx_ratio":     {"direction": +1, "tau": 3.5},
    "auth_failure_rate":  {"direction": +1, "tau": 3.5},
    "db_timeout_rate":    {"direction": +1, "tau": 3.0},
    "latency_p95":        {"direction": +1, "tau": 3.0},
    "event_count":        {"direction": -1, "tau": 4.0},   # collapse = collector down
    "service_restart_frequency": {"direction": +1, "tau": 3.0},
}

class StatisticalBaselineDetector:
    name = "statistical_baseline"

    def __init__(self, repo, *, config=FEATURE_CONFIG):
        self.repo = repo
        self.config = config

    def score(self, fv) -> list[AnomalyCandidate]:
        out: list[AnomalyCandidate] = []
        for feature, cfg in self.config.items():
            x = fv.values.get(feature)
            if x is None:                                  # skip absent features
                continue
            if fv.sample_counts.get(feature, 0) < min_required(feature):
                continue                                   # minimum denominator
            state = self.repo.get_baseline(f"{fv.entity.key()}|{feature}")
            z = state.robust_z(x) if state else None
            if z is None:
                continue                                   # cold start / degenerate
            if cfg["direction"] > 0 and z > cfg["tau"]:
                out.append(self._candidate(fv, feature, x, state, z))
            elif cfg["direction"] < 0 and z < -cfg["tau"]:
                out.append(self._candidate(fv, feature, x, state, z))
            elif cfg["direction"] == 0 and abs(z) > cfg["tau"]:
                out.append(self._candidate(fv, feature, x, state, z))
        return out

    def update(self, fv, *, anomaly_active: bool):
        for feature, x in fv.values.items():
            if x is None: continue
            key = f"{fv.entity.key()}|{feature}"
            state = self.repo.get_baseline(key) or BaselineState(key)
            new = state.pause() if anomaly_active else state.consider(x)
            self.repo.put_baseline(key, new)               # durable BEFORE ack
```

**Walkthrough:**
- `robust_z` returns `None` for cold start and degenerate MAD, and the detector **skips** — never scores on nothing.
- `update` is called **after** the anomaly decision; when `anomaly_active`, it pauses (contamination guard) and records the pause.
- `put_baseline` is the durability point; it must complete before the queue ack.
- Directionality is per-feature config, so `event_count` can alert on *collapse* while `http_5xx_ratio` alerts on *spikes*.

### 2.3 Calibration harness (choose τ on validation, not test)

```python
# evaluation/calibrate.py
from dataclasses import dataclass

@dataclass
class CalibrationResult:
    tau: float
    precision: float
    recall: float
    false_alerts_per_hour: float

def calibrate(feature: str, val_windows, ground_truth, taus):
    results = []
    for tau in taus:
        tp = fp = fn = 0
        normal_hours = 0.0
        for w, truth in zip(val_windows, ground_truth):
            z = w.robust_z[feature]
            if z is None:
                continue
            predicted = z > tau
            if truth.is_anomaly:
                tp += int(predicted); fn += int(not predicted)
            else:
                normal_hours += w.window_s / 3600.0
                fp += int(predicted)
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        faph = fp / normal_hours if normal_hours else float("inf")
        results.append(CalibrationResult(tau, precision, recall, faph))
    return results

def choose_tau(results, *, target_faph=1.0):
    """Pick the tau meeting the FAPH budget with the best recall. Document the target."""
    eligible = [r for r in results if r.false_alerts_per_hour <= target_faph]
    return max(eligible, key=lambda r: r.recall) if eligible else min(results, key=lambda r: r.false_alerts_per_hour)
```

**Walkthrough:** sweep τ, compute precision/recall/FAPH, pick the τ that respects a **target false-alerts-per-hour budget** while maximizing recall. This encodes the operational reality (alert fatigue is costly) as a *calibration procedure*, and it happens on **validation** data — never the test set.

### 2.4 Correlation as a weighted graph with `min_link`

```python
# src/lad/correlate/graph.py
from dataclasses import dataclass, field
from datetime import timedelta

@dataclass
class Incident:
    incident_id: str
    candidates: list = field(default_factory=list)
    event_ids: set = field(default_factory=set)
    start: object = None
    last_evidence_ts: object = None
    representative: object = None

def link_strength(a, b, events_by_id) -> int:
    s = 0
    # strong: shared trace/request id
    if (a.trace_ids & b.trace_ids) or (a.request_ids & b.request_ids):
        s += 4
    if a.entity.host == b.entity.host and a.entity.service == b.entity.service:
        s += 2
    if known_dependency(a.entity, b.entity) or known_dependency(b.entity, a.entity):
        s += 2
    if compatible_categories(a, b):
        s += 1
    if ordering_consistent(a, b):
        s += 1
    return s

def correlate(candidates, events_by_id, *, window_s=120, quiet_s=600, min_link=3):
    candidates = sorted(candidates, key=lambda c: c.window_start)
    incidents: list[Incident] = []
    for c in candidates:
        best, best_link = None, 0
        for inc in incidents:
            within_window = c.window_start - inc.last_evidence_ts <= timedelta(seconds=window_s)
            within_quiet = c.window_start - inc.last_evidence_ts <= timedelta(seconds=quiet_s)
            if not within_quiet:
                continue
            link = link_strength(inc.representative, c, events_by_id)
            if within_window and link > best_link:
                best, best_link = inc, link
        if best is not None and best_link >= min_link:
            best.candidates.append(c)
            best.event_ids |= c.supporting_event_ids
            best.last_evidence_ts = c.window_start
        else:
            incidents.append(Incident(
                incident_id=new_incident_id(), candidates=[c],
                event_ids=set(c.supporting_event_ids),
                start=c.window_start, last_evidence_ts=c.window_start, representative=c))
    return incidents
```

**Walkthrough:** candidates merge only when `link >= min_link`, which **cannot** be satisfied by timestamp proximity alone (the max time-based contribution is small). `window_s` governs the merge span; `quiet_s` governs how long an incident stays "open" for late evidence. Unrelated same-minute anomalies produce separate incidents because their link scores stay below `min_link`.

### 2.5 Incident builder with deterministic explanation

```python
# src/lad/incidents/build.py
EXPLANATION_TEMPLATE = """\
Incident {incident_id}: {severity} — {summary}
  Entity:      {entity}
  Window:      {window_start} → {window_end} UTC
  Detector:    {detector} (score {anomaly_score:.3f})
  Observed vs baseline:
{obs_lines}
  Supporting events: {n_support}
  Contradicting:     {n_contra}
  Missing evidence:  {missing}
  Hypotheses:
{hypo_lines}
  Recommended diagnostics (non-executing):
{check_lines}
"""

def build_incident(inc: Incident, *, score, detector, model_versions, hypotheses,
                   diagnostic_checks, severity_rule) -> dict:
    stmt = severity_rule(inc)                        # documented rule function
    obs_lines = "\n".join(
        f"    - {c.feature}: observed {c.observed} vs baseline {c.baseline} (robust z={c.score:.2f})"
        for c in inc.candidates)
    summary = deterministic_summary(inc)             # template, not generation
    return {
        "incident_id": inc.incident_id,
        "status": "open",
        "severity": stmt,
        "anomaly_score": score,                       # NOT a probability
        "detector": detector,
        "model_versions": model_versions,
        "affected_entities": [vars(inc.representative.entity)],
        "evidence": {"supporting_event_ids": sorted(inc.event_ids),
                     "contradicting_event_ids": [], "redacted_refs": []},
        "hypotheses": hypotheses,                     # each cites support/contradict/missing
        "diagnostic_checks": diagnostic_checks,       # each {"executes": False, ...}
        "explanation": EXPLANATION_TEMPLATE.format(...),
        "audit": [],
    }
```

**Walkthrough:** severity comes from a documented rule function (not derivable from the score); the explanation is a **template over structured fields**; hypotheses and checks are passed in already evidence-linked. Nothing here generates free text — determinism is preserved end to end.

### 2.6 Evaluation with a documented matching rule

```python
# evaluation/metrics.py
def match_incidents(predicted, truth, *, horizon_s=120):
    """A predicted incident matches truth if it overlaps the true anomaly window
    on the same entity and is created within `horizon_s` of anomaly start.
    Document this rule wherever metrics are reported."""
    tp = fp = fn = 0
    matched_truth = set()
    for p in predicted:
        hit = None
        for t in truth:
            if (p.entity.host == t.entity.host
                and p.start <= t.end and p.start >= t.start - timedelta(seconds=horizon_s)):
                hit = t; break
        if hit and hit.id not in matched_truth:
            tp += 1; matched_truth.add(hit.id)
        else:
            fp += 1
    fn = len([t for t in truth if t.id not in matched_truth])
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall    = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2*precision*recall/(precision+recall) if precision+recall else 0.0
    return {"tp": tp, "fp": fp, "fn": fn,
            "precision": precision, "recall": recall, "f1": f1}
```

**Walkthrough:** metrics are meaningless without a matching rule. Here it's explicit and testable. We also always report the **counts** and the **denominator**, never accuracy alone (imbalanced detection makes accuracy a lie).

---

## 3. Common Pitfalls & Debugging

### 3.1 Fabricating zeros for missing data

The cardinal sin. `http_5xx_ratio = 0.0` for a source that never sends HTTP poisons the baseline and creates false "recoveries." **Fix:** `None` + skip; test with non-HTTP fixtures.

### 3.2 Mean/σ baselines on heavy-tailed data

One big outlier inflates σ and masks the next anomaly. **Fix:** median/MAD; verify with a test where an outlier is injected and a subsequent anomaly still alerts.

### 3.3 Cold start treated as "no anomalies = working"

After install, there's a learning period. If the demo starts immediately, it looks broken. **Fix:** surface `cold_start`/`warming up` in the API and UI; document the warmup; seed history for the demo with fixed-seed normal traffic (labeled synthetic).

### 3.4 Contamination (learning the attack)

Updating the baseline during an active anomaly turns the attack into the new normal. **Fix:** pause updates on anomaly; robust updates; drift caps; **test** that a 10-window anomaly barely moves the baseline.

### 3.5 Too-small windows → unstable ratios

`latency_p95` on 3 samples is noise. **Fix:** minimum-sample gates; use larger windows for percentiles; if insufficient, `None`.

### 3.6 Double counting across overlapping windows

Summing counts over sliding windows inflates volume. **Fix:** persist tumbling-window aggregates; derive sliding views carefully; never sum overlapping windows.

### 3.7 Timezone/alignment drift

Workers that align windows using local time will disagree at DST or across timezones, producing duplicate/missing windows. **Fix:** align in UTC to epoch boundaries; test with a worker "restart."

### 3.8 Threshold tuned on the test set

The fastest way to fake good numbers, and it's a correctness violation. **Fix:** calibrate only on validation; keep the test set untouched; record the chosen τ and calibration set in the report.

### 3.9 Correlation false merges

Merging unrelated anomalies because they're nearby in time. **Fix:** require `min_link` evidence beyond time; test scenario 4 (unrelated simultaneous anomalies stay separate). And the inverse — missed links — test scenario 3 (DB timeout + 5xx share a trace → one incident).

### 3.10 Called the score a probability

Presenting `0.93` as "93% likely an anomaly" is a factual error. **Fix:** label it "anomaly score (detector-specific)"; never claim calibrated probability unless you actually calibrate one (and you don't, for the robust z).

### 3.11 Debugging toolkit

```bash
# replay a scenario through the pipeline and dump candidates
python -m lad.eval.run --scenario db_then_5xx --dump-candidates

# inspect a specific entity's baseline history
python -m lad.tools.baseline --entity "host-alpha|svc-pay|app-nginx|-" --feature http_5xx_ratio

# plot (export CSV, view externally)
python -m lad.tools.export_windows --scenario normal --out /tmp/normal.csv
```

- **Snapshot tests** for feature vectors on fixtures — catch accidental changes to feature semantics.
- **A "normal traffic" regression test** asserting **zero** incidents — the single best guard against threshold regressions.
- **Deterministic seeds** in all generators; a metric without a seed is not reproducible.

---

## 4. Curated Resources

### 4.1 Books (with chapter guidance)

- **"Forecasting: Principles and Practice" — Hyndman & Athanasopoulos (free online at otexts.com/fpp3).**
  - Ch. 2 *Time series graphics*, Ch. 3 *Transformations* (why heavy tails need transforms), Ch. 8 *Exponential smoothing* (EWMA and its α), Ch. 12 *Time-series regression* (time-of-day features).
- **"Robust Statistics" — Peter Huber & Elvezio Ronchetti.** The canonical source for median/MAD, influence functions, and why robust estimators behave under contamination. Read the chapters on *location* and *scale*.
- **"Time Series Analysis" — James D. Hamilton.** The rigorous treatment of stationary series, autocorrelation, and differencing, for when rolling windows aren't enough.
- **"Anomaly Detection: A Survey" — Chandola, Banerjee, Kumar (ACM Computing Surveys 2009).** The taxonomy; read the *statistical* and *evaluation* sections.
- **"NIST/SEMATECH e-Handbook of Statistical Methods" (free online).** The "Measures of Scale" and "Detection of Outliers" sections are practical and authoritative.
- **"Practical Statistics for Data Scientists" — Bruce, Bruce & Gedeck.** Ch. on *Resampling* and *Robust estimates* — the pragmatic middle ground.
- **"Observability Engineering" — Majors, Fong-Jones, Miranda.** Why per-entity, high-cardinality analysis beats averages (the "average hides the fire" point).

### 4.2 Papers

- **Chandola et al., "Anomaly Detection: A Survey" (2009).** Start here.
- **"Sequential Probability Ratio Test" (Wald, 1945)** — the classic for deciding "has a change occurred?" with a false-positive budget; underlies persistence/hysteresis thinking.
- **"A Survey on Automated Log Analysis for Reliability Engineering" (He et al., 2021).** Ties log features (templates, counts) to detection.
- **PELT / changepoint detection (Killick et al., 2012)** — for collective anomalies and ramps (future work).
- **"Robust Statistics: A Survey" (various)** — for the median/MAD foundations.

### 4.3 Videos, talks, courses

- **Rob Hyndman — "Forecasting" lecture series (YouTube).** Excellent on ETS/EWMA intuition.
- **StatQuest (Josh Starmer) — "Robust Statistics", "Quantiles and Percentiles", "Boxplots".** Fast, clear foundations.
- **"The Mathematics of Machine Learning" — any rigorous intro course** for the probability under the hood.
- **Google SRE book talks on *Alerting on SLOs*** — the *why* behind false-alert budgets and burn rates.
- **Honeycomb / Charity Majors talks on high-cardinality observability** — the operational case for per-entity detection.

### 4.4 Exercises to internalize this module

1. Implement `compute_window` and prove non-HTTP sources yield no HTTP features.
2. Implement the robust baseline; write tests for cold start, degenerate MAD, and the contamination guard (10-window anomaly moves the baseline < ε).
3. Build the calibration harness and pick τ for `http_5xx_ratio` under a 1 FAPH budget on a validation scenario.
4. Implement correlation with `min_link`; prove scenario 3 merges and scenario 4 stays separate, including a late-arriving-event case.
5. Implement the metric harness with a documented matching rule; produce a report with counts and denominators, plus seeds and parameters.
6. Write the "normal scenario → zero incidents" regression test.

---

*Next module:* **[Module 5 — Isolation Forest & Rigorous ML Evaluation](learning_module_5.md)** — using a tree ensemble honestly, and the discipline that keeps a detector's claims real.

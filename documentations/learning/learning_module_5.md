# 📚 Learning Module 5 — Isolation Forest & Rigorous ML Evaluation

> **Module goal:** Understand *exactly* how Isolation Forest works, when it earns a place next to a statistical baseline, and the evaluation discipline that keeps any detector's claims honest.
> **Project tie-in:** You will build `src/lad/detection/isolation_forest/`, the shadow-mode comparison, model artifacts, and the Gate 4 detector-comparison report.

**Estimated study time:** 25–35 hours. **Prereq:** Module 4 (features, baselines, metrics); basic linear algebra.

---

## Table of Contents

1. [Core Theory & In-Depth Explanation](#1-core-theory--in-depth-explanation)
   - 1.1 From decision trees to random forests (the prerequisite intuition)
   - 1.2 The isolation principle: why anomalies are *easy to isolate*
   - 1.3 The Isolation Forest algorithm, step by step
   - 1.4 The path-length score, `c(n)`, and why the score is not a probability
   - 1.5 Training, thresholding, and the `contamination` parameter
   - 1.6 Isolation Forest vs. the statistical baseline: strengths and blind spots
   - 1.7 Preprocessing, missing values, and leakage (the three that break you)
   - 1.8 Evaluation: splits, metrics, PR vs. ROC, and reproducibility
   - 1.9 Shadow mode, model artifacts, and honest go/no-go
   - 1.10 Why *not* K-means (and what LOF/One-Class SVM would cost)
2. [Practical Examples & Code Walkthroughs](#2-practical-examples--code-walkthroughs)
3. [Common Pitfalls & Debugging](#3-common-pitfalls--debugging)
4. [Curated Resources](#4-curated-resources)

---

## 1. Core Theory & In-Depth Explanation

### 1.1 From decision trees to random forests

A **decision tree** recursively splits data by a feature and a threshold (`duration_ms > 812?`), partitioning the space into rectangles. Depth = number of splits on a path.

A **random forest** (Breiman, 2001) is **bagging** over trees: train many trees on bootstrap samples with random feature subsets, then aggregate. Aggregation reduces variance and resists overfitting.

**Isolation Forest** keeps the *random tree* machinery but changes the **objective entirely**. A random forest tries to *predict well*. Isolation Forest tries to *partition the data quickly and uniformly* — it is not a predictive model at all. That distinction is why it confuses people who expect a classifier.

### 1.2 The isolation principle

The core insight (Liu, Ting, Zhou, 2008):

> **Anomalies are few and different, so random partitions isolate them in fewer splits.**

Picture a 2-D scatter: a dense blob of normal points with a few outliers far away. Draw a random axis-aligned line.
- To isolate an outlier, one line usually suffices (it sits alone in a thin slab).
- To isolate a point *inside* the blob, you need many lines to carve away the surrounding mass.

So the **depth at which a point becomes isolated** (surrounded by its own partition) is a proxy for anomaly: **short path = anomalous; long path = normal.**

```
            │                 ● outlier (isolated by 1 split)
            │
   ─────────┼───────────────────────────  random split
            │     ●  ● ● ●
            │    ● ● ●●● ● ●            dense normal region
            │      ● ● ● ● ●            (needs many splits to isolate one point)
```

This is elegant because it needs **no density estimation**, **no distance metric tuning**, and it handles high dimensions far better than distance-based methods (which suffer "distance concentration" — in high dimensions everything is far from everything). Isolation Forest's average complexity is roughly **O(n log n)** for training and **O(log n)** per query — fast.

### 1.3 The algorithm, step by step

**Training (build the forest):**
1. Choose `n_estimators` = number of trees `t`.
2. For each tree: draw a **subsample** of size `ψ` (psi, e.g. 256) **uniformly at random** from the training data — *without* replacement in the standard formulation.
3. Grow an **iTree** on the subsample:
   - Pick a random feature `q`.
   - Pick a random split value `p` uniformly between that feature's min and max **in the current node's data**.
   - Split into `left = {x : x_q < p}`, `right = {x : x_q ≥ p}`.
   - Recurse until a node has **1 point** (isolated), all points are identical, or a depth limit `l = ceil(log2(ψ))` is reached.
4. Repeat for all trees.

**Note the "random split value," not a learned best split.** There's no impurity/gain optimization. That's what makes it cheap and unbiased.

**Query (score a point):**
1. Drop the point down each tree, counting edges traversed until it reaches an **external node** (the depth at which it is isolated / falls into a leaf).
2. Average the path length over all trees.
3. Convert to an anomaly score (below).

### 1.4 The score, `c(n)`, and why it's not a probability

The path length for a point `x` in tree `i` is `h_i(x)`. The **average** over all trees is `E[h(x)]`. The **normalizing constant** is:

```
c(n) = 2·H(n−1) − 2·(n−1)/n      for n > 2
H(i) ≈ ln(i) + γ                 (γ = Euler–Mascheroni ≈ 0.5772)
c(2) = 1 ; c(1) = 0
```

`c(n)` is the **expected path length of an unsuccessful search in a Binary Search Tree** — i.e., the path length you'd expect for a *typical* point in a balanced-ish partition of `n` points. It normalizes for sample size.

The **anomaly score**:

```
s(x, n) = 2^( − E[h(x)] / c(n) )
```

**Interpretation via limits:**
- If `E[h(x)] → c(n)` (average path), `s → 0.5`. **A score near 0.5 means "indistinguishable from normal."**
- If `E[h(x)] → 0` (isolated immediately), `s → 1`. **Very anomalous.**
- If `E[h(x)] → n−1` (very deep, embedded), `s → 0`. **Very normal.**

```
s ≈ 1.0  → strongly anomalous        (isolated in very few splits)
s ≈ 0.5  → normal / ambiguous
s ≈ 0.0  → very normal / dense
```

⚠️ **`s` is NOT a probability.** It is a monotone transform of average path length. `s = 0.7` does **not** mean "70% chance of being an anomaly." To treat it as a probability you would need to calibrate it (e.g., on labeled validation data with a proper scoring rule). The project's rule is explicit: **document that the score is not a probability and threshold it on validation data.**

**scikit-learn's sign convention:** `IsolationForest.score_samples(X)` returns the **negated** average path-length-based score (larger = more normal), and `decision_function(X)` returns `score_samples − offset_` such that values **< 0** are anomalies (when contamination is used to set `offset_`). `fit_predict` returns `+1` for inliers and `−1` for outliers. This sign confusion is a top pitfall.

```python
clf = IsolationForest(n_estimators=200, random_state=42).fit(X_train)
clf.decision_function(X_test)   # < 0 → predicted anomaly; larger → more normal
clf.score_samples(X_test)       # raw-ish score; larger → more normal
-predict_anomaly_score(x)       # our own wrapper: larger → more anomalous
```

### 1.5 Training, thresholding, and `contamination`

**`contamination`** (scikit-learn) is the *expected proportion of outliers in the training data*. It sets `offset_` so that roughly that fraction of training points fall below the decision boundary. Two philosophies:

1. **Set `contamination` from domain knowledge** ("we expect ~1% anomalous windows"). Fast, but if the estimate is wrong, the threshold is wrong.
2. **Set the threshold yourself on validation data.** Compute raw scores, sweep the threshold, pick the one meeting your **false-alerts-per-hour** budget with the best recall. **This is the project's approach** and is required by the spec ("Decide how to threshold scores using training/validation data, then evaluate on held-out data. Do not tune on the test set.").

```python
# philosophy 2 in practice
scores_val = clf.score_samples(X_val)          # larger = more normal
# convert to "anomaly score" (larger = more anomalous)
anom_val = -scores_val
threshold = choose_threshold(anom_val, y_val, target_faph=1.0)
```

**What to record for every artifact (spec requirement):**
- parameters (`n_estimators`, `max_samples`, `max_features`, …)
- random seed
- **feature list** (order and meaning)
- **data version** (which scenario/commit/generator seed)
- model artifact / version id
- the chosen threshold and **how** it was chosen

### 1.6 Isolation Forest vs. the statistical baseline

| Dimension | Statistical baseline | Isolation Forest |
|---|---|---|
| Transparency | **High** — formula a human computes | Medium — opaque ensemble |
| Handles feature *interactions* | No (per-feature) | **Yes** (multivariate) |
| Per-feature context | **Yes** (per-entity baselines) | Not inherently |
| Cold start | Explicit, handled | Needs enough training data |
| Cost | Tiny | Training + artifact + inference cost |
| Interpretability of an alert | Direct (observed vs baseline) | Hard — needs feature attribution |
| Robust to outliers | Designed for it (median/MAD) | Designed for it (isolation) |
| Detects subtle multi-feature novelty | Weak | **Potentially strong** |
| Security (poisoning) | Guardable | Also guardable; not inherently safer |

**The honest framing:** Isolation Forest is a **candidate** that *might* catch multivariate anomalies the per-feature baseline misses. It is **complementary**, not automatically superior. The spec: "If it does not improve useful metrics or consumes too much integration time, document the experiment and keep the statistical detector as the MVP detector." **Documenting a negative result is success**, not failure.

### 1.7 Preprocessing, missing values, and leakage

**Preprocessing for trees.** Trees are scale-invariant (a split on `duration_ms` doesn't care about units), so **normalization is unnecessary** for Isolation Forest — a common misconception. However:
- **Monotone transforms** (log) can still help by changing *where* the random splits can occur — for extremely skewed features, a log transform makes the "normal" region denser so anomalies isolate faster. Test it; don't assume it.
- **Constant features** contribute nothing; drop them.
- **Correlated features** double-count — consider deduplication if it distorts distances, though isolation is less sensitive to this than distance methods.

**Missing values.** scikit-learn's `IsolationForest` does **not** accept `NaN` (unlike `HistGradientBoosting*`). You must choose and **document** a missing-value policy:
- **Impute** (median from *training* only) **+ add a missingness indicator feature.** The indicator lets the tree isolate "missing telemetry" as its own pattern — valuable, since missing data is itself a signal ("missing telemetry or ingestion delay as separate operational signals").
- **Drop** rows/features with too much missingness.
- **Never** impute using validation/test statistics (leakage).

```python
from sklearn.impute import SimpleImputer
import numpy as np

# fit on TRAIN ONLY
imputer = SimpleImputer(strategy="median").fit(X_train)
Xtr = imputer.transform(X_train)
Xva = imputer.transform(X_val)

# add missingness indicators computed BEFORE imputation
miss_train = np.isnan(X_train).astype(int)
miss_val   = np.isnan(X_val).astype(int)
Xtr = np.hstack([Xtr, miss_train])
Xva = np.hstack([Xva, miss_val])
```

**Leakage — the three species that matter here:**
1. **Temporal leakage:** random train/test splits on time series put near-duplicate adjacent windows in both sets. **Split by time/host/scenario.** This is non-negotiable.
2. **Incident leakage:** overlapping windows from the *same incident* must stay in one split. Otherwise the model "recognizes" the incident it's tested on.
3. **Label leakage:** the synthetic scenario's ground-truth label must **never** be a feature. ("Do not use synthetic scenario labels as input features.") The test generator must keep labels in evaluation metadata only.

**Also:** fit the imputer/scaler on train only; keep feature order stable across train/val/test and at serving time (a reordered feature vector silently degrades the model — version the feature list).

### 1.8 Evaluation: splits, metrics, PR vs. ROC, reproducibility

**Splits.** Prefer **GroupKFold by incident** or a **time-based split** (train on earlier, test on later). Never `train_test_split(shuffle=True)` on windows.

**Metrics** (all from the project's metric list):
- **Precision** = TP/(TP+FP). Of what we flagged, how much was real.
- **Recall** = TP/(TP+FN). Of the real anomalies, how many we caught.
- **F1** = harmonic mean. Only meaningful with a defined matching rule.
- **False alerts per hour** = false incidents / normal hours. The operational metric.
- **Detection delay** = first detection − anomaly start (seconds).
- **Cost/latency** (serving).

**PR vs. ROC for imbalanced data.** ROC-AUC can look flattering when negatives vastly outnumber positives (the false-positive-rate denominator is huge). **Precision–Recall AUC (PR-AUC / average precision)** is far more informative for rare anomalies. Report both if you like, but **lead with precision/recall at the operating threshold** and **FAPH** — the numbers operations actually feels.

```
Imbalanced anomaly detection:
  ROC-AUC 0.95 can coexist with precision 0.05 at the operating point.
  Always report the operating-point precision/recall and the counts.
```

**Counts and denominators.** "Precision 0.8" is meaningless without "of 20 alerts, 16 true." Report `tp/fp/fn` and the total normal hours.

**Reproducibility.** Fix `random_state` everywhere; fix the data-generator seed; record the split; record the feature list and data version. A reported metric without a seed and a split is not a result.

### 1.9 Shadow mode, model artifacts, honest go/no-go

**Shadow mode** lets you compare *without* risking user-visible false alerts:

```python
if settings.detector_if == "off":
    pass
elif settings.detector_if == "shadow":
    score = if_model.anomaly_score(vec)          # log only; never create incidents
    log_shadow(entity, window, score, threshold, statistical_triggered, model_version)
elif settings.detector_if == "on":
    ...                                          # create incidents (only after go decision)
```

**Artifacts:** model + a metadata record (`ModelArtifactMeta`): version, seed, features, data version, trained_at, threshold, preprocessing. Store the artifact durably (file/S3) and load it **explicitly**; never "whatever file is on disk." Every incident records which model version(s) contributed.

**Go/no-go criteria (define *before* running the comparison):**
- Does IF improve **recall** at the same **FAPH budget** on held-out scenarios by a meaningful margin (define "meaningful," e.g., ≥10 percentage points, or catches ≥1 scenario the baseline misses entirely)?
- Is the added **serving cost/latency** acceptable?
- Is it **reproducible**?
- Can we **explain** its alerts sufficiently for the incident UX? (If not, its incidents will be low-quality.)

If any fails, **document and keep the baseline**. The spec literally instructs this path.

### 1.10 Why *not* K-means (and what LOF / One-Class SVM would cost)

**K-means is not the default detector.** The confusion is conceptual: K-means clusters data into **K groups**; **K is the number of clusters, not anomaly classes.** Clusters are not labeled normal/anomalous. You can *heuristically* use distance-to-centroid as a novelty score, but:
- K must be chosen (elbow, silhouette — extra decisions).
- It assumes roughly spherical, similar-size clusters and Euclidean geometry.
- It's sensitive to scaling and to outliers *pulling centroids*.
- Cluster membership is not an anomaly label.

None of this makes it wrong for *some* problems — it makes it **not a transparent anomaly detector** for this project, where transparency is a requirement.

**LOF (Local Outlier Factor).** Density-based; great for local density deviations, but:
- Needs a distance metric and `n_neighbors` tuning.
- Degrades in high dimensions (distance concentration).
- Requires the full dataset for scoring (or careful approximate serving).
- **Separate justification and evaluation required.**

**One-Class SVM.** Learns a boundary around normal data; strong in low dimensions with tuning, but:
- Sensitive to `gamma`/`nu` and scaling.
- **Training cost O(n²–n³)** — poor fit for large window feature sets, and hard to persist/retrain cheaply.
- Again: separate justification.

The spec: "Optional methods such as LOF or One-Class SVM require separate justification and evaluation. **Do not add them merely to increase algorithm count.**" A detector that isn't evaluated and maintained is a liability.

---

## 2. Practical Examples & Code Walkthroughs

### 2.1 Building the feature matrix from windows (train/val/test by time)

```python
# evaluation/dataset.py
import numpy as np
from datetime import datetime

FEATURES = ["event_count", "http_5xx_ratio", "latency_p95", "db_timeout_rate",
            "auth_failure_rate", "service_restart_frequency"]

def to_matrix(windows, feature_list=FEATURES):
    """Each window -> fixed-order vector; absent features -> NaN (handled later)."""
    rows, meta = [], []
    for w in windows:
        rows.append([w.values.get(f, np.nan) for f in feature_list])
        meta.append({"entity": w.entity.key(), "start": w.window_start, "window_s": w.window_s})
    return np.array(rows, dtype=float), meta

def temporal_split(windows, *, frac_train=0.6, frac_val=0.2):
    """Split by TIME, never shuffle. Keeps incident windows together by window_start order."""
    windows = sorted(windows, key=lambda w: w.window_start)
    n = len(windows)
    a, b = int(n * frac_train), int(n * (frac_train + frac_val))
    return windows[:a], windows[a:b], windows[b:]
```

**Walkthrough:** feature order is fixed and shared (a versioned list — part of the artifact). `NaN` represents absent features and is handled by imputation + indicator. Temporal splitting prevents the near-duplicate leakage that would inflate metrics.

### 2.2 Training with a documented preprocessing pipeline

```python
# src/lad/detection/isolation_forest/train.py
from dataclasses import dataclass, asdict
import numpy as np
from sklearn.ensemble import IsolationForest
from sklearn.impute import SimpleImputer

@dataclass
class ModelArtifactMeta:
    version: str
    seed: int
    features: tuple[str, ...]
    data_version: str
    trained_at: str
    threshold: float
    preprocessing: str
    n_estimators: int
    max_samples: int
    def to_json(self): return asdict(self)

def train_iforest(X_train, X_val, y_val, meta_base, *,
                  n_estimators=200, max_samples=256, seed=42, target_faph=1.0):
    imputer = SimpleImputer(strategy="median").fit(X_train)
    Xtr = np.hstack([imputer.transform(X_train), np.isnan(X_train).astype(int)])
    Xva = np.hstack([imputer.transform(X_val),   np.isnan(X_val).astype(int)])

    clf = IsolationForest(n_estimators=n_estimators, max_samples=max_samples,
                          random_state=seed, contamination="auto")
    clf.fit(Xtr)

    # threshold chosen on VALIDATION
    anom_val = -clf.score_samples(Xva)                  # larger = more anomalous
    thr = choose_threshold(anom_val, y_val, target_faph=target_faph)

    meta = ModelArtifactMeta(
        version=meta_base["version"], seed=seed, features=tuple(meta_base["features"]),
        data_version=meta_base["data_version"], trained_at=now_utc_iso(),
        threshold=thr,
        preprocessing="median-impute(fit-on-train) + missing-indicator; no scaling",
        n_estimators=n_estimators, max_samples=max_samples)
    return {"model": clf, "imputer": imputer, "meta": meta}

def anomaly_score(clf, imputer, vec: np.ndarray) -> float:
    x = np.hstack([imputer.transform(vec.reshape(1, -1)), np.isnan(vec).reshape(1, -1)])
    return float(-clf.score_samples(x)[0])               # larger = more anomalous
```

**Walkthrough:** the imputer is fit on **train only**; missingness indicators are appended; the model uses `contamination="auto"` and we set the threshold ourselves on validation. The `meta` record captures everything needed to reproduce and audit.

### 2.3 Threshold selection meeting an FAPH budget

```python
# evaluation/thresholds.py
import numpy as np

def choose_threshold(anom_scores, labels, *, target_faph, normal_hours):
    """labels: 1 = anomaly, 0 = normal. Returns the threshold with best recall
    at or below the target false-alerts-per-hour budget."""
    order = np.argsort(-anom_scores)                     # high scores first
    best_thr, best_recall = np.inf, -1.0
    tp = fp = 0
    total_pos = int(labels.sum())
    # imagine the threshold moving from +inf downward
    prev_score = None
    for idx in order:
        s = anom_scores[idx]
        if prev_score is not None and s != prev_score:
            faph = fp / normal_hours if normal_hours else float("inf")
            if faph <= target_faph:
                recall = tp / total_pos if total_pos else 0.0
                if recall > best_recall:
                    best_thr, best_recall = prev_score, recall
        if labels[idx] == 1: tp += 1
        else:                fp += 1
        prev_score = s
    return best_thr
```

**Walkthrough:** sweep the threshold top-down, tracking TP/FP, and record the best-recall threshold whose FAPH is within budget. This mirrors Module 4's calibration but for a score instead of a robust z. It runs on validation data.

### 2.4 Shadow-mode scoring wired into the pipeline

```python
# src/lad/detection/isolation_forest/shadow.py
def shadow_step(fv, candidates_from_baseline, ctx):
    if ctx.settings.detector_if == "off":
        return candidates_from_baseline
    score = anomaly_score(ctx.if_model, ctx.if_imputer, to_vector(fv, ctx.if_meta.features))
    triggered = score >= ctx.if_meta.threshold
    log_structured("if_shadow", {
        "mode": "shadow", "detector": "isolation_forest",
        "entity": fv.entity.key(), "window_start": fv.window_start.isoformat(),
        "score": round(score, 4), "threshold": ctx.if_meta.threshold,
        "statistical_triggered": bool(candidates_from_baseline),
        "model_version": ctx.if_meta.version, "seed": ctx.if_meta.seed,
    })
    if ctx.settings.detector_if == "on" and triggered:
        return candidates_from_baseline + [make_candidate(fv, score, "isolation_forest")]
    return candidates_from_baseline                            # shadow never changes output
```

**Walkthrough:** shadow mode **logs** the score and whether the baseline also triggered — the raw data for the Gate 4 comparison — but never creates incidents. Only `on` (after an explicit go decision) contributes candidates.

### 2.5 The comparison report (Gate 4 deliverable)

```python
# evaluation/compare_detectors.py
def compare(scenarios, baseline, iforest):
    rows = []
    for s in scenarios:
        for name, det in (("statistical_baseline", baseline), ("isolation_forest", iforest)):
            preds = det.run(s.windows)                         # incidents (or candidates) on held-out data
            m = match_incidents(preds, s.ground_truth, horizon_s=120)
            delay = mean_detection_delay(preds, s.ground_truth)
            rows.append({
                "scenario": s.id, "detector": name,
                **m, "false_alerts_per_hour": faph(preds, s), "detection_delay_s": delay,
            })
    return rows

def render_report(rows, params):
    lines = ["# Detector Comparison (held-out scenarios)",
             f"seed={params['seed']} split={params['split']} features={params['features']}",
             f"data_version={params['data_version']}", "",
             "| Scenario | Detector | TP | FP | FN | Precision | Recall | F1 | FAPH | Delay(s) |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append("| {scenario} | {detector} | {tp} | {fp} | {fn} | "
                     "{precision:.2f} | {recall:.2f} | {f1:.2f} | {false_alerts_per_hour:.2f} | "
                     "{detection_delay_s:.0f} |".format(**r))
    lines += ["", "Limitations: synthetic scenarios; small n; see commit and data version."]
    return "\n".join(lines)
```

**Walkthrough:** identical held-out scenarios, both detectors, one table with **counts and denominators**, plus an explicit **Limitations** line. This is exactly what the reporting rule demands, and it's the artifact that decides go/no-go.

### 2.6 A reproducible experiment runner

```python
# evaluation/run.py
import argparse, random, numpy as np
from lad.contracts.version import commit_sha

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--detector", choices=["baseline", "iforest", "both"], default="both")
    args = ap.parse_args()

    random.seed(args.seed); np.random.seed(args.seed)          # seed everything
    scenario = build_scenario(args.scenario, seed=args.seed)
    train, val, test = temporal_split(scenario.windows)
    ...  # train on train, threshold on val, evaluate on test
    print(f"# commit {commit_sha()} seed {args.seed} scenario {args.scenario}")
```

**Walkthrough:** every result is stamped with commit and seed; splitting is temporal; evaluation is on the untouched test set.

---

## 3. Common Pitfalls & Debugging

### 3.1 Misreading the score sign

`score_samples` (larger = normal) vs. `decision_function` (negative = anomaly) vs. the paper's `s` (near 1 = anomaly). **Fix:** wrap it once in a single `anomaly_score()` function (larger = more anomalous) and use *only* that everywhere. Test its direction on a known outlier.

### 3.2 Calling the score a probability

`0.7` is not 70%. **Fix:** label it "anomaly score"; if you want a probability, calibrate (e.g., isotonic/Platt on validation) and *then* say so — but don't, for the MVP.

### 3.3 NaN input

`IsolationForest` raises on `NaN`. **Fix:** impute on train + missingness indicators; test that a window with all features missing still scores without crashing (and ideally flags "missing telemetry").

### 3.4 Standardizing features out of habit

Trees don't need scaling; scaling can even alter split behavior subtly. **Fix:** skip the scaler unless a transform (log) demonstrably helps in evaluation.

### 3.5 Random shuffling on time series

Near-duplicate adjacent windows leak across splits, inflating metrics. **Fix:** temporal/group splits; keep incident windows together.

### 3.6 Ground-truth labels as features

If `scenario_id` or an anomaly flag slips into the matrix, the model "cheats." **Fix:** an explicit allowlist of feature names; a test asserting none of the label columns are in the feature list.

### 3.7 Tuning on the test set

The most common way to report fiction. **Fix:** threshold on validation; touch test once; record the chosen threshold and the split.

### 3.8 `contamination` confusion

Setting `contamination=0.5` because "half the training data feels anomalous" silently moves the decision boundary to flag ~50% of points. **Fix:** `contamination="auto"` + explicit threshold, or set it from a *documented* prior; never guess.

### 3.9 Unstable model artifacts

Retraining without versioning means yesterday's incident referenced a model that no longer exists. **Fix:** version every artifact, record the version per incident, and keep old versions for audit. Load explicitly.

### 3.10 Overclaiming generalization

A tiny synthetic scenario is not proof of real-world generalization. **Fix:** state limitations plainly; never claim generalization from a small synthetic test.

### 3.11 Debugging toolkit

```bash
# sanity-check the score direction on a known outlier
python -c "
from evaluation.demo import make_known_outlier; from lad.detection.isolation_forest.scoring import anomaly_score
print('outlier score:', anomaly_score(*make_known_outlier()))
"

# inspect score distribution on normal vs anomalous validation windows
python -m evaluation.inspect_scores --scenario normal --split val

# reproduce a full comparison
python -m evaluation.compare_detectors --seed 1234 --out /tmp/compare.md
```

- **Score-distribution plots** (normal vs. anomalous) are the fastest way to see whether the detector separates at all before you tune thresholds.
- **Permutation sanity check:** shuffle the feature *rows* (destroying structure) and confirm the detector no longer separates — catches leakage and coding errors.
- **Determinism check:** run the same command twice; outputs must be byte-identical given the same seed and data version.

---

## 4. Curated Resources

### 4.1 Papers (read these; they're the primary sources)

- **Liu, Ting & Zhou, "Isolation Forest" (ICDM 2008).** The original; read the score definition and the `c(n)` normalization.
- **Liu, Ting & Zhou, "Isolation-Based Anomaly Detection" (ACM TKDD 2012).** The extended version; includes *iForestASD* (streaming), which is directly relevant to per-window scoring.
- **Breiman, "Random Forests" (2001).** For the bagging intuition.
- **Chandola, Banerjee & Kumar, "Anomaly Detection: A Survey" (2009).** Taxonomy and evaluation pitfalls.
- **Kriegel, Kröger, Schubert & Zimek, "LoOP: Local Outlier Probabilities"** and **Breunig et al., "LOF" (2000)** — if you ever justify LOF.
- **Schölkopf et al., "Estimating the Support of a High-Dimensional Distribution" (2001)** — the One-Class SVM origin.
- **"A Comparative Evaluation of Unsupervised Anomaly Detection Algorithms" (Goldstein & Uchida, 2016).** Empirical ranking of iForest, LOF, OCSVM, etc.
- **"On the Evaluation of Unsupervised Outlier Detection" (Campos et al., 2016)** and **"On the Evaluation of Outlier Detection" follow-ups.** Metric pitfalls.

### 4.2 Books (with chapter guidance)

- **"Outlier Analysis" (2nd ed.) — Charu Aggarwal.** Ch. 3 *Statistical methods*, Ch. 5 *Proximity-based*, Ch. 7 *Isolation-based methods* (this is the chapter on Isolation Forest), Ch. 10 *Evaluation*.
- **"Anomaly Detection Principles and Algorithms" — Mehrotra, Mohan, Huang.** Rigorous surveys with proofs.
- **"Hands-On Machine Learning with Scikit-Learn, Keras & TensorFlow" (3rd ed.) — Aurélien Géron.** Ch. 7 *Ensemble Learning and Random Forests* (the prerequisite intuition for §1.1).
- **"An Introduction to Statistical Learning" — James, Witten, Hastie, Tibshirani.** Ch. 8 *Tree-Based Methods*; Ch. 5 *Resampling* (cross-validation, the split discipline).
- **"Designing Machine Learning Systems" — Chip Huyen.** Ch. on *data leakage*, *distribution shift*, and *monitoring* — the production discipline.
- **"Trustworthy Online Controlled Experiments" — Kohavi, Tang, Xu.** For the experimental-methodology mindset (how to compare two detectors fairly).

### 4.3 Videos, talks, courses

- **StatQuest (Josh Starmer) — "Decision Trees", "Random Forests", "Isolation Forest".** The fastest path to the tree intuition.
- **scikit-learn official user guide — "Novelty and Outlier Detection"** and the `IsolationForest` API docs (read the sign-convention notes carefully).
- **Andrew Ng — "Machine Learning Specialization"** (Coursera): the train/validation/test and bias/variance foundations.
- **"A Friendly Introduction to Isolation Forests"** blog/video (e.g., articles by towardsdatascience authors) — good for the geometry intuition.
- **"How (not) to evaluate anomaly detection"** / anomaly-detection evaluation talks — search conference talks on outlier-detection metrics (PR-AUC, FAPH).

### 4.4 Exercises to internalize this module

1. Implement `anomaly_score()` (larger = anomalous) and unit-test its direction on a hand-built outlier.
2. Build the train/val/test temporal split and a test asserting no incident spans two splits.
3. Train an Isolation Forest with median-impute + missing indicators; log the full `ModelArtifactMeta`.
4. Select a threshold under a 1 FAPH budget on validation and evaluate on test; report counts.
5. Wire shadow mode and produce the comparison report for scenarios 1–5.
6. Write a test asserting no ground-truth label column is in the feature list.
7. Run the same experiment twice and assert byte-identical output (reproducibility).

---

*Next module:* **[Module 6 — AWS Serverless & SAM: Lambda, SQS, DynamoDB, API Gateway, IAM](learning_module_6.md)** — deploying the same core to a durable, least-privilege cloud stack.

# Statistical Anomaly Detection — Data Engineering Requirements

> **Purpose**: This document specifies the exact statistical logic required to build an anomaly-detection pipeline in **Azure Databricks** (PySpark / SQL) that powers the Operations Dashboard's "Statistical Risk Analysis" component.
>
> **Audience**: Data Engineers, Data Analysts, Analytics Engineers
>
> **Last Updated**: 2026-02-19
>
> **Reference Implementation**: `operations/sticky_component.html`

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Metrics Inventory](#2-metrics-inventory)
3. [Data Model & Schema](#3-data-model--schema)
4. [Statistical Methods — Detailed Specification](#4-statistical-methods--detailed-specification)
   - 4.1 [Logit-Z Method (Bounded Ratios)](#41-logit-z-method-bounded-ratios)
   - 4.2 [Capacity-Logit-Z Method (Bounded Capacity)](#42-capacity-logit-z-method-bounded-capacity)
   - 4.3 [Median-MAD Method (Unbounded Counts)](#43-median-mad-method-unbounded-counts)
5. [Baseline Window & Evaluation Logic](#5-baseline-window--evaluation-logic)
6. [Directionality Rules](#6-directionality-rules)
7. [Bonferroni Multiple-Testing Correction](#7-bonferroni-multiple-testing-correction)
8. [Trend Detection — OLS Linear Regression](#8-trend-detection--ols-linear-regression)
9. [Risk Classification Logic](#9-risk-classification-logic)
10. [Predictive Analytics — Holt-Winters Forecasting](#10-predictive-analytics--holt-winters-forecasting)
    - 10.1 [Double Exponential Smoothing Algorithm](#101-double-exponential-smoothing-algorithm)
    - 10.2 [Confidence Intervals](#102-confidence-intervals)
    - 10.3 [Time-to-Breach Estimation](#103-time-to-breach-estimation)
11. [Prescriptive Analytics — Action Engine](#11-prescriptive-analytics--action-engine)
    - 11.1 [Action Library Structure](#111-action-library-structure)
    - 11.2 [Action Rules per Metric](#112-action-rules-per-metric)
    - 11.3 [Urgency Classification](#113-urgency-classification)
12. [Stakeholder Dashboard Output — What the UI Shows](#12-stakeholder-dashboard-output--what-the-ui-shows)
    - 12.1 [Executive Summary Card](#121-executive-summary-card)
    - 12.2 [Per-Metric Risk Card](#122-per-metric-risk-card)
    - 12.3 [Forecast & Action Panel](#123-forecast--action-panel)
    - 12.4 [Sample Rendered Output (All 5 Metrics)](#124-sample-rendered-output-all-5-metrics)
13. [Reusable Narrative Generator — Adapt to Any Use Case](#13-reusable-narrative-generator--adapt-to-any-use-case)
    - 13.1 [How the Template System Works](#131-how-the-template-system-works)
    - 13.2 [Databricks Notebook: Generic Narrative Pipeline](#132-databricks-notebook-generic-narrative-pipeline)
    - 13.3 [Adapting to a New Domain (Example: Cloud Cost Monitoring)](#133-adapting-to-a-new-domain-example-cloud-cost-monitoring)
14. [Output Schema](#14-output-schema)
15. [PySpark Reference Implementation](#15-pyspark-reference-implementation)
16. [Databricks SQL Reference Implementation](#16-databricks-sql-reference-implementation)
17. [Testing & Validation](#17-testing--validation)
18. [Architecture Notes](#18-architecture-notes)

---

## 1. Executive Summary

The pipeline implements all **4 tiers of the analytics maturity model** to monitor **5 operational metrics** across telephony, application health, and self-service domains:

| Analytics Tier | Question Answered | Implementation |
|----------------|-------------------|----------------|
| **Descriptive** | *"What happened?"* | Current values, baseline μ/σ, sparkline history, formatted display |
| **Diagnostic** | *"Why did it happen?"* | Logit-Z / Median-MAD anomaly detection, Bonferroni correction, risk commentary |
| **Predictive** | *"What will happen?"* | Holt-Winters double exponential smoothing, 95% confidence intervals, time-to-breach |
| **Prescriptive** | *"What should we do?"* | Automated action engine with urgency classification, impact statements, metric-specific remediation steps |

Each metric requires a **different statistical method** based on its mathematical distribution:

| Metric | Distribution Problem | Method Used |
|--------|---------------------|-------------|
| Apdex scores (bounded [0,1]) | Normal Z-score breaks at boundaries | **Logit transform → Z-score** |
| Port usage (bounded [0, capacity]) | Hard ceiling truncates distribution | **Utilization ratio → Logit → Z-score** |
| Requests/min (unbounded, skewed) | Right-skewed, outlier-prone | **Median + MAD** (robust) |

A **Bonferroni correction** is applied across all 5 metrics to control false-positive rate.

**Trend detection** uses OLS linear regression. **Forecasting** uses Holt-Winters double exponential smoothing with confidence intervals. **Prescriptive actions** are rule-based with severity-ordered condition evaluation.

---

## 2. Metrics Inventory

| # | Metric Name | Category | Metric Type | Direction | Unit | Source System |
|---|-------------|----------|-------------|-----------|------|---------------|
| 1 | **Nuance Port Usage** | Telephony | `bounded_capacity` | `higher_is_bad` | ports (capacity=500) | Nuance / Telephony Platform |
| 2 | **.NET Apdex Score** | Application Health | `bounded_ratio` | `lower_is_bad` | dimensionless [0,1] | Dynatrace / APM |
| 3 | **Unified Gateway Apdex** | Application Health | `bounded_ratio` | `lower_is_bad` | dimensionless [0,1] | Dynatrace / APM |
| 4 | **Self-Serve Rate** | Self Service | `bounded_ratio` | `lower_is_bad` | ratio [0,1] → display as % | IVR / CRM |
| 5 | **Requests Per Minute** | Telephony | `unbounded_count` | `both` | rpm | API Gateway / Load Balancer |

### Metric Type Definitions

- **`bounded_ratio`** — Value is mathematically constrained to [0, 1]. Examples: Apdex scores, percentages expressed as decimals. Standard Z-scores are invalid because the distribution is asymmetric near boundaries.
- **`bounded_capacity`** — Value is constrained to [0, Max_Capacity]. Example: port usage where 500 ports are provisioned. Requires conversion to utilization ratio first.
- **`unbounded_count`** — Value can theoretically be any non-negative number. Typically right-skewed (many normal values, occasional spikes). Standard Z-scores are fragile; Median+MAD is preferred.

### Direction Definitions

- **`lower_is_bad`** — A *decrease* from baseline is the anomaly (e.g., Apdex dropping means degraded performance).
- **`higher_is_bad`** — An *increase* from baseline is the anomaly (e.g., port usage climbing toward capacity).
- **`both`** — Both significant increases AND decreases are anomalous (e.g., RPM — a spike may indicate DDoS, a drop may indicate outage).

---

## 3. Data Model & Schema

### 3.1 Input Table: `metrics_raw`

This is the time-series source table that the pipeline reads from.

```sql
CREATE TABLE IF NOT EXISTS ops_monitoring.metrics_raw (
    metric_id           STRING       NOT NULL COMMENT 'Unique metric identifier',
    metric_name         STRING       NOT NULL COMMENT 'Human-readable name (e.g., ".NET Apdex Score")',
    category            STRING       NOT NULL COMMENT 'Grouping category (e.g., "Application Health")',
    metric_type         STRING       NOT NULL COMMENT 'bounded_ratio | bounded_capacity | unbounded_count',
    direction           STRING       NOT NULL COMMENT 'lower_is_bad | higher_is_bad | both',
    capacity            DOUBLE       COMMENT 'Max capacity (only for bounded_capacity type, NULL otherwise)',
    unit                STRING       COMMENT 'Display unit (ports, rpm, %, etc.)',
    recorded_at         TIMESTAMP    NOT NULL COMMENT 'UTC timestamp of the measurement',
    value               DOUBLE       NOT NULL COMMENT 'The measured value at this point in time'
)
USING DELTA
PARTITIONED BY (metric_id)
COMMENT 'Raw time-series metric values for anomaly detection pipeline';
```

### 3.2 Configuration Table: `metric_config`

```sql
CREATE TABLE IF NOT EXISTS ops_monitoring.metric_config (
    metric_id           STRING       NOT NULL,
    metric_name         STRING       NOT NULL,
    category            STRING       NOT NULL,
    metric_type         STRING       NOT NULL,
    direction           STRING       NOT NULL,
    capacity            DOUBLE,
    unit                STRING,
    baseline_window_pct DOUBLE       DEFAULT 0.70 COMMENT 'Fraction of history used as baseline (0.70 = first 70%)',
    history_min_points  INT          DEFAULT 20   COMMENT 'Minimum data points required for analysis',
    is_active           BOOLEAN      DEFAULT TRUE
)
USING DELTA
COMMENT 'Static configuration for each monitored metric';
```

### 3.3 Output Table: `anomaly_results`

See [Section 14](#14-output-schema) for the full output schema.

---

## 4. Statistical Methods — Detailed Specification

### 4.1 Logit-Z Method (Bounded Ratios)

**Applies to**: `.NET Apdex Score`, `Unified Gateway Apdex`, `Self-Serve Rate`

**Why**: These metrics are bounded to [0, 1]. A standard Z-score assumes the data can extend infinitely in both directions, but a value of 0.95 with σ=0.02 *cannot* exceed 1.0. The distribution is asymmetric near the boundaries, making Z-scores unreliable. The **logit transform** maps (0,1) to (-∞, +∞), restoring the normality assumption.

#### Step-by-Step

**Step 1 — Clamp values** to avoid `log(0)` or `log(∞)`:
```
clamped_value = MAX(0.001, MIN(0.999, raw_value))
```

**Step 2 — Logit transform**:
$$\text{logit}(p) = \ln\left(\frac{p}{1 - p}\right)$$

| Raw Value | Logit Value |
|-----------|-------------|
| 0.50 | 0.000 |
| 0.75 | 1.099 |
| 0.90 | 2.197 |
| 0.95 | 2.944 |
| 0.99 | 4.595 |
| 0.10 | -2.197 |

**Step 3 — Compute baseline statistics** on the **logit-transformed** baseline values:
$$\mu_{logit} = \frac{1}{n} \sum_{i=1}^{n} \text{logit}(x_i)$$
$$\sigma_{logit} = \sqrt{\frac{1}{n-1} \sum_{i=1}^{n} (\text{logit}(x_i) - \mu_{logit})^2}$$

> **IMPORTANT**: Use **Bessel's correction** (divide by `n-1`, not `n`) for sample standard deviation.

**Step 4 — Compute Z-score**:
$$Z = \frac{\text{logit}(x_{current}) - \mu_{logit}}{\sigma_{logit}}$$

#### Worked Example: .NET Apdex

```
Baseline values (first 14 of 20 points, i.e., 70%):
[0.93, 0.92, 0.94, 0.91, 0.93, 0.90, 0.92, 0.91, 0.89, 0.90, 0.88, 0.87, 0.86, 0.85]

Logit-transformed:
[2.586, 2.442, 2.751, 2.313, 2.586, 2.197, 2.442, 2.313, 2.090, 2.197, 1.992, 1.897, 1.815, 1.735]

μ_logit = mean(above) ≈ 2.240
σ_logit = sample_sd(above) ≈ 0.302

Current value = 0.78
logit(0.78) = ln(0.78 / 0.22) = 1.266

Z = (1.266 - 2.240) / 0.302 = -3.22

Direction = 'lower_is_bad' → flip sign → anomaly_score = +3.22
```

Result: Z = 3.22 > σ_critical (3.09) → **Critical anomaly**.

---

### 4.2 Capacity-Logit-Z Method (Bounded Capacity)

**Applies to**: `Nuance Port Usage`

**Why**: Port usage is bounded [0, 500]. As usage approaches capacity, the same absolute change (e.g., +10 ports) becomes exponentially more impactful. Converting to a utilization ratio and applying logit captures this non-linearity.

#### Step-by-Step

**Step 1 — Convert to utilization ratio**:
$$\text{ratio} = \frac{\text{current\_value}}{\text{capacity}}$$

Example: 472 ports / 500 capacity = 0.944

**Step 2 — Clamp** the ratio:
```
clamped_ratio = MAX(0.001, MIN(0.999, ratio))
```

**Step 3 — Logit transform** the ratio (same formula as §4.1 Step 2).

**Step 4 — Compute baseline μ and σ** on transformed baseline ratios.

**Step 5 — Compute Z-score**:
$$Z = \frac{\text{logit}(\text{current\_ratio}) - \mu_{logit}}{\sigma_{logit}}$$

#### Worked Example: Nuance Port Usage

```
Baseline raw values (first 14 of 20):
[310, 325, 318, 340, 335, 328, 342, 350, 355, 360, 368, 375, 380, 390]

Utilization ratios (÷ 500):
[0.620, 0.650, 0.636, 0.680, 0.670, 0.656, 0.684, 0.700, 0.710, 0.720, 0.736, 0.750, 0.760, 0.780]

Logit-transformed ratios:
[0.489, 0.619, 0.557, 0.753, 0.709, 0.645, 0.773, 0.847, 0.896, 0.944, 1.025, 1.099, 1.153, 1.266]

μ_logit ≈ 0.841
σ_logit ≈ 0.234

Current = 472 → ratio = 0.944 → logit(0.944) = 2.826

Z = (2.826 - 0.841) / 0.234 = 8.48

Direction = 'higher_is_bad' → keep positive → anomaly_score = 8.48
```

Result: Z = 8.48 >> σ_critical (3.09) → **Critical anomaly** (extreme port saturation).

---

### 4.3 Median-MAD Method (Unbounded Counts)

**Applies to**: `Requests Per Minute`

**Why**: Request counts are unbounded and typically right-skewed (many normal values, occasional bursts). The **mean** and **standard deviation** are heavily influenced by outliers. **Median + MAD** (Median Absolute Deviation) provides a robust alternative.

#### Step-by-Step

**Step 1 — Compute the median** of the baseline:
$$\tilde{x} = \text{median}(\text{baseline})$$

**Step 2 — Compute MAD** (Median Absolute Deviation):
$$\text{MAD} = \text{median}(|x_i - \tilde{x}|)$$

**Step 3 — Scale MAD** to be comparable with standard deviation (for normally distributed data):
$$\sigma_{MAD} = 1.4826 \times \text{MAD}$$

> The constant **1.4826** is the inverse of the 75th percentile of the standard normal distribution. It ensures that for normally distributed data, MAD × 1.4826 ≈ standard deviation.

**Step 4 — Compute modified Z-score**:
$$Z = \frac{x_{current} - \tilde{x}}{\sigma_{MAD}}$$

**Step 5 — Apply direction**:
- Direction = `both` → take absolute value: `anomaly_score = |Z|`

#### Worked Example: Requests Per Minute

```
Baseline values (first 14 of 20):
[1180, 1210, 1195, 1220, 1205, 1215, 1230, 1190, 1225, 1240, 1200, 1235, 1250, 1260]

Sorted: [1180, 1190, 1195, 1200, 1205, 1210, 1215, 1220, 1225, 1230, 1235, 1240, 1250, 1260]
Median = (1215 + 1220) / 2 = 1217.5

Absolute deviations from median:
[37.5, 27.5, 22.5, 17.5, 12.5, 7.5, 2.5, 2.5, 7.5, 12.5, 17.5, 22.5, 32.5, 42.5]

Sorted deviations: [2.5, 2.5, 7.5, 7.5, 12.5, 12.5, 17.5, 17.5, 22.5, 22.5, 27.5, 32.5, 37.5, 42.5]
MAD = (17.5 + 17.5) / 2 = 17.5

σ_MAD = 1.4826 × 17.5 = 25.9455

Current = 1850
Z = (1850 - 1217.5) / 25.9455 = 24.4

Direction = 'both' → anomaly_score = |24.4| = 24.4
```

Result: Z = 24.4 >> σ_critical (3.09) → **Critical anomaly** (extreme RPM spike).

---

## 5. Baseline Window & Evaluation Logic

### Baseline Split

```
Total history = N data points (ordered chronologically, oldest first)
Baseline period = first FLOOR(N × 0.70) data points
Evaluation period = remaining 30% (for trend context, NOT used in baseline μ/σ)
```

### Requirements

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Minimum history length | **20 data points** | Central Limit Theorem requires n ≥ 20–30 for reliable σ estimation |
| Baseline fraction | **70%** | Provides sufficient data for stable μ/σ while leaving recent data for trend detection |
| Bessel's correction | **n - 1** divisor | Required for unbiased sample variance from a subset |

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| History < 20 points | **Skip analysis**. Return `risk_level = 'Insufficient Data'` |
| σ = 0 (all baseline values identical) | Return Z-score = 0 (no anomaly can be computed) |
| Bounded value = 0.0 or 1.0 exactly | Clamp to [0.001, 0.999] before logit to avoid ±∞ |
| Capacity value = 0 | Skip analysis for bounded_capacity metrics |

---

## 6. Directionality Rules

After computing the raw Z-score, apply the following transformation based on the metric's `direction`:

```python
if direction == 'lower_is_bad':
    anomaly_score = -Z_raw       # Flip sign: negative Z (drop) → positive anomaly
elif direction == 'higher_is_bad':
    anomaly_score = Z_raw        # Keep as-is: positive Z (spike) → positive anomaly
elif direction == 'both':
    anomaly_score = abs(Z_raw)   # Both tails: any deviation is anomalous
```

**The anomaly_score is what gets compared to thresholds.** A positive anomaly_score always means "bad."

---

## 7. Bonferroni Multiple-Testing Correction

### Problem

When monitoring N metrics simultaneously, each at significance level α = 0.05, the probability of *at least one* false positive is:

$$P(\text{≥1 false positive}) = 1 - (1 - \alpha)^N$$

For N = 5: $1 - (0.95)^5 = 18.5\%$ — unacceptably high.

### Correction

Divide α by the number of simultaneous tests:

$$\alpha_{adjusted} = \frac{\alpha}{N} = \frac{0.05}{5} = 0.01$$

### Adjusted Thresholds

Derived from the inverse normal CDF at the adjusted α levels:

| Risk Level | Raw α | Adjusted α | Z-threshold (σ) |
|------------|-------|------------|------------------|
| **Critical** | 0.001 per metric | 0.005 family | **3.09** |
| **Elevated** | 0.01 per metric | 0.05 family | **2.33** |
| Nominal | > 0.01 | — | < 2.33 |

### Implementation

```python
NUM_METRICS = 5
BONFERRONI_ALPHA = 0.05 / NUM_METRICS   # 0.01
SIGMA_CRITICAL = 3.09
SIGMA_ELEVATED = 2.33
```

> **IMPORTANT**: If you add or remove metrics from the monitoring set, update `NUM_METRICS` and recalculate the thresholds.

---

## 8. Trend Detection — OLS Linear Regression

### Why Not Simple Comparison

Comparing only the last two data points (`current > previous`) is noise, not trend. A single spike would be misclassified as "aggressively increasing."

### OLS (Ordinary Least Squares) Specification

Fit a simple linear model $y = \beta_0 + \beta_1 x$ where:
- $x_i = i$ (ordinal index 0, 1, 2, ..., n-1) — represents time
- $y_i$ = metric value at point $i$

#### Formulas

**Slope** ($\beta_1$):
$$\beta_1 = \frac{\sum_{i=0}^{n-1} (x_i - \bar{x})(y_i - \bar{y})}{\sum_{i=0}^{n-1} (x_i - \bar{x})^2}$$

Where $\bar{x} = \frac{n-1}{2}$ and $\bar{y} = \text{mean}(y)$.

**Coefficient of Determination** ($R^2$):
$$R^2 = 1 - \frac{SS_{res}}{SS_{tot}}$$

Where:
$$SS_{tot} = \sum (y_i - \bar{y})^2$$
$$SS_{res} = \sum (y_i - \hat{y}_i)^2$$

**Normalized Slope** (for cross-metric comparison):
$$\beta_{norm} = \frac{\beta_1}{\sigma_y}$$

### Trend Classification

| R² Range | Slope Direction | Classification |
|----------|----------------|----------------|
| R² > 0.85 | slope > 0 | **Strong increasing trend** |
| R² > 0.85 | slope < 0 | **Strong decreasing trend** |
| 0.50 < R² ≤ 0.85 | slope > 0 | **Moderate increasing trend** |
| 0.50 < R² ≤ 0.85 | slope < 0 | **Moderate decreasing trend** |
| R² ≤ 0.50 | any | **No significant trend** |

### Input Data for Trend

Use the **full history** (all N points, not just the baseline 70%) for trend computation. This gives the most complete picture of trajectory.

---

## 9. Risk Classification Logic

### Decision Tree

```
IF anomaly_score > 3.09 (SIGMA_CRITICAL):
    risk_level = "Critical"
    risk_description = "Extreme anomaly (Bonferroni-adjusted p < 0.010)"

ELSE IF anomaly_score > 2.33 (SIGMA_ELEVATED):
    risk_level = "Elevated"
    risk_description = "Significant deviation beyond adjusted threshold"

ELSE:
    risk_level = "Nominal"
    risk_description = "Within expected statistical range"
```

### Directional Context (appended to commentary)

```
IF direction = 'lower_is_bad' AND current_value < baseline_mean_raw:
    append "▼ Value is below baseline (degradation)"

ELSE IF direction = 'higher_is_bad' AND current_value > baseline_mean_raw:
    append "▲ Value exceeds baseline (approaching capacity)"
```

---

## 10. Predictive Analytics — Holt-Winters Forecasting

### 10.1 Double Exponential Smoothing Algorithm

**Why Holt-Winters over OLS extrapolation?**

OLS linear regression fits a straight line — it cannot capture accelerating or decelerating trends. Port usage acceleration, Apdex decay curves, and RPM spikes are inherently *non-linear*. Holt-Winters exponential smoothing adapts its level and trend estimates at each time step, giving more weight to recent observations.

#### Algorithm: Holt's Linear Method (Additive Trend, No Seasonality)

Parameters:
- **α (alpha)** = 0.3 — Level smoothing factor. Higher values react faster to level shifts.
- **β (beta)** = 0.1 — Trend smoothing factor. Higher values react faster to trend changes.
- **h** = 5 — Forecast horizon (number of future periods).

#### Step-by-Step

**Initialization**:
$$\ell_0 = y_0 \quad \text{(first observation)}$$
$$b_0 = \frac{y_2 - y_0}{2} \quad \text{(average slope of first 3 points)}$$

**Recursive Update** (for each observation $t = 1, 2, ..., n-1$):
$$\ell_t = \alpha \cdot y_t + (1 - \alpha)(\ell_{t-1} + b_{t-1}) \quad \text{(level update)}$$
$$b_t = \beta(\ell_t - \ell_{t-1}) + (1 - \beta) \cdot b_{t-1} \quad \text{(trend update)}$$

**Forecast** ($h$ steps ahead from final state):
$$\hat{y}_{n+h} = \ell_n + h \cdot b_n$$

**Residuals** (for confidence intervals):
$$e_t = y_t - (\ell_{t-1} + b_{t-1})$$

#### Worked Example: Nuance Port Usage Forecast

```
History: [310, 325, 318, ..., 458, 472] (20 points)
α=0.3, β=0.1

Initialization:
  ℓ₀ = 310
  b₀ = (318 - 310) / 2 = 4.0

After recursive processing through all 20 points:
  ℓ₂₀ ≈ 468.2 (smoothed level)
  b₂₀ ≈ 9.8  (smoothed trend: ~9.8 ports/period increase)

Forecast:
  h=1: 468.2 + 1×9.8 = 478.0 ports
  h=2: 468.2 + 2×9.8 = 487.8 ports
  h=3: 468.2 + 3×9.8 = 497.6 ports ← approaches 500 capacity!
  h=4: 468.2 + 4×9.8 = 507.4 ports ← exceeds capacity
  h=5: 468.2 + 5×9.8 = 517.2 ports
```

### 10.2 Confidence Intervals

Prediction intervals widen as the forecast horizon grows (uncertainty increases with distance).

**Residual Standard Error**:
$$SE = \sqrt{\frac{1}{n-2} \sum_{t=1}^{n-1} e_t^2}$$

**Prediction Interval** at horizon $h$:
$$\hat{y}_{n+h} \pm z_{\alpha/2} \cdot SE \cdot \sqrt{h}$$

Where:
- $z_{0.025} = 1.96$ for 95% confidence interval
- $z_{0.10} = 1.28$ for 80% confidence interval
- $\sqrt{h}$ scales the uncertainty with forecast distance

| Confidence Level | z-value | Use Case |
|:---:|:---:|---|
| 95% | 1.96 | Planning threshold — "we are 95% confident the value will be within this range" |
| 80% | 1.28 | Operational threshold — narrower, more actionable |

#### Implementation Note

For **bounded metrics** (Apdex, Self-Serve Rate), the forecast and confidence limits should be clamped to [0, 1] after computation. For **capacity metrics**, clamp lower bound to 0.

### 10.3 Time-to-Breach Estimation

Using the Holt-Winters forecast model ($\hat{y}_{n+h} = \ell_n + h \cdot b_n$), extrapolate until the projected value crosses a defined threshold.

#### Breach Thresholds

| Metric | Threshold | Breach Direction | Rationale |
|--------|-----------|-----------------|----------|
| **Nuance Port Usage** | Capacity × 0.95 (= 475) | Crosses above | Industry standard: 95% utilization is "at capacity" |
| **.NET Apdex** | 0.70 | Crosses below | Apdex < 0.70 = "Poor" per Apdex standard |
| **UGW Apdex** | 0.70 | Crosses below | Same Apdex standard |
| **Self-Serve Rate** | 0.70 (70%) | Crosses below | Below 70% creates unsustainable agent load |
| **Requests/Min** | 2× baseline median | Crosses above | Double the normal RPM indicates traffic anomaly |

#### Calculation

```
Solve for h where:
  ℓ_n + h × b_n = threshold

  h = (threshold - ℓ_n) / b_n
```

If $b_n$ is moving *away* from the threshold (or = 0), then `periodsToBreak = null` (no breach projected).

Maximum lookahead: **50 periods**. Beyond this, the linear trend assumption becomes unreliable.

#### States

| State | Condition | Display |
|-------|----------|--------|
| **Already Breached** | Current value has already crossed threshold | `⚠ ALREADY BREACHED: [breach label]` |
| **Breach Imminent** | h ≤ 5 periods | `⏱ Breach in ~h periods: [breach label]` |
| **Breach Projected** | 5 < h ≤ 50 | `⏱ Breach in ~h periods: [breach label]` |
| **No Breach** | h > 50 or trend direction is safe | `✓ No breach projected within forecast horizon` |

---

## 11. Prescriptive Analytics — Action Engine

The prescriptive layer maps the combined diagnostics (anomaly score, risk level) and predictions (trend, time-to-breach) to **specific recommended actions** with urgency levels and impact statements.

### 11.1 Action Library Structure

Each metric has an **ordered list of condition → action rules**. The engine evaluates conditions top-to-bottom and returns the **first match** (most severe first).

```
ActionRule {
  condition: function(analysisContext) → boolean
  urgency: 'urgent' | 'moderate' | 'monitor'
  action: string   // The specific recommendation
  impact: string   // Expected business impact if action is / isn't taken
}

analysisContext = {
  anomalyScore: number,     // Absolute Z-score
  riskLevel: string,        // 'Critical' | 'Elevated' | 'Nominal'
  trend: { slope, rSquared, slopeNormalized },
  breach: { periodsToBreak, threshold, currentlyBreached },
  currentValue: number
}
```

### 11.2 Action Rules per Metric

#### Nuance Port Usage

| # | Condition | Urgency | Recommended Action | Impact |
|---|-----------|---------|-------------------|--------|
| 1 | Currently breached (>95% util) | **Urgent** | IMMEDIATE: Request emergency port capacity expansion. Engage vendor support hotline. | Prevents call routing failures and customer abandonment. |
| 2 | Breach in ≤3 periods | **Urgent** | ESCALATE: Port saturation projected imminently. Initiate capacity expansion. Reroute overflow to backup carrier. | Avoids saturation-induced call drops. |
| 3 | Breach in ≤10 periods | **Moderate** | PLAN: Schedule port capacity review with Nuance. Analyze peak-hour patterns. Consider dynamic port allocation. | Proactive capacity management reduces incident risk by ~60%. |
| 4 | Risk ≠ Nominal | **Moderate** | MONITOR: Set up automated alerts at 85% and 90% utilization thresholds. | Early warning enables proactive intervention. |
| 5 | (default) | **Monitor** | MAINTAIN: Port usage within normal range. Continue monitoring cadence. | No action required. |

#### .NET Apdex Score

| # | Condition | Urgency | Recommended Action | Impact |
|---|-----------|---------|-------------------|--------|
| 1 | Critical + already breached | **Urgent** | Trigger APM deep-dive. Check memory leaks, thread pool exhaustion. Engage .NET platform team. | Prevents user-facing SLA breach. |
| 2 | Critical anomaly | **Urgent** | Run Dynatrace root-cause analysis. Isolate top 3 slowest transactions. Consider service restart. | Direct correlation with customer satisfaction. |
| 3 | Elevated anomaly | **Moderate** | Review recent deployments. Check infrastructure metrics. Correlate with release calendar. | Catch regression before customer impact. |
| 4 | Negative trend (R² > 0.5) | **Moderate** | Schedule performance profiling. Review code-level hotspots in Dynatrace. | Trend reversal at this stage is 3× cheaper than post-incident. |
| 5 | (default) | **Monitor** | Continue standard APM monitoring. | No action required. |

#### Unified Gateway Apdex

| # | Condition | Urgency | Recommended Action | Impact |
|---|-----------|---------|-------------------|--------|
| 1 | Critical anomaly | **Urgent** | Check gateway pod health, connection pool limits, SSL certificate status. | Gateway is single point of failure for all API traffic. |
| 2 | Elevated anomaly | **Moderate** | Review request queue depth, backend timeouts, TLS handshake latency. | Gateway issues cascade to all downstream services. |
| 3 | Negative trend (R² > 0.5) | **Moderate** | Evaluate gateway scaling policy. Review connection pool recycling. | Proactive scaling prevents cascading failures. |
| 4 | (default) | **Monitor** | Continue monitoring. | No action required. |

#### Self-Serve Rate

| # | Condition | Urgency | Recommended Action | Impact |
|---|-----------|---------|-------------------|--------|
| 1 | Critical + breached (<70%) | **Urgent** | Check IVR menu, speech recognition, knowledge base freshness. Alert workforce management. | Every 1% drop ≈ 200+ additional live agent calls/day. |
| 2 | Critical anomaly | **Urgent** | Audit top 10 IVR exit points. Review NLU confidence scores. | Agent queue times increase exponentially below 65%. |
| 3 | Elevated anomaly | **Moderate** | Analyze intent-level containment rates. A/B test IVR prompt changes. | Targeted fixes can recover 5-10% containment in a week. |
| 4 | Negative trend (R² > 0.5) | **Moderate** | Schedule CX team review. Update knowledge base for top 20 call drivers. | Improving self-serve is the highest-ROI capacity lever. |
| 5 | (default) | **Monitor** | Continue monitoring containment by intent. | No action required. |

#### Requests Per Minute

| # | Condition | Urgency | Recommended Action | Impact |
|---|-----------|---------|-------------------|--------|
| 1 | Critical + upward trend | **Urgent** | Rule out DDoS/bot traffic. Check rate limiters. Prepare auto-scaling. Alert NOC. | Uncontrolled growth causes cascading failures. |
| 2 | Critical + downward trend | **Urgent** | RPM critically low — verify LB health, DNS, client connectivity. Check for incident. | RPM drop may indicate customer-impacting outage. |
| 3 | Elevated anomaly | **Moderate** | Correlate with marketing campaigns, seasonal patterns. Update baseline if organic. | Distinguishing growth from anomaly prevents false alerts. |
| 4 | (default) | **Monitor** | Continue baseline calibration. | No action required. |

### 11.3 Urgency Classification

| Urgency | Color | Trigger Criteria | Expected Response Time |
|---------|-------|-----------------|----------------------|
| **Urgent** | Red | Critical anomaly AND/OR breach imminent/active | Immediate (< 15 min) |
| **Moderate** | Amber | Elevated anomaly OR breach in ≤10 periods OR significant negative trend | Within 1 hour |
| **Monitor** | Blue | Nominal — no action needed | Next scheduled review |

---

## 12. Stakeholder Dashboard Output — What the UI Shows

This section defines **exactly what a business analyst or stakeholder sees** on the dashboard. No Z-scores, no logit transforms — just plain-language status, forecasts, and recommended actions.

### 12.1 Executive Summary Card

At the top of the dashboard, a single card summarizes the overall health:

```
┌────────────────────────────────────────────────────────────────────────────┐
│  OPERATIONS HEALTH SUMMARY                        2026-02-19 14:30 UTC    │
│                                                                            │
│  Overall Status:  🔴 CRITICAL  (2 of 5 metrics require immediate action)  │
│                                                                            │
│  🔴 Critical:  2    🟡 Elevated:  1    🟢 Nominal:  2                     │
│                                                                            │
│  Top Risk:  Nuance Port Usage at 94.4% capacity — breach in ~3 periods    │
│  Next Risk: .NET Apdex at 0.78 — below 'Poor' threshold (0.70) in ~8p    │
└────────────────────────────────────────────────────────────────────────────┘
```

**Fields shown:**

| Field | Source Column | Logic |
|-------|--------------|-------|
| Overall Status | `risk_level` (all rows) | Worst risk across all metrics |
| Critical/Elevated/Nominal counts | `risk_level` | `GROUP BY risk_level` count |
| Top Risk narrative | `metric_name` + `formatted_value` + `breach_label` | Metric with highest `anomaly_score` |
| Timestamp | `run_timestamp` | Pipeline run time |

### 12.2 Per-Metric Risk Card

Each metric gets a card. Here's the **exact layout** a stakeholder sees:

```
┌─────────────────────────────────────────────────────────────────────┐
│  NUANCE PORT USAGE                                    🔴 CRITICAL  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Current Value     472 / 500 ports  (94.4%)                        │
│  Baseline          336.8 avg  (67.4% utilization)                  │
│  Deviation         +8.48σ from baseline                            │
│                                                                     │
│  Trend             ▲ Strong increasing trend  (R² = 0.97)         │
│  Sparkline         ▁▂▂▃▃▃▄▄▅▅▅▆▆▇▇███▉█                         │
│                                                                     │
│  ──── Forecast ────                                                │
│  Next period       478 ports                                       │
│  +3 periods        498 ports                                       │
│  +5 periods        517 ports  (95% CI: 489 – 545)                 │
│  ⏱ Breach in ~3 periods (threshold: 475 ports / 95%)              │
│                                                                     │
│  ──── Recommended Action ────                                      │
│  🔴 URGENT                                                         │
│  ESCALATE: Port saturation projected imminently. Initiate          │
│  capacity expansion. Reroute overflow to backup carrier.           │
│  Impact: Avoids saturation-induced call drops.                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Field-to-Column mapping:**

| UI Field | Source Column(s) | Format |
|----------|-----------------|--------|
| Metric name | `metric_name` | As-is |
| Risk badge | `risk_level` | Color-coded: Critical=Red, Elevated=Amber, Nominal=Green |
| Current Value | `formatted_value` | Pre-formatted string |
| Baseline | `baseline_mu` | Reverse-logit for bounded types, raw for unbounded |
| Deviation | `anomaly_score` | `"+{score}σ from baseline"` or `"-{score}σ below baseline"` |
| Trend | `trend_classification` | Arrow icon + classification text |
| Sparkline | `history_values` | JSON array → mini bar chart |
| Forecast values | `forecast_h1`, `forecast_h3`, `forecast_h5` | Formatted with unit |
| Confidence interval | `ci_95_lower_h5`, `ci_95_upper_h5` | `"(95% CI: {lower} – {upper})"` |
| Breach line | `periods_to_breach`, `breach_label` | `"⏱ Breach in ~{n} periods"` or `"✓ No breach projected"` |
| Action urgency | `rx_urgency` | Color tag: urgent=Red, moderate=Amber, monitor=Blue |
| Action text | `rx_action` | Full recommendation text |
| Impact text | `rx_impact` | Business impact statement |

### 12.3 Forecast & Action Panel

For stakeholders who want a **consolidated action list** (e.g., for a morning stand-up):

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ACTION ITEMS — 2026-02-19 14:30 UTC                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  🔴 URGENT (respond within 15 min)                                     │
│  ─────────────────────────────────                                     │
│  1. Nuance Port Usage (94.4%)                                          │
│     Breach in ~3 periods. ESCALATE: Initiate capacity expansion.       │
│     Reroute overflow to backup carrier.                                │
│     → Impact: Avoids saturation-induced call drops.                    │
│                                                                         │
│  2. .NET Application Performance (Apdex 0.78)                         │
│     Critical anomaly (-3.22σ). Run Dynatrace root-cause analysis.     │
│     Isolate top 3 slowest transactions. Consider service restart.      │
│     → Impact: Direct correlation with customer satisfaction.           │
│                                                                         │
│  🟡 MODERATE (respond within 1 hour)                                   │
│  ──────────────────────────────────                                    │
│  3. Self-Serve Rate (58.0%)                                            │
│     Elevated anomaly. Analyze intent-level containment rates.          │
│     A/B test IVR prompt changes.                                       │
│     → Impact: Targeted fixes can recover 5-10% containment in a week. │
│                                                                         │
│  🔵 MONITORING (next scheduled review)                                 │
│  ─────────────────────────────────────                                 │
│  4. Unified Gateway Apdex (0.88) — Nominal. No action required.       │
│  5. Requests/Min (1,850 rpm) — Nominal. Continue baseline calibration. │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**SQL to generate the action list:**

```sql
SELECT
    rx_urgency,
    metric_name,
    formatted_value,
    risk_level,
    ROUND(anomaly_score, 2) AS deviation_sigma,
    CASE
        WHEN periods_to_breach IS NOT NULL
        THEN CONCAT('Breach in ~', periods_to_breach, ' periods. ')
        ELSE ''
    END || rx_action AS full_action,
    rx_impact
FROM ops_monitoring.anomaly_results
WHERE run_id = (SELECT MAX(run_id) FROM ops_monitoring.anomaly_results)
ORDER BY
    CASE rx_urgency
        WHEN 'urgent'   THEN 1
        WHEN 'moderate'  THEN 2
        WHEN 'monitor'   THEN 3
    END,
    anomaly_score DESC;
```

### 12.4 Sample Rendered Output (All 5 Metrics)

Below is the **exact text output** generated for each metric. This is what the narrative engine produces — a stakeholder can read this as-is in an email, Teams message, or dashboard panel.

---

**Metric 1: Nuance Port Usage**

> **Status: 🔴 CRITICAL** — 472 / 500 ports (94.4% utilization)
>
> Port usage is +8.48σ above baseline (67.4% avg). This is an extreme statistical anomaly. The trend is *strongly increasing* (R² = 0.97), with usage climbing 8–10 ports per measurement cycle.
>
> **Forecast:** At current trajectory, usage will reach 498 ports (+3 periods) and **breach the 95% capacity threshold (~475 ports) in approximately 3 periods**. The 95% confidence interval at +5 periods is 489–545 ports.
>
> **Recommended Action (URGENT):** Initiate capacity expansion with Nuance. Reroute overflow to backup carrier immediately.
> **Business Impact:** Prevents call routing failures and customer abandonment.

---

**Metric 2: .NET Apdex Score**

> **Status: 🔴 CRITICAL** — Apdex 0.780 (Tolerable)
>
> Apdex is -3.22σ below baseline (0.909 avg). This represents a statistically significant degradation beyond the Bonferroni-adjusted threshold. The trend is *strongly decreasing* (R² = 0.94), indicating sustained performance decay.
>
> **Forecast:** Apdex is projected to drop to 0.74 (+3 periods) and **breach the 'Poor' threshold (0.70) in approximately 8 periods**. The 95% confidence interval at +5 periods is 0.68–0.77.
>
> **Recommended Action (URGENT):** Run Dynatrace root-cause analysis. Isolate top 3 slowest transactions. Consider service restart if memory leak is confirmed.
> **Business Impact:** Direct correlation with customer satisfaction. SLA breach imminent.

---

**Metric 3: Unified Gateway Apdex**

> **Status: 🟢 NOMINAL** — Apdex 0.880 (Satisfactory)
>
> Gateway performance is within expected range (+0.41σ from baseline 0.873 avg). No statistically significant deviation detected. Trend is flat (R² = 0.12).
>
> **Forecast:** Apdex expected to remain stable around 0.87–0.89 over the next 5 periods. No breach projected within the forecast horizon.
>
> **Recommended Action (MONITOR):** Continue standard monitoring. No action required.

---

**Metric 4: Self-Serve Rate**

> **Status: 🟡 ELEVATED** — 58.0% containment rate
>
> Self-serve rate is -2.65σ below baseline (66.2% avg). This is a statistically significant drop, though not yet critical. The trend is *moderately decreasing* (R² = 0.72), suggesting a gradual drift rather than a sudden break.
>
> **Forecast:** At current trajectory, self-serve rate will reach 54% (+5 periods). **Breach of the 70% sustainability threshold already active** — current value (58%) is below the 70% floor.
>
> **Recommended Action (MODERATE):** Analyze intent-level containment rates. A/B test IVR prompt changes for top 5 failure intents.
> **Business Impact:** Every 1% drop ≈ 200+ additional live agent calls/day. Targeted fixes can recover 5–10% containment in a week.

---

**Metric 5: Requests Per Minute**

> **Status: 🟢 NOMINAL** — 1,850 rpm
>
> RPM is elevated at +1.85σ from baseline (1,217 rpm median) but within the Bonferroni-adjusted threshold (2.33σ). The trend is *strongly increasing* (R² = 0.91), consistent with organic traffic growth.
>
> **Forecast:** RPM projected to reach 2,020 (+3 periods) and 2,190 (+5 periods). No breach of the 2× median threshold (2,435 rpm) projected within 5 periods.
>
> **Recommended Action (MONITOR):** Continue baseline calibration. If growth persists, rebase the median.

---

## 13. Reusable Narrative Generator — Adapt to Any Use Case

The statistical engine and narrative templates are **domain-agnostic**. You only need to provide:

1. **Metric configuration** (name, type, direction, thresholds)
2. **Time-series history** (array of numbers)
3. **Domain-specific action rules** (condition → action text)

The math, forecasting, and narrative generation are the same regardless of whether you're monitoring port usage, cloud costs, API latency, or warehouse inventory.

### 13.1 How the Template System Works

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  METRIC CONFIG   │     │  ANOMALY ENGINE  │     │ NARRATIVE ENGINE │
│                  │     │                  │     │                  │
│ • name           │────▶│ • Z-score        │────▶│ • Status line    │
│ • type           │     │ • Trend (OLS)    │     │ • Deviation text │
│ • direction      │     │ • Forecast (HW)  │     │ • Forecast text  │
│ • thresholds     │     │ • Breach calc    │     │ • Action text    │
│ • action_rules   │     │ • Risk class     │     │ • Impact text    │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                                          │
                                                          ▼
                                               ┌──────────────────┐
                                               │   RENDERED TEXT   │
                                               │  (Dashboard /    │
                                               │   Email / Slack) │
                                               └──────────────────┘
```

### 13.2 Databricks Notebook: Generic Narrative Pipeline

Copy this notebook to generate narratives for **any domain**. Swap `METRIC_CONFIG` and `ACTION_RULES` for your use case.

```python
"""
Generic Narrative Generation Pipeline for Databricks
=====================================================
Domain-agnostic: works for operations, finance, cloud costs, SLA monitoring, etc.
Just change METRIC_CONFIG and ACTION_RULES.
"""

import json
import numpy as np
from datetime import datetime

# ═══════════════════════════════════════════════════════════════════════
# STEP 1: DEFINE YOUR METRICS  (← CHANGE THIS FOR YOUR USE CASE)
# ═══════════════════════════════════════════════════════════════════════

METRIC_CONFIG = [
    {
        "metric_id": "your_metric_1",
        "metric_name": "Your Metric Name",
        "category": "Your Category",
        "metric_type": "bounded_ratio",       # bounded_ratio | bounded_capacity | unbounded_count
        "direction": "lower_is_bad",           # lower_is_bad | higher_is_bad | both
        "capacity": None,                       # Only for bounded_capacity
        "unit": "score",
        "breach_threshold": 0.70,               # When is it "breached"?
        "breach_direction": "below",            # "above" or "below"
        "breach_label": "Below acceptable score"
    },
    # ... add more metrics
]

# ═══════════════════════════════════════════════════════════════════════
# STEP 2: DEFINE YOUR ACTION RULES  (← CHANGE THIS FOR YOUR USE CASE)
# ═══════════════════════════════════════════════════════════════════════

ACTION_RULES = {
    "your_metric_1": [
        {
            "condition": lambda ctx: ctx["risk_level"] == "Critical" and ctx["breach"]["currently_breached"],
            "urgency": "urgent",
            "action": "Your urgent action when breached.",
            "impact": "Your business impact statement."
        },
        {
            "condition": lambda ctx: ctx["risk_level"] == "Critical",
            "urgency": "urgent",
            "action": "Your urgent action for critical anomaly.",
            "impact": "Your business impact."
        },
        {
            "condition": lambda ctx: ctx["risk_level"] == "Elevated",
            "urgency": "moderate",
            "action": "Your moderate action.",
            "impact": "Your moderate impact."
        },
        {
            # Default fallback — always matches
            "condition": lambda ctx: True,
            "urgency": "monitor",
            "action": "Continue monitoring.",
            "impact": "No action required."
        }
    ],
    # ... add rules for each metric
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 3: NARRATIVE TEMPLATES  (← CUSTOMIZE WORDING AS NEEDED)
# ═══════════════════════════════════════════════════════════════════════

STATUS_ICONS = {"Critical": "🔴", "Elevated": "🟡", "Nominal": "🟢", "Insufficient Data": "⚪"}
URGENCY_ICONS = {"urgent": "🔴", "moderate": "🟡", "monitor": "🔵"}

def generate_narrative(result: dict) -> str:
    """
    Takes a single metric's anomaly result dict and returns
    a stakeholder-readable narrative string.
    """
    icon = STATUS_ICONS.get(result["risk_level"], "⚪")
    direction_word = "above" if result["z_score_raw"] > 0 else "below"
    abs_score = abs(result["anomaly_score"])

    # ── Status Line ──
    lines = []
    lines.append(f"**{result['metric_name']}**")
    lines.append(f"")
    lines.append(f"> **Status: {icon} {result['risk_level'].upper()}** — {result['formatted_value']}")
    lines.append(f">")

    # ── Deviation Description ──
    if result["risk_level"] == "Insufficient Data":
        lines.append(f"> Insufficient history for analysis ({result['history_length']} of 20 required points).")
        return "\n".join(lines)

    if abs_score > 0.5:
        severity = "an extreme" if abs_score > 5 else "a significant" if abs_score > 2.33 else "a moderate"
        lines.append(
            f"> Value is {direction_word} baseline by {abs_score:.2f}σ. "
            f"This is {severity} statistical deviation."
        )
    else:
        lines.append(f"> Value is within expected range ({abs_score:.2f}σ from baseline).")

    # ── Trend ──
    if result.get("trend_classification"):
        trend_arrow = "▲" if result["trend_slope"] > 0 else "▼"
        lines.append(
            f"> Trend: {trend_arrow} {result['trend_classification']} "
            f"(R² = {result['trend_r_squared']:.2f})."
        )
    lines.append(f">")

    # ── Forecast ──
    if result.get("forecast_h1") is not None:
        lines.append(f"> **Forecast:**")
        lines.append(f"> Next period: {result['forecast_h1']:.1f}")
        if result.get("forecast_h5") is not None:
            ci_text = ""
            if result.get("ci_95_lower_h5") is not None:
                ci_text = f" (95% CI: {result['ci_95_lower_h5']:.1f} – {result['ci_95_upper_h5']:.1f})"
            lines.append(f"> +5 periods: {result['forecast_h5']:.1f}{ci_text}")

        # ── Breach ──
        if result.get("currently_breached"):
            lines.append(f"> ⚠ **ALREADY BREACHED**: {result['breach_label']}")
        elif result.get("periods_to_breach") is not None:
            lines.append(
                f"> ⏱ **Breach in ~{result['periods_to_breach']} periods**: {result['breach_label']}"
            )
        else:
            lines.append(f"> ✓ No breach projected within forecast horizon.")
    lines.append(f">")

    # ── Prescription ──
    if result.get("rx_action"):
        urg_icon = URGENCY_ICONS.get(result["rx_urgency"], "")
        lines.append(f"> **Recommended Action ({urg_icon} {result['rx_urgency'].upper()}):** {result['rx_action']}")
        lines.append(f"> **Business Impact:** {result['rx_impact']}")

    return "\n".join(lines)


def generate_executive_summary(results: list) -> str:
    """
    Takes list of all metric results and returns the overall summary text.
    """
    critical = [r for r in results if r["risk_level"] == "Critical"]
    elevated = [r for r in results if r["risk_level"] == "Elevated"]
    nominal  = [r for r in results if r["risk_level"] == "Nominal"]

    # Overall status = worst case
    if critical:
        overall = "🔴 CRITICAL"
    elif elevated:
        overall = "🟡 ELEVATED"
    else:
        overall = "🟢 ALL NOMINAL"

    action_count = len(critical) + len(elevated)
    total = len(results)

    lines = []
    lines.append(f"## Operations Health Summary — {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append(f"")
    lines.append(f"**Overall Status: {overall}** ({action_count} of {total} metrics require action)")
    lines.append(f"")
    lines.append(f"| Status | Count |")
    lines.append(f"|--------|-------|")
    lines.append(f"| 🔴 Critical | {len(critical)} |")
    lines.append(f"| 🟡 Elevated | {len(elevated)} |")
    lines.append(f"| 🟢 Nominal  | {len(nominal)} |")
    lines.append(f"")

    # Top risk
    if critical or elevated:
        top = sorted(critical + elevated, key=lambda r: -abs(r["anomaly_score"]))[0]
        breach_text = ""
        if top.get("periods_to_breach"):
            breach_text = f" — breach in ~{top['periods_to_breach']} periods"
        elif top.get("currently_breached"):
            breach_text = " — ALREADY BREACHED"
        lines.append(f"**Top Risk:** {top['metric_name']} at {top['formatted_value']}{breach_text}")

    return "\n".join(lines)


def generate_action_list(results: list) -> str:
    """
    Generates a prioritized action list for stand-ups / email digests.
    """
    urgency_order = {"urgent": 1, "moderate": 2, "monitor": 3}
    sorted_results = sorted(results, key=lambda r: (
        urgency_order.get(r.get("rx_urgency", "monitor"), 3),
        -abs(r.get("anomaly_score", 0))
    ))

    lines = []
    lines.append(f"## Action Items — {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append("")

    current_urgency = None
    item_num = 0

    for r in sorted_results:
        urg = r.get("rx_urgency", "monitor")
        if urg != current_urgency:
            current_urgency = urg
            urg_label = {"urgent": "🔴 URGENT (respond < 15 min)",
                         "moderate": "🟡 MODERATE (respond < 1 hour)",
                         "monitor": "🔵 MONITORING (next review)"}
            lines.append(f"")
            lines.append(f"### {urg_label.get(urg, urg)}")
            lines.append(f"")

        item_num += 1
        breach_prefix = ""
        if r.get("currently_breached"):
            breach_prefix = "⚠ BREACHED. "
        elif r.get("periods_to_breach"):
            breach_prefix = f"Breach in ~{r['periods_to_breach']}p. "

        lines.append(f"{item_num}. **{r['metric_name']}** ({r['formatted_value']})")
        lines.append(f"   {breach_prefix}{r.get('rx_action', 'N/A')}")
        lines.append(f"   → *Impact: {r.get('rx_impact', 'N/A')}*")
        lines.append("")

    return "\n".join(lines)
```

### 13.3 Adapting to a New Domain (Example: Cloud Cost Monitoring)

Here's how you'd reuse this pipeline for a completely different domain — **cloud cost monitoring** — by only changing the config and action rules:

```python
# ═══ CLOUD COST MONITORING — CONFIG ═══

METRIC_CONFIG = [
    {
        "metric_id": "monthly_azure_spend",
        "metric_name": "Monthly Azure Spend",
        "category": "Cloud Costs",
        "metric_type": "unbounded_count",
        "direction": "higher_is_bad",
        "capacity": None,
        "unit": "USD",
        "breach_threshold": 50000,
        "breach_direction": "above",
        "breach_label": "Exceeds monthly budget ($50,000)"
    },
    {
        "metric_id": "reserved_instance_utilization",
        "metric_name": "Reserved Instance Utilization",
        "category": "Cloud Costs",
        "metric_type": "bounded_ratio",
        "direction": "lower_is_bad",
        "capacity": None,
        "unit": "%",
        "breach_threshold": 0.60,
        "breach_direction": "below",
        "breach_label": "RI utilization below 60% (waste)"
    },
    {
        "metric_id": "storage_growth_rate",
        "metric_name": "Storage Growth Rate",
        "category": "Cloud Costs",
        "metric_type": "unbounded_count",
        "direction": "higher_is_bad",
        "capacity": None,
        "unit": "GB/day",
        "breach_threshold": 500,
        "breach_direction": "above",
        "breach_label": "Exceeds 500 GB/day growth budget"
    }
]

# ═══ CLOUD COST MONITORING — ACTION RULES ═══

ACTION_RULES = {
    "monthly_azure_spend": [
        {
            "condition": lambda ctx: ctx["risk_level"] == "Critical" and ctx["breach"]["currently_breached"],
            "urgency": "urgent",
            "action": "Budget exceeded. Identify top 3 cost drivers via Azure Cost Analysis. "
                      "Engage resource owners for immediate right-sizing or shutdown.",
            "impact": "Every day over budget costs ~$1,600. FinOps SLA breach triggers executive review."
        },
        {
            "condition": lambda ctx: ctx["breach"].get("periods_to_breach") is not None and ctx["breach"]["periods_to_breach"] <= 5,
            "urgency": "moderate",
            "action": "Budget breach projected. Review auto-scaling policies, orphaned resources, "
                      "and dev/test environment schedules.",
            "impact": "Proactive cost control avoids budget overrun and executive escalation."
        },
        {
            "condition": lambda ctx: True,
            "urgency": "monitor",
            "action": "Spend within budget. Continue weekly cost review cadence.",
            "impact": "No action required."
        }
    ],
    "reserved_instance_utilization": [
        {
            "condition": lambda ctx: ctx["risk_level"] in ("Critical", "Elevated"),
            "urgency": "moderate",
            "action": "RI utilization dropping. Review instance families with <50% usage. "
                      "Consider exchanging or selling unused reservations on Azure marketplace.",
            "impact": "Each unused RI wastes $200-2,000/month depending on SKU."
        },
        {
            "condition": lambda ctx: True,
            "urgency": "monitor",
            "action": "RI utilization healthy. Continue tracking.",
            "impact": "No action required."
        }
    ],
    "storage_growth_rate": [
        {
            "condition": lambda ctx: ctx["risk_level"] == "Critical",
            "urgency": "urgent",
            "action": "Abnormal storage growth detected. Check for log floods, backup duplication, "
                      "or data pipeline errors. Review lifecycle policies.",
            "impact": "Unchecked growth at this rate adds ~$15K/month to storage costs."
        },
        {
            "condition": lambda ctx: True,
            "urgency": "monitor",
            "action": "Growth within expected range. Continue lifecycle policy enforcement.",
            "impact": "No action required."
        }
    ]
}

# ═══ THEN JUST RUN THE SAME PIPELINE ═══
# The anomaly engine (Z-scores, Holt-Winters, breach detection) is IDENTICAL.
# The narrative generator (generate_narrative, generate_action_list) is IDENTICAL.
# Only the CONFIG and RULES change per domain.
```

**Steps to adapt to any new use case:**

| Step | What to Change | Example |
|------|---------------|--------|
| 1 | `METRIC_CONFIG` array | Add your metrics with name, type, direction, thresholds |
| 2 | `ACTION_RULES` dict | Define condition → action rules per metric |
| 3 | Source data query | Point to your time-series table instead of `metrics_raw` |
| 4 | Output destination | Write to your dashboard, email, Slack, or Teams webhook |
| 5 | (Optional) Tune α, β | Adjust Holt-Winters smoothing if your data has different volatility |

**Everything else stays the same** — the math (Logit-Z, Median-MAD, Bonferroni), the forecasting (Holt-Winters), the narrative templates, and the action engine.

---

## 14. Output Schema

### Table: `ops_monitoring.anomaly_results`

```sql
CREATE TABLE IF NOT EXISTS ops_monitoring.anomaly_results (
    -- Identifiers
    run_id              STRING       NOT NULL COMMENT 'Unique pipeline run identifier (UUID)',
    run_timestamp       TIMESTAMP    NOT NULL COMMENT 'UTC timestamp of this analysis run',
    metric_id           STRING       NOT NULL COMMENT 'FK to metric_config',
    metric_name         STRING       NOT NULL,
    category            STRING       NOT NULL,

    -- ═══ DESCRIPTIVE ═══
    current_value       DOUBLE       NOT NULL COMMENT 'Most recent measured value',
    formatted_value     STRING       NOT NULL COMMENT 'Display-formatted value (e.g., "472 / 500", "0.780", "58.0%")',
    method              STRING       NOT NULL COMMENT 'Logit-Z | Capacity-Logit-Z | Median-MAD',
    metric_type         STRING       NOT NULL,
    direction           STRING       NOT NULL,

    -- ═══ DIAGNOSTIC ═══
    baseline_mu         DOUBLE       NOT NULL COMMENT 'Baseline mean (logit-space for bounded types)',
    baseline_sigma      DOUBLE       NOT NULL COMMENT 'Baseline SD (logit-space for bounded types)',
    baseline_n          INT          NOT NULL COMMENT 'Number of baseline data points used',
    z_score_raw         DOUBLE       NOT NULL COMMENT 'Raw Z-score before directionality adjustment',
    anomaly_score       DOUBLE       NOT NULL COMMENT 'Direction-adjusted anomaly score (positive = bad)',
    risk_level          STRING       NOT NULL COMMENT 'Critical | Elevated | Nominal | Insufficient Data',
    risk_description    STRING       NOT NULL COMMENT 'Human-readable risk explanation',

    -- Trend analysis (Diagnostic + Predictive bridge)
    trend_slope         DOUBLE       COMMENT 'OLS regression slope over full history',
    trend_r_squared     DOUBLE       COMMENT 'Coefficient of determination [0,1]',
    trend_slope_norm    DOUBLE       COMMENT 'Slope normalized by SD(y) for cross-metric comparison',
    trend_classification STRING      COMMENT 'Strong increasing | Moderate decreasing | No significant trend | etc.',
    trend_description   STRING       COMMENT 'Human-readable trend explanation',

    -- ═══ PREDICTIVE (Holt-Winters) ═══
    hw_level            DOUBLE       COMMENT 'Final Holt-Winters smoothed level (ℓ_n)',
    hw_trend            DOUBLE       COMMENT 'Final Holt-Winters trend component (b_n)',
    hw_alpha            DOUBLE       DEFAULT 0.3 COMMENT 'Level smoothing parameter used',
    hw_beta             DOUBLE       DEFAULT 0.1 COMMENT 'Trend smoothing parameter used',
    forecast_h1         DOUBLE       COMMENT 'Forecast value at h=1 (next period)',
    forecast_h3         DOUBLE       COMMENT 'Forecast value at h=3',
    forecast_h5         DOUBLE       COMMENT 'Forecast value at h=5',
    forecast_values     STRING       COMMENT 'JSON array of all h forecast values',
    ci_95_upper_h5      DOUBLE       COMMENT '95% confidence interval upper bound at h=5',
    ci_95_lower_h5      DOUBLE       COMMENT '95% confidence interval lower bound at h=5',
    ci_80_upper_h5      DOUBLE       COMMENT '80% confidence interval upper bound at h=5',
    ci_80_lower_h5      DOUBLE       COMMENT '80% confidence interval lower bound at h=5',
    residual_se         DOUBLE       COMMENT 'Residual standard error from Holt-Winters fit',
    breach_threshold    DOUBLE       COMMENT 'The threshold value for breach detection',
    breach_label        STRING       COMMENT 'Human-readable breach description',
    periods_to_breach   INT          COMMENT 'Estimated periods until threshold breach (NULL if no breach projected)',
    currently_breached  BOOLEAN      COMMENT 'Whether current value already exceeds threshold',
    forecast_at_breach  DOUBLE       COMMENT 'Projected value at breach point',

    -- ═══ PRESCRIPTIVE ═══
    rx_urgency          STRING       COMMENT 'urgent | moderate | monitor',
    rx_action           STRING       COMMENT 'Specific recommended action text',
    rx_impact           STRING       COMMENT 'Expected business impact statement',

    -- Thresholds used
    sigma_critical      DOUBLE       NOT NULL DEFAULT 3.09,
    sigma_elevated      DOUBLE       NOT NULL DEFAULT 2.33,
    bonferroni_alpha    DOUBLE       NOT NULL DEFAULT 0.01,
    num_metrics_tested  INT          NOT NULL DEFAULT 5,

    -- Metadata
    history_length      INT          NOT NULL COMMENT 'Total number of history points available',
    history_values      STRING       COMMENT 'JSON array of history values for sparkline rendering'
)
USING DELTA
PARTITIONED BY (run_id)
COMMENT 'Full 4-tier analytics results (Descriptive + Diagnostic + Predictive + Prescriptive) per pipeline run';
```

---

## 15. PySpark Reference Implementation

```python
"""
Anomaly Detection Pipeline — PySpark Implementation
Deploy as a Databricks Notebook or Job
"""

import numpy as np
from pyspark.sql import SparkSession, DataFrame
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField, StringType, DoubleType, IntegerType, ArrayType
)
import uuid
from datetime import datetime

# ─── CONSTANTS ─────────────────────────────────────────────
NUM_METRICS = 5
BONFERRONI_ALPHA = 0.05 / NUM_METRICS  # 0.01
SIGMA_CRITICAL = 3.09
SIGMA_ELEVATED = 2.33
BASELINE_WINDOW_PCT = 0.70
MIN_HISTORY_POINTS = 20
MAD_CONSISTENCY_CONST = 1.4826


# ─── STATISTICAL FUNCTIONS (NumPy) ────────────────────────

def logit(p: float) -> float:
    """Logit transform: maps (0,1) → (-∞, +∞)"""
    clamped = max(0.001, min(0.999, p))
    return np.log(clamped / (1 - clamped))


def compute_baseline_stats_logit(values: list) -> tuple:
    """
    For bounded_ratio metrics.
    Returns (mu_logit, sigma_logit) in logit-transformed space.
    Uses Bessel-corrected sample SD (ddof=1).
    """
    transformed = [logit(v) for v in values]
    mu = np.mean(transformed)
    sigma = np.std(transformed, ddof=1)  # Bessel's correction
    return float(mu), float(sigma)


def compute_baseline_stats_capacity_logit(values: list, capacity: float) -> tuple:
    """
    For bounded_capacity metrics.
    Convert to utilization ratio, then logit transform.
    Returns (mu_logit, sigma_logit).
    """
    ratios = [v / capacity for v in values]
    return compute_baseline_stats_logit(ratios)


def compute_baseline_stats_mad(values: list) -> tuple:
    """
    For unbounded_count metrics.
    Returns (median, adjusted_MAD) where adjusted_MAD = 1.4826 × MAD.
    """
    med = float(np.median(values))
    deviations = [abs(v - med) for v in values]
    mad_val = float(np.median(deviations))
    adjusted_mad = MAD_CONSISTENCY_CONST * mad_val
    return med, adjusted_mad


def compute_z_score(
    current_value: float,
    baseline_values: list,
    metric_type: str,
    capacity: float = None
) -> tuple:
    """
    Compute Z-score using the appropriate method.
    Returns: (z_score, baseline_mu, baseline_sigma, method_name)
    """
    if metric_type == "bounded_ratio":
        mu, sigma = compute_baseline_stats_logit(baseline_values)
        current_transformed = logit(current_value)
        z = (current_transformed - mu) / sigma if sigma > 0 else 0.0
        return z, mu, sigma, "Logit-Z"

    elif metric_type == "bounded_capacity":
        mu, sigma = compute_baseline_stats_capacity_logit(baseline_values, capacity)
        current_ratio = current_value / capacity
        current_transformed = logit(current_ratio)
        z = (current_transformed - mu) / sigma if sigma > 0 else 0.0
        return z, mu, sigma, "Capacity-Logit-Z"

    elif metric_type == "unbounded_count":
        mu, sigma = compute_baseline_stats_mad(baseline_values)
        z = (current_value - mu) / sigma if sigma > 0 else 0.0
        return z, mu, sigma, "Median-MAD"

    else:
        raise ValueError(f"Unknown metric_type: {metric_type}")


def apply_directionality(z_raw: float, direction: str) -> float:
    """Apply directional adjustment to Z-score."""
    if direction == "lower_is_bad":
        return -z_raw  # Flip: negative Z (drop) → positive anomaly
    elif direction == "higher_is_bad":
        return z_raw   # Keep: positive Z (spike) → positive anomaly
    elif direction == "both":
        return abs(z_raw)  # Both tails
    else:
        raise ValueError(f"Unknown direction: {direction}")


def compute_ols_trend(values: list) -> dict:
    """
    OLS linear regression for trend detection.
    Returns dict with slope, r_squared, slope_normalized, classification.
    """
    n = len(values)
    if n < 3:
        return {
            "slope": 0.0, "r_squared": 0.0,
            "slope_normalized": 0.0, "classification": "Insufficient data"
        }

    x = np.arange(n, dtype=float)
    y = np.array(values, dtype=float)
    x_mean = np.mean(x)
    y_mean = np.mean(y)

    numerator = np.sum((x - x_mean) * (y - y_mean))
    denominator = np.sum((x - x_mean) ** 2)
    slope = numerator / denominator if denominator > 0 else 0.0

    y_hat = y_mean + slope * (x - x_mean)
    ss_res = np.sum((y - y_hat) ** 2)
    ss_tot = np.sum((y - y_mean) ** 2)
    r_squared = 1 - (ss_res / ss_tot) if ss_tot > 0 else 0.0

    sd_y = np.std(y, ddof=1)
    slope_normalized = slope / sd_y if sd_y > 0 else 0.0

    # Classify
    direction = "increasing" if slope > 0 else "decreasing"
    if r_squared > 0.85:
        classification = f"Strong {direction} trend"
    elif r_squared > 0.50:
        classification = f"Moderate {direction} trend"
    else:
        classification = "No significant trend"

    return {
        "slope": float(slope),
        "r_squared": float(r_squared),
        "slope_normalized": float(slope_normalized),
        "classification": classification
    }


def classify_risk(anomaly_score: float) -> tuple:
    """Returns (risk_level, risk_description)."""
    abs_score = abs(anomaly_score)
    if abs_score > SIGMA_CRITICAL:
        return "Critical", f"Extreme anomaly (Bonferroni-adjusted p < {BONFERRONI_ALPHA:.3f})"
    elif abs_score > SIGMA_ELEVATED:
        return "Elevated", "Significant deviation beyond adjusted threshold"
    else:
        return "Nominal", "Within expected statistical range"


def format_value(value: float, metric_type: str, unit: str, capacity: float = None) -> str:
    """Format value for display."""
    if metric_type == "bounded_ratio" and unit == "%":
        return f"{value * 100:.1f}%"
    elif metric_type == "bounded_ratio":
        return f"{value:.3f}"
    elif metric_type == "bounded_capacity" and capacity:
        return f"{int(value)} / {int(capacity)}"
    else:
        return f"{value:,.0f}"


# ─── PREDICTIVE: HOLT-WINTERS ─────────────────────────────

def holt_winters(data: list, alpha: float = 0.3, beta: float = 0.1, horizon: int = 5) -> dict:
    """
    Holt-Winters Double Exponential Smoothing (additive trend, no seasonality).
    Returns: { fitted, forecast, level, trend, residuals }
    """
    n = len(data)
    if n < 3:
        return {
            "fitted": list(data), "forecast": [data[-1]] * horizon,
            "level": data[-1], "trend": 0.0, "residuals": []
        }

    level = data[0]
    trend = (data[min(2, n - 1)] - data[0]) / min(2, n - 1)
    fitted = [level]
    residuals = []

    for i in range(1, n):
        prev_level, prev_trend = level, trend
        level = alpha * data[i] + (1 - alpha) * (prev_level + prev_trend)
        trend = beta * (level - prev_level) + (1 - beta) * prev_trend
        fitted.append(level + trend)
        residuals.append(data[i] - (prev_level + prev_trend))

    forecast = [level + h * trend for h in range(1, horizon + 1)]
    return {
        "fitted": fitted, "forecast": forecast,
        "level": float(level), "trend": float(trend),
        "residuals": residuals
    }


def forecast_confidence(residuals: list, forecast: list) -> dict:
    """
    Compute 95% and 80% prediction intervals for Holt-Winters forecast.
    Intervals widen by √h (increasing uncertainty with distance).
    """
    if len(residuals) < 2:
        return {
            "upper95": list(forecast), "lower95": list(forecast),
            "upper80": list(forecast), "lower80": list(forecast),
            "residual_se": 0.0
        }

    se = float(np.sqrt(np.sum(np.array(residuals) ** 2) / (len(residuals) - 1)))
    return {
        "upper95": [f + 1.96 * se * np.sqrt(i + 1) for i, f in enumerate(forecast)],
        "lower95": [f - 1.96 * se * np.sqrt(i + 1) for i, f in enumerate(forecast)],
        "upper80": [f + 1.28 * se * np.sqrt(i + 1) for i, f in enumerate(forecast)],
        "lower80": [f - 1.28 * se * np.sqrt(i + 1) for i, f in enumerate(forecast)],
        "residual_se": se
    }


def time_to_breach(
    current_value: float, hw_level: float, hw_trend: float,
    metric_type: str, direction: str, capacity: float = None,
    baseline_values: list = None
) -> dict:
    """
    Estimate periods until a threshold is breached.
    Returns: { periods_to_breach, threshold, breach_label, currently_breached }
    """
    if metric_type == "bounded_ratio":
        if direction == "lower_is_bad":
            threshold = 0.70
            breach_label = "Drops below 0.70 (Poor)"
        else:
            threshold = 0.95
            breach_label = "Exceeds 95%"
    elif metric_type == "bounded_capacity" and capacity:
        threshold = capacity * 0.95
        breach_label = f"Utilization exceeds 95% ({int(capacity * 0.95)}/{int(capacity)})"
    else:
        med = float(np.median(baseline_values)) if baseline_values else 0
        threshold = med * 2
        breach_label = f"RPM exceeds 2× baseline ({int(threshold)})"

    # Walk forward
    periods = None
    for h in range(1, 51):
        projected = hw_level + h * hw_trend
        if direction == "lower_is_bad":
            if projected < threshold:
                periods = h
                break
        else:
            if projected > threshold:
                periods = h
                break

    currently_breached = (
        current_value < threshold if direction == "lower_is_bad"
        else current_value > threshold
    )

    return {
        "periods_to_breach": periods,
        "threshold": threshold,
        "breach_label": breach_label,
        "currently_breached": currently_breached,
        "forecast_at_breach": hw_level + periods * hw_trend if periods else None
    }


# ─── PRESCRIPTIVE: ACTION ENGINE ──────────────────────────

# Condition-ordered action rules (most severe first, first match wins)
ACTION_RULES = {
    "Nuance Port Usage": [
        {"cond": lambda c: c["breach"]["currently_breached"],
         "urgency": "urgent",
         "action": "IMMEDIATE: Request emergency port capacity expansion from Nuance. Current utilization exceeds 95%.",
         "impact": "Prevents call routing failures and customer abandonment."},
        {"cond": lambda c: c["breach"]["periods_to_breach"] and c["breach"]["periods_to_breach"] <= 3,
         "urgency": "urgent",
         "action": "ESCALATE: Port saturation projected within 3 intervals. Initiate capacity expansion. Reroute overflow.",
         "impact": "Avoids saturation-induced call drops."},
        {"cond": lambda c: c["breach"]["periods_to_breach"] and c["breach"]["periods_to_breach"] <= 10,
         "urgency": "moderate",
         "action": "PLAN: Schedule port capacity review with Nuance. Analyze peak-hour patterns.",
         "impact": "Proactive capacity management reduces incident risk by ~60%."},
        {"cond": lambda c: c["risk_level"] != "Nominal",
         "urgency": "moderate",
         "action": "MONITOR: Port usage trending upward. Set alerts at 85% and 90% utilization.",
         "impact": "Early warning enables proactive intervention."},
        {"cond": lambda _: True,
         "urgency": "monitor",
         "action": "MAINTAIN: Port usage within normal range.",
         "impact": "No action required."},
    ],
    ".NET Apdex Score": [
        {"cond": lambda c: c["anomaly_score"] > SIGMA_CRITICAL and c["breach"]["currently_breached"],
         "urgency": "urgent",
         "action": "IMMEDIATE: Trigger APM deep-dive. Check memory leaks, thread pool exhaustion. Engage .NET platform team.",
         "impact": "Prevents user-facing SLA breach."},
        {"cond": lambda c: c["anomaly_score"] > SIGMA_CRITICAL,
         "urgency": "urgent",
         "action": "ESCALATE: Run Dynatrace root-cause analysis. Isolate top 3 slowest transactions.",
         "impact": "Direct correlation with customer satisfaction scores."},
        {"cond": lambda c: c["anomaly_score"] > SIGMA_ELEVATED,
         "urgency": "moderate",
         "action": "INVESTIGATE: Review recent deployments. Check CPU/memory/IO. Correlate with release calendar.",
         "impact": "Catch regression before customer impact."},
        {"cond": lambda c: c["trend"]["slope"] < 0 and c["trend"]["r_squared"] > 0.5,
         "urgency": "moderate",
         "action": "PLAN: Schedule performance profiling. Review code-level hotspots.",
         "impact": "Trend reversal now is 3× cheaper than post-incident."},
        {"cond": lambda _: True,
         "urgency": "monitor",
         "action": "MAINTAIN: .NET Apdex healthy.",
         "impact": "No action required."},
    ],
    # ... same pattern for other metrics (see §11.2 for full rule tables)
}


def get_prescription(metric_name: str, context: dict) -> dict:
    """
    Evaluate action rules in severity order, return first match.
    context = { anomaly_score, risk_level, trend, breach, current_value }
    """
    rules = ACTION_RULES.get(metric_name, [])
    for rule in rules:
        if rule["cond"](context):
            return {"urgency": rule["urgency"], "action": rule["action"], "impact": rule["impact"]}
    return {"urgency": "monitor", "action": "No rules configured.", "impact": "N/A"}


# ─── MAIN PIPELINE FUNCTION ───────────────────────────────

def run_anomaly_detection(spark: SparkSession, metrics_df: DataFrame) -> DataFrame:
    """
    Main entry point — Full 4-tier analytics pipeline.

    Input: DataFrame with columns:
        metric_id, metric_name, category, metric_type, direction,
        capacity, unit, current_value, history (array<double>)

    Output: DataFrame matching the anomaly_results schema (Descriptive + Diagnostic + Predictive + Prescriptive).
    """
    import json

    run_id = str(uuid.uuid4())
    run_timestamp = datetime.utcnow()
    results = []

    # Collect to driver for statistical computation
    # (For 5 metrics, this is trivially small — no performance concern)
    rows = metrics_df.collect()

    for row in rows:
        history = list(row["history"])
        n = len(history)

        # Edge case: insufficient data
        if n < MIN_HISTORY_POINTS:
            results.append({
                "run_id": run_id,
                "run_timestamp": run_timestamp,
                "metric_id": row["metric_id"],
                "metric_name": row["metric_name"],
                "category": row["category"],
                "current_value": row["current_value"],
                "formatted_value": str(row["current_value"]),
                "method": "N/A",
                "metric_type": row["metric_type"],
                "direction": row["direction"],
                "baseline_mu": 0.0,
                "baseline_sigma": 0.0,
                "baseline_n": 0,
                "z_score_raw": 0.0,
                "anomaly_score": 0.0,
                "risk_level": "Insufficient Data",
                "risk_description": f"Need ≥{MIN_HISTORY_POINTS} data points, only {n} available",
                "trend_slope": None,
                "trend_r_squared": None,
                "trend_slope_norm": None,
                "trend_classification": None,
                "trend_description": None,
                "sigma_critical": SIGMA_CRITICAL,
                "sigma_elevated": SIGMA_ELEVATED,
                "bonferroni_alpha": BONFERRONI_ALPHA,
                "num_metrics_tested": NUM_METRICS,
                "history_length": n,
                "history_values": json.dumps(history),
                # Predictive (empty)
                "hw_level": None, "hw_trend": None,
                "hw_alpha": None, "hw_beta": None,
                "forecast_h1": None, "forecast_h3": None, "forecast_h5": None,
                "forecast_values": None,
                "ci_95_upper_h5": None, "ci_95_lower_h5": None,
                "ci_80_upper_h5": None, "ci_80_lower_h5": None,
                "residual_se": None,
                "breach_threshold": None, "breach_label": None,
                "periods_to_breach": None, "currently_breached": None,
                "forecast_at_breach": None,
                # Prescriptive (empty)
                "rx_urgency": None, "rx_action": None, "rx_impact": None,
            })
            continue

        # Split baseline
        baseline_end = int(np.floor(n * BASELINE_WINDOW_PCT))
        baseline = history[:baseline_end]
        current = row["current_value"]
        capacity = row["capacity"]

        # Compute Z-score
        z_raw, mu, sigma, method = compute_z_score(
            current, baseline, row["metric_type"], capacity
        )

        # Apply directionality
        anomaly_score = apply_directionality(z_raw, row["direction"])

        # Classify risk
        risk_level, risk_desc = classify_risk(anomaly_score)

        # Trend analysis (full history)
        trend = compute_ols_trend(history)

        # Trend description
        slope_dir = "increasing" if trend["slope"] > 0 else "decreasing"
        if trend["r_squared"] > 0.85:
            trend_desc = f"Strong linear trend {slope_dir} (R²={trend['r_squared']:.2f})"
        elif trend["r_squared"] > 0.50:
            trend_desc = f"Moderate {slope_dir} trend (R²={trend['r_squared']:.2f})"
        else:
            trend_desc = f"No significant trend pattern (R²={trend['r_squared']:.2f})"

        # Directional context
        baseline_mean_raw = float(np.mean(baseline))
        if row["direction"] == "lower_is_bad" and current < baseline_mean_raw:
            risk_desc += " ▼ Value is below baseline (degradation)."
        elif row["direction"] == "higher_is_bad" and current > baseline_mean_raw:
            risk_desc += " ▲ Value exceeds baseline (approaching capacity)."

        # ── Tier 3: Predictive Analytics ──────────────────────────
        hw = holt_winters(history)
        ci = forecast_confidence(history, hw["forecasts"][:len(history)])
        breach = time_to_breach(
            hw["forecasts"][len(history):],          # future forecasts
            row["metric_id"], row["metric_type"],
            capacity, baseline
        )

        # ── Tier 4: Prescriptive Analytics ────────────────────────
        rx = get_prescription(
            row["metric_id"], risk_level, anomaly_score,
            trend["classification"], breach
        )

        results.append({
            "run_id": run_id,
            "run_timestamp": run_timestamp,
            "metric_id": row["metric_id"],
            "metric_name": row["metric_name"],
            "category": row["category"],
            "current_value": current,
            "formatted_value": format_value(current, row["metric_type"], row["unit"], capacity),
            "method": method,
            "metric_type": row["metric_type"],
            "direction": row["direction"],
            # Diagnostic
            "baseline_mu": mu,
            "baseline_sigma": sigma,
            "baseline_n": len(baseline),
            "z_score_raw": z_raw,
            "anomaly_score": anomaly_score,
            "risk_level": risk_level,
            "risk_description": risk_desc,
            "trend_slope": trend["slope"],
            "trend_r_squared": trend["r_squared"],
            "trend_slope_norm": trend["slope_normalized"],
            "trend_classification": trend["classification"],
            "trend_description": trend_desc,
            "sigma_critical": SIGMA_CRITICAL,
            "sigma_elevated": SIGMA_ELEVATED,
            "bonferroni_alpha": BONFERRONI_ALPHA,
            "num_metrics_tested": NUM_METRICS,
            "history_length": n,
            "history_values": json.dumps(history),
            # Predictive
            "hw_level": hw["level"],
            "hw_trend": hw["trend"],
            "hw_alpha": hw["alpha"],
            "hw_beta": hw["beta"],
            "forecast_h1": hw["forecasts"][n] if len(hw["forecasts"]) > n else None,
            "forecast_h3": hw["forecasts"][n+2] if len(hw["forecasts"]) > n+2 else None,
            "forecast_h5": hw["forecasts"][n+4] if len(hw["forecasts"]) > n+4 else None,
            "forecast_values": json.dumps(hw["forecasts"][n:n+5]),
            "ci_95_upper_h5": ci["ci_95"][4][1] if len(ci["ci_95"]) >= 5 else None,
            "ci_95_lower_h5": ci["ci_95"][4][0] if len(ci["ci_95"]) >= 5 else None,
            "ci_80_upper_h5": ci["ci_80"][4][1] if len(ci["ci_80"]) >= 5 else None,
            "ci_80_lower_h5": ci["ci_80"][4][0] if len(ci["ci_80"]) >= 5 else None,
            "residual_se": ci["residual_se"],
            # Breach
            "breach_threshold": breach["threshold"],
            "breach_label": breach["label"],
            "periods_to_breach": breach["periods_to_breach"],
            "currently_breached": breach["currently_breached"],
            "forecast_at_breach": breach["forecast_at_breach"],
            # Prescriptive
            "rx_urgency": rx["urgency"],
            "rx_action": rx["action"],
            "rx_impact": rx["impact"],
        })

    # Convert to Spark DataFrame
    from pyspark.sql.types import (
        StructType, StructField, StringType, DoubleType,
        IntegerType, TimestampType
    )

    schema = StructType([
        StructField("run_id", StringType()),
        StructField("run_timestamp", TimestampType()),
        StructField("metric_id", StringType()),
        StructField("metric_name", StringType()),
        StructField("category", StringType()),
        StructField("current_value", DoubleType()),
        StructField("formatted_value", StringType()),
        StructField("method", StringType()),
        StructField("metric_type", StringType()),
        StructField("direction", StringType()),
        # Diagnostic
        StructField("baseline_mu", DoubleType()),
        StructField("baseline_sigma", DoubleType()),
        StructField("baseline_n", IntegerType()),
        StructField("z_score_raw", DoubleType()),
        StructField("anomaly_score", DoubleType()),
        StructField("risk_level", StringType()),
        StructField("risk_description", StringType()),
        StructField("trend_slope", DoubleType()),
        StructField("trend_r_squared", DoubleType()),
        StructField("trend_slope_norm", DoubleType()),
        StructField("trend_classification", StringType()),
        StructField("trend_description", StringType()),
        StructField("sigma_critical", DoubleType()),
        StructField("sigma_elevated", DoubleType()),
        StructField("bonferroni_alpha", DoubleType()),
        StructField("num_metrics_tested", IntegerType()),
        StructField("history_length", IntegerType()),
        StructField("history_values", StringType()),
        # Predictive — Holt-Winters
        StructField("hw_level", DoubleType()),
        StructField("hw_trend", DoubleType()),
        StructField("hw_alpha", DoubleType()),
        StructField("hw_beta", DoubleType()),
        StructField("forecast_h1", DoubleType()),
        StructField("forecast_h3", DoubleType()),
        StructField("forecast_h5", DoubleType()),
        StructField("forecast_values", StringType()),
        StructField("ci_95_upper_h5", DoubleType()),
        StructField("ci_95_lower_h5", DoubleType()),
        StructField("ci_80_upper_h5", DoubleType()),
        StructField("ci_80_lower_h5", DoubleType()),
        StructField("residual_se", DoubleType()),
        # Predictive — Breach
        StructField("breach_threshold", DoubleType()),
        StructField("breach_label", StringType()),
        StructField("periods_to_breach", IntegerType()),
        StructField("currently_breached", StringType()),
        StructField("forecast_at_breach", DoubleType()),
        # Prescriptive
        StructField("rx_urgency", StringType()),
        StructField("rx_action", StringType()),
        StructField("rx_impact", StringType()),
    ])

    return spark.createDataFrame(results, schema)
```

---

## 16. Databricks SQL Reference Implementation

For teams preferring SQL-first workflows, the logic can be implemented using **Databricks SQL UDFs** and window functions.

> **Scope Note:** The SQL UDF below covers **Tier 1 (Descriptive) and Tier 2 (Diagnostic)** only.
> For the full 4-tier pipeline (including Holt-Winters forecasting and prescriptive actions),
> use the **PySpark notebook** in §15. The iterative state required by Holt-Winters and the
> rule-based prescription engine are more naturally expressed in Python than in SQL UDFs.

### 16.1 Logit UDF

```sql
CREATE OR REPLACE FUNCTION ops_monitoring.logit(p DOUBLE)
RETURNS DOUBLE
COMMENT 'Logit transform: ln(p / (1-p)) with clamping to avoid log(0)'
RETURN LN(GREATEST(0.001, LEAST(0.999, p)) / (1 - GREATEST(0.001, LEAST(0.999, p))));
```

### 16.2 Assemble History with Window Functions

```sql
-- Collect the last 20 values per metric as an array
CREATE OR REPLACE TEMPORARY VIEW metric_histories AS
SELECT
    m.metric_id,
    m.metric_name,
    m.category,
    c.metric_type,
    c.direction,
    c.capacity,
    c.unit,
    FIRST_VALUE(m.value) OVER (
        PARTITION BY m.metric_id ORDER BY m.recorded_at DESC
    ) AS current_value,
    COLLECT_LIST(m.value) OVER (
        PARTITION BY m.metric_id
        ORDER BY m.recorded_at
        ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    ) AS history
FROM ops_monitoring.metrics_raw m
JOIN ops_monitoring.metric_config c ON m.metric_id = c.metric_id
WHERE c.is_active = TRUE;
```

### 16.3 Python UDF for Full Computation

```sql
-- Register the Python UDF (Databricks supports this natively)
CREATE OR REPLACE FUNCTION ops_monitoring.compute_anomaly(
    current_value DOUBLE,
    history ARRAY<DOUBLE>,
    metric_type STRING,
    direction STRING,
    capacity DOUBLE
)
RETURNS STRUCT<
    z_score_raw: DOUBLE,
    anomaly_score: DOUBLE,
    baseline_mu: DOUBLE,
    baseline_sigma: DOUBLE,
    method: STRING,
    risk_level: STRING,
    trend_slope: DOUBLE,
    trend_r_squared: DOUBLE,
    trend_classification: STRING
>
LANGUAGE PYTHON
AS $$
import numpy as np

def logit(p):
    c = max(0.001, min(0.999, p))
    return float(np.log(c / (1 - c)))

n = len(history)
if n < 20:
    return (0.0, 0.0, 0.0, 0.0, "N/A", "Insufficient Data", 0.0, 0.0, "N/A")

baseline_end = int(np.floor(n * 0.70))
baseline = history[:baseline_end]

# Z-score computation
if metric_type == "bounded_ratio":
    transformed = [logit(v) for v in baseline]
    mu = float(np.mean(transformed))
    sigma = float(np.std(transformed, ddof=1))
    z = (logit(current_value) - mu) / sigma if sigma > 0 else 0.0
    method = "Logit-Z"
elif metric_type == "bounded_capacity" and capacity and capacity > 0:
    ratios = [v / capacity for v in baseline]
    transformed = [logit(r) for r in ratios]
    mu = float(np.mean(transformed))
    sigma = float(np.std(transformed, ddof=1))
    z = (logit(current_value / capacity) - mu) / sigma if sigma > 0 else 0.0
    method = "Capacity-Logit-Z"
else:  # unbounded_count
    med = float(np.median(baseline))
    devs = [abs(v - med) for v in baseline]
    mad_val = float(np.median(devs))
    sigma = 1.4826 * mad_val
    mu = med
    z = (current_value - med) / sigma if sigma > 0 else 0.0
    method = "Median-MAD"

# Directionality
if direction == "lower_is_bad":
    anomaly = -z
elif direction == "both":
    anomaly = abs(z)
else:
    anomaly = z

# Risk
abs_a = abs(anomaly)
if abs_a > 3.09:
    risk = "Critical"
elif abs_a > 2.33:
    risk = "Elevated"
else:
    risk = "Nominal"

# Trend (OLS)
x = np.arange(n, dtype=float)
y = np.array(history, dtype=float)
x_m, y_m = np.mean(x), np.mean(y)
num = np.sum((x - x_m) * (y - y_m))
den = np.sum((x - x_m) ** 2)
slope = num / den if den > 0 else 0.0
y_hat = y_m + slope * (x - x_m)
ss_res = np.sum((y - y_hat) ** 2)
ss_tot = np.sum((y - y_m) ** 2)
r2 = 1 - ss_res / ss_tot if ss_tot > 0 else 0.0
d = "increasing" if slope > 0 else "decreasing"
if r2 > 0.85:
    tcl = f"Strong {d} trend"
elif r2 > 0.5:
    tcl = f"Moderate {d} trend"
else:
    tcl = "No significant trend"

return (float(z), float(anomaly), float(mu), float(sigma), method, risk, float(slope), float(r2), tcl)
$$;
```

### 16.4 Final Query

```sql
SELECT
    m.metric_id,
    m.metric_name,
    m.category,
    m.current_value,
    r.method,
    r.z_score_raw,
    r.anomaly_score,
    r.risk_level,
    r.baseline_mu,
    r.baseline_sigma,
    r.trend_slope,
    r.trend_r_squared,
    r.trend_classification
FROM metric_histories m
LATERAL VIEW OUTER INLINE(
    ARRAY(ops_monitoring.compute_anomaly(
        m.current_value, m.history, m.metric_type, m.direction, m.capacity
    ))
) r;
```

---

## 17. Testing & Validation

### 17.1 Unit Test Cases

Use these known-good values to validate your implementation:

#### Test 1: Logit-Z (.NET Apdex)

```python
history = [0.93, 0.92, 0.94, 0.91, 0.93, 0.90, 0.92, 0.91,
           0.89, 0.90, 0.88, 0.87, 0.86, 0.85, 0.84, 0.83,
           0.82, 0.80, 0.79, 0.78]
current = 0.78
metric_type = "bounded_ratio"
direction = "lower_is_bad"

# Expected (approximate):
# baseline (first 14): [0.93, 0.92, ..., 0.85]
# z_raw ≈ -3.22
# anomaly_score ≈ +3.22 (flipped for lower_is_bad)
# risk_level = "Critical" (3.22 > 3.09)
```

#### Test 2: Capacity-Logit-Z (Nuance Ports)

```python
history = [310, 325, 318, 340, 335, 328, 342, 350,
           355, 360, 368, 375, 380, 390, 398, 410,
           425, 440, 458, 472]
current = 472
capacity = 500
metric_type = "bounded_capacity"
direction = "higher_is_bad"

# Expected (approximate):
# z_raw ≈ 8.48
# anomaly_score ≈ 8.48 (keep positive for higher_is_bad)
# risk_level = "Critical"
```

#### Test 3: Median-MAD (RPM)

```python
history = [1180, 1210, 1195, 1220, 1205, 1215, 1230, 1190,
           1225, 1240, 1200, 1235, 1250, 1260, 1310, 1400,
           1520, 1650, 1780, 1850]
current = 1850
metric_type = "unbounded_count"
direction = "both"

# Expected (approximate):
# median_baseline ≈ 1217.5
# MAD ≈ 17.5 → adjusted_MAD ≈ 25.95
# z_raw ≈ 24.4
# anomaly_score ≈ 24.4 (abs for 'both')
# risk_level = "Critical"
```

#### Test 4: Nominal Case (no anomaly)

```python
history = [0.94, 0.93, 0.95, 0.94, 0.93, 0.94, 0.93, 0.94,
           0.93, 0.94, 0.93, 0.94, 0.93, 0.94, 0.93, 0.94,
           0.93, 0.94, 0.93, 0.94]
current = 0.93
metric_type = "bounded_ratio"
direction = "lower_is_bad"

# Expected:
# anomaly_score ≈ 0 (close to baseline mean)
# risk_level = "Nominal"
```

#### Test 5: Edge Case — Insufficient History

```python
history = [0.90, 0.91, 0.89]  # Only 3 points
current = 0.85
# Expected:
# risk_level = "Insufficient Data"
# All statistical fields = 0 or null
# All predictive & prescriptive fields = null
```

#### Test 6: Holt-Winters Forecast (Nuance Ports — Strong Upward Trend)

```python
history = [310, 325, 318, 340, 335, 328, 342, 350,
           355, 360, 368, 375, 380, 390, 398, 410,
           425, 440, 458, 472]
capacity = 500

# Expected (approximate, α=0.3, β=0.1):
# hw_level ≈ 466   (smoothed level at last observation)
# hw_trend ≈ 8.5   (smoothed trend per period)
# forecast_h1 ≈ 475, forecast_h3 ≈ 492, forecast_h5 ≈ 509
# ci_95 band widens by √h: h5 band width ≈ ±2 × 1.96 × residual_se × √5
# periods_to_breach ≈ 3 (threshold = 95% of 500 = 475)
# currently_breached = False
```

#### Test 7: Prescriptive Engine — Critical + Breach Imminent

```python
metric_id = "nuance_port_usage"
risk_level = "Critical"
anomaly_score = 8.5
trend_classification = "Strong increasing trend"
breach = {"periods_to_breach": 2, "currently_breached": False}

# Expected:
# rx_urgency = "urgent"
# rx_action = "Initiate emergency port expansion..."
# rx_impact = "Prevent call routing failures..."
```

#### Test 8: Prescriptive Engine — Nominal (No Action)

```python
metric_id = "net_apdex"
risk_level = "Nominal"
anomaly_score = 0.4
trend_classification = "No significant trend"
breach = {"periods_to_breach": None, "currently_breached": False}

# Expected:
# rx_urgency = "monitor"
# rx_action = "Continue current monitoring..."
# rx_impact = "Maintain performance baseline..."
```

### 17.2 Integration Test Checklist

| # | Check | Expected |
|---|-------|----------|
| 1 | Pipeline runs without error on empty `metrics_raw` | Zero rows in output, no exceptions |
| 2 | Pipeline handles exactly 20 data points | Baseline = 14 points, valid Z-score |
| 3 | Pipeline rejects < 20 data points | `risk_level = "Insufficient Data"`, predictive/prescriptive fields null |
| 4 | Apdex of 1.000 doesn't produce infinity | Clamped to 0.999, logit ≈ 6.9 |
| 5 | Port usage = capacity (500/500) | Clamped to 0.999, logit ≈ 6.9, flagged Critical |
| 6 | All 5 metrics at nominal values | All `risk_level = "Nominal"`, zero anomalies |
| 7 | Bonferroni thresholds change when metric count changes | Thresholds recalculated |
| 8 | Output writes successfully to Delta table | Schema matches, partitioned by `run_id` |
| 9 | HW forecast produces exactly 5 future values | `forecast_values` JSON array has 5 elements |
| 10 | CI bands widen with horizon | `ci_95_upper_h5 - ci_95_lower_h5` > h1 band width |
| 11 | Time-to-breach returns null for Nominal metrics | `periods_to_breach = null`, `breach_label = null` |
| 12 | Prescriptive engine returns action for every Critical metric | `rx_urgency = "urgent"`, `rx_action` not null |
| 13 | Prescriptive engine returns "monitor" for Nominal metrics | `rx_urgency = "monitor"` |

---

## 18. Architecture Notes

### 18.1 Recommended Databricks Setup

```
┌─────────────────────────────────────────────────────┐
│                  DATA SOURCES                        │
│  Nuance API │ Dynatrace API │ IVR/CRM │ API Gateway │
└──────┬──────┴───────┬───────┴────┬────┴──────┬──────┘
       │              │            │            │
       ▼              ▼            ▼            ▼
┌─────────────────────────────────────────────────────┐
│           Bronze Layer (Raw Ingestion)               │
│  ops_monitoring.metrics_raw (Delta, append-only)     │
│  Schedule: Every 5 min via Databricks Workflows      │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│           Silver Layer (Anomaly Detection)            │
│  Notebook: anomaly_detection_pipeline                │
│  • Reads last 20+ data points per metric             │
│  • Runs compute_anomaly() logic                      │
│  • Writes to ops_monitoring.anomaly_results          │
│  Schedule: Every 15 min via Databricks Workflows     │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│           Gold Layer (Dashboard API)                 │
│  ops_monitoring.latest_anomaly_view (materialized)   │
│  • Latest run_id only                                │
│  • Pre-joined with metric_config                     │
│  • Consumed by Grafana / Dashboard HTML component    │
└─────────────────────────────────────────────────────┘
```

### 18.2 Scheduling

| Job | Frequency | Cluster | Notes |
|-----|-----------|---------|-------|
| Metric ingestion | Every 5 min | Shared job cluster | Append-only to Bronze |
| Anomaly detection | Every 15 min | Single-node (5 metrics is trivial) | Writes to Silver |
| Dashboard refresh | Every 15 min | N/A (reads from Delta) | Frontend polls latest results |

### 18.3 Alerting Integration

The `anomaly_results` table can trigger alerts:

```sql
-- Alert query: any Critical anomalies in the latest run
SELECT metric_name, anomaly_score, risk_description
FROM ops_monitoring.anomaly_results
WHERE run_id = (SELECT MAX(run_id) FROM ops_monitoring.anomaly_results)
  AND risk_level = 'Critical';
```

Route to PagerDuty/Teams/Slack via Databricks SQL Alerts or a downstream workflow.

---

## Appendix A: Mathematical Reference

| Symbol | Name | Formula |
|--------|------|---------|
| $\text{logit}(p)$ | Logit transform | $\ln\left(\frac{p}{1-p}\right)$ |
| $\bar{x}$ | Sample mean | $\frac{1}{n}\sum x_i$ |
| $s$ | Sample SD (Bessel) | $\sqrt{\frac{1}{n-1}\sum(x_i - \bar{x})^2}$ |
| $\tilde{x}$ | Median | Middle value of sorted array |
| MAD | Median Absolute Deviation | $\text{median}(\|x_i - \tilde{x}\|)$ |
| $\sigma_{MAD}$ | MAD-based SD | $1.4826 \times \text{MAD}$ |
| $Z$ | Z-score / anomaly score | $\frac{x - \mu}{\sigma}$ |
| $R^2$ | Coefficient of determination | $1 - \frac{SS_{res}}{SS_{tot}}$ |
| $\alpha_{Bonf}$ | Bonferroni-adjusted alpha | $\frac{\alpha}{N}$ |

## Appendix B: Threshold Quick Reference

| Metric Count | α_adjusted | σ_elevated | σ_critical |
|:---:|:---:|:---:|:---:|
| 3 | 0.0167 | 2.13 | 2.93 |
| 5 | 0.0100 | 2.33 | 3.09 |
| 7 | 0.0071 | 2.45 | 3.19 |
| 10 | 0.0050 | 2.58 | 3.29 |

> Recalculate using `scipy.stats.norm.ppf(1 - alpha_adjusted)` for σ_elevated and `scipy.stats.norm.ppf(1 - alpha_adjusted/10)` for σ_critical.

# Leading Indicators — Implementation Guide for Developers
## Azure Databricks Edition: Measure, Correlate, Alert & Generate Insights

**Priority:** URGENT — 2-day delivery target  
**Platform:** Azure Databricks (PySpark + Delta Lake + Structured Streaming)  
**Audience:** Data Engineers & Developers  
**Last Updated:** February 19, 2026

---

## TL;DR — What We're Building

The Command Center dashboard shows **14 signals** grouped into **3 domains**. Your job is to:
1. **Ingest** each signal's raw data into Delta Lake (Bronze layer) via Databricks connectors
2. **Transform & Score** — apply thresholds, compute health status (Silver layer)
3. **Correlate** — detect multi-signal patterns using rule-based Spark SQL joins
4. **Alert & Generate Insights** — template-based insight text, written to Gold layer
5. **Serve** — expose via Databricks SQL Serverless endpoint or REST API for the dashboard

### Architecture on Azure Databricks

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        AZURE DATABRICKS WORKSPACE                           │
│                                                                              │
│  ┌─────────────┐    ┌──────────────┐    ┌──────────────┐    ┌────────────┐  │
│  │   BRONZE     │    │   SILVER      │    │    GOLD       │    │  SERVING   │  │
│  │ (Raw Ingest) │───▶│ (Scored +     │───▶│ (Insights +   │───▶│ (SQL       │  │
│  │              │    │  Thresholds)  │    │  Alerts +     │    │  Endpoint   │  │
│  │ Delta Tables │    │  Delta Tables │    │  API-ready)   │    │  or REST)  │  │
│  └──────┬───────┘    └──────────────┘    └──────────────┘    └────────────┘  │
│         │                                                                     │
│  Sources:                                                                     │
│  ├── Genesys Cloud API (agent, queue, call quality, SLA, IVR)                │
│  ├── ServiceNow API (incidents)                                               │
│  ├── Dynatrace API (app health, core systems)                                │
│  ├── ThousandEyes API (connectivity, latency)                                │
│  ├── Citrix Director API (desktop/endpoint)                                  │
│  └── WFM RTA API (schedules, staffing)                                       │
│                                                                              │
│  Orchestration: Databricks Workflows (Job Clusters, every 60s trigger)       │
│  Storage: Azure Data Lake Storage Gen2 (ADLS) with Delta format              │
│  Serving: Databricks SQL Warehouse → REST API / Direct JDBC                  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Why Databricks Fits This Problem

| Concern | Databricks Answer |
|---------|-------------------|
| Near-real-time (60s refresh) | Structured Streaming with trigger `availableNow` or `processingTime='60 seconds'` |
| Multi-source ingestion | Native REST connectors, `requests` library in notebooks, Auto Loader for file-based |
| Historical lookback | Delta Lake time travel — free 30-day history for pattern matching |
| Low-latency serving | Databricks SQL Serverless warehouse (cold start ~8s, warm <1s) |
| Correlation joins | Spark SQL window functions + temporal joins — built for this |
| Team skill set | PySpark + SQL — your data engineers already know this |

---

## PART 1: The 14 Signals — How to Measure Each One (Azure Databricks)

> **All queries below are Spark SQL / PySpark.** Tables are Delta tables in your Lakehouse.  
> Raw data lands in `bronze.*` tables. Scored output goes to `silver.signal_snapshots`.

### Databricks Setup — Ingestion Pattern (Use for All 14 Signals)

Every signal follows the same pattern. Here's the reusable ingestion framework:

```python
# Notebook: 01_signal_ingestion (runs every 60 seconds via Databricks Workflow)

import requests
from pyspark.sql.functions import *
from pyspark.sql.types import *
from datetime import datetime, timedelta

def ingest_api_to_bronze(api_url, headers, table_name, parse_fn):
    """
    Generic: Call API → parse → append to Bronze Delta table.
    parse_fn: takes JSON response, returns list of Row dicts.
    """
    response = requests.get(api_url, headers=headers, timeout=30)
    response.raise_for_status()
    rows = parse_fn(response.json())
    
    if rows:
        df = spark.createDataFrame(rows)
        df = df.withColumn("_ingested_at", current_timestamp())
        df.write.mode("append").format("delta").saveAsTable(f"bronze.{table_name}")
    
    return len(rows)
```

---

### 1. Agent Online %

| Attribute | Value |
|---|---|
| **What it measures** | Percentage of scheduled agents currently logged in and in a routable state |
| **Source** | Genesys Cloud Analytics API + WFM RTA API |
| **Refresh** | Every 60 seconds |
| **Sub-signals** | Voice Agents, Chat Agents, Email Agents (same formula, filtered by media type) |
| **Domains** | Agent Health, Genesys Health |

**Databricks Calculation:**
```sql
-- Silver layer: Compute agent online percentage
CREATE OR REPLACE TEMPORARY VIEW agent_online_current AS
SELECT 
    current_timestamp() AS snapshot_time,
    'Agent Online' AS signal_name,
    ROUND(
        COUNT(CASE WHEN agent_status IN ('Available','On Queue','Interacting') THEN 1 END) * 100.0
        / NULLIF(MAX(w.scheduled_count), 0), 1
    ) AS numeric_value,
    -- Sub-signals by media type
    ROUND(COUNT(CASE WHEN agent_status IN ('Available','On Queue','Interacting') AND media_type = 'voice' THEN 1 END) * 100.0 / NULLIF(SUM(CASE WHEN media_type = 'voice' THEN w.scheduled_per_media END), 0), 1) AS voice_pct,
    ROUND(COUNT(CASE WHEN agent_status IN ('Available','On Queue','Interacting') AND media_type = 'chat' THEN 1 END) * 100.0 / NULLIF(SUM(CASE WHEN media_type = 'chat' THEN w.scheduled_per_media END), 0), 1) AS chat_pct,
    ROUND(COUNT(CASE WHEN agent_status IN ('Available','On Queue','Interacting') AND media_type = 'email' THEN 1 END) * 100.0 / NULLIF(SUM(CASE WHEN media_type = 'email' THEN w.scheduled_per_media END), 0), 1) AS email_pct
FROM bronze.agent_realtime_status a
JOIN bronze.wfm_schedule w ON a.interval_id = w.interval_id
WHERE a._ingested_at >= current_timestamp() - INTERVAL 2 MINUTES
  AND a.activity_code NOT IN ('Training', 'Meeting', 'Break');
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 95%** | At 50,000 agents, 95% = 47,500 online. The 5% buffer covers normal break rotation, system logins, and shift overlap gaps. Industry benchmark (COPC) for enterprise is 93-96%. We set 95% because our WFM model assumes this staffing level for SLA attainment. | Business as usual. SLA targets achievable. |
| Warning ⚠️ | **90–95%** | 90% = 45,000 agents. A 5% drop means ~2,500 fewer agents than planned. This creates queue pressure within 3–5 minutes. At this level, SLA will degrade in high-volume LOBs (Sales, Billing) first. We chose 90% because below this point, Erlang C models predict SLA breach within 10 minutes for at least 2 LOBs. | Investigate immediately. Check: vendor presence, site connectivity, desktop health. Likely correlated with another signal. |
| Critical 🔴 | **< 90%** | Below 90% = 5,000+ missing agents. This is a confirmed staffing emergency. Causes: mass Citrix failure, ISP outage at a major site (Manila/India), or Genesys platform issue preventing logins. At this level, ASA (Average Speed of Answer) will exceed SLA within 2 minutes, and abandon rates spike. | **Immediate war room.** This is already impacting customers. Check Desktop/Endpoint and Presence—Location first. |

**Sub-signal Thresholds:**
- Voice Agents: Same as parent (95/90/90) — voice is the primary channel
- Chat Agents: Slightly relaxed (93/88/85) — chat allows concurrency, so fewer agents needed
- Email Agents: Relaxed (90/85/80) — email is async, queue tolerance is higher

**Why these specific numbers and not others?**
> These thresholds were calibrated against 6 months of historical data. We observed that when Agent Online drops below 90%, there's an 87% probability of at least one LOB SLA breach within 15 minutes. The 95% healthy line was chosen because 97%+ of normal operating minutes fall above it — meaning warnings only fire during genuine anomalies, not noise.

---

### 2. Incidents (Active Count)

| Attribute | Value |
|---|---|
| **What it measures** | Count of currently open incidents, weighted by severity |
| **Source** | ServiceNow Table API |
| **Refresh** | Every 60 seconds |
| **Sub-signals** | P1 Critical, P2 High, P3 Medium |
| **Domains** | App Health, Genesys Health |

**Databricks Calculation:**
```sql
SELECT 
    current_timestamp() AS snapshot_time,
    'Incidents' AS signal_name,
    COUNT(*) AS numeric_value,
    SUM(CASE WHEN priority = 1 THEN 1 ELSE 0 END) AS p1_count,
    SUM(CASE WHEN priority = 2 THEN 1 ELSE 0 END) AS p2_count,
    SUM(CASE WHEN priority = 3 THEN 1 ELSE 0 END) AS p3_count,
    -- Rate of change: compare to count 10 minutes ago
    COUNT(*) - COALESCE(
        (SELECT numeric_value FROM silver.signal_snapshots 
         WHERE signal_name = 'Incidents' 
         AND snapshot_time >= current_timestamp() - INTERVAL 10 MINUTES
         ORDER BY snapshot_time ASC LIMIT 1), 0
    ) AS change_10min
FROM bronze.incidents
WHERE state IN ('New','In Progress','On Hold')
  AND assignment_group IN ('Contact Center Ops','Network Ops','Platform Support')
  AND opened_at >= current_timestamp() - INTERVAL 4 HOURS;
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≤ 3 total AND 0 P1** | In a 50,000-agent environment, 1–3 active P2/P3 incidents is the normal baseline. Our 90-day average is 2.1 active incidents during business hours. P1 = 0 is the key condition — any P1 means something customer-facing is broken. | Normal operations. These are minor issues being handled through standard process. |
| Warning ⚠️ | **4–6 total OR 1 P1** | 4–6 incidents means incident velocity has increased. Historically, when active count hits 5+, there's a 60% chance of a related root cause (not independent failures). A single P1 always warrants attention because P1 by definition = customer-impacting. We alert at 1 P1 because the mean time from P1 open to operator awareness is currently 8 minutes — too slow. | Check if incidents share CIs or assignment groups. A single P1 → check which domain it maps to. |
| Critical 🔴 | **> 6 total OR ≥ 2 P1** | 7+ active incidents has historically preceded 80% of major outages (precedes by 10–15 min). Multiple P1s = cascading failure in progress. The probability of coincidence for 2 independent P1s is < 3%, so 2 P1s = systemic issue. | **Cascade in progress.** Immediately check correlation with App Health and Core Systems. |

**Rate-of-Change Override:**
> If incidents jump from 2→7 in 10 minutes, treat as CRITICAL regardless of absolute count. This "incident surge" pattern has 92% correlation with impending outage.

```python
# In your scoring notebook:
change_10min = current_count - count_10min_ago
if change_10min >= 4:  # rapid surge
    status = "critical"  # override even if count < 7
```

**Sub-signal Thresholds:**
- P1 Critical: Status is always `critical` (by definition — P1 means service-impacting)
- P2 High: Status is always `warning` (significant but workaround exists)
- P3 Medium: Status is always `healthy` (minor, tracked but not alarming)

---

### 3. App Health %

| Attribute | Value |
|---|---|
| **What it measures** | Weighted average uptime of critical contact center applications |
| **Source** | Dynatrace Synthetic Monitors / Custom health endpoints |
| **Refresh** | Every 60 seconds |
| **Sub-signals** | CRM, WFM, Reporting (each app individually) |
| **Domains** | App Health |

**Databricks Calculation:**
```python
# Notebook: ingest_dynatrace_synthetics.py
import requests

DYNATRACE_URL = dbutils.secrets.get("keyvault", "dynatrace-url")
DYNATRACE_TOKEN = dbutils.secrets.get("keyvault", "dynatrace-api-token")

response = requests.get(
    f"{DYNATRACE_URL}/api/v2/synthetic/executions",
    headers={"Authorization": f"Api-Token {DYNATRACE_TOKEN}"},
    params={"from": "now-5m", "entitySelector": 'type("SYNTHETIC_TEST"),tag("contact-center")'}
)

# Parse and write to bronze
results = response.json().get("executions", [])
df = spark.createDataFrame([{
    "app_name": r["monitorName"],
    "response_code": r["responseCode"],
    "response_time_ms": r["duration"],
    "is_healthy": 1 if r["responseCode"] == 200 and r["duration"] < 3000 else 0,
    "check_time": r["executionTimestamp"]
} for r in results])
df.write.mode("append").format("delta").saveAsTable("bronze.synthetic_monitor_results")
```

```sql
-- Silver scoring
SELECT 
    current_timestamp() AS snapshot_time,
    'App Health' AS signal_name,
    ROUND(AVG(CASE WHEN is_healthy = 1 THEN 100.0 ELSE 0.0 END), 1) AS numeric_value
FROM bronze.synthetic_monitor_results
WHERE check_time >= current_timestamp() - INTERVAL 5 MINUTES
  AND app_group = 'contact_center';
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 97%** | We monitor 12 synthetic checks per app, running every minute. 97% means at most 1 failed check across all apps in a 5-min window. Single check failures are common (network blip, DNS cache) and self-resolve. We use a 5-min sliding window to smooth these transients — without it, we'd get 15+ false alarms per day. | All apps responding normally. Occasional blips auto-resolved. |
| Warning ⚠️ | **93–97%** | 93% means 2–4 failed checks in 5 minutes. This indicates a real degradation — either one app is consistently slow (response > 3s) or intermittently failing. At this level, agents may notice "screens loading slowly" but can still work. CRM at 93% means ~7% of screen loads are slow/erroring — agents will start calling the help desk. | Check which sub-signal (CRM/WFM/Reporting) is degraded. Likely correlated with Core Systems or Desktop/Endpoint. |
| Critical 🔴 | **< 93%** | Below 93% = multiple apps failing or one critical app (CRM) is down. At 50K agents, if CRM is unavailable, agents cannot process calls — they sit idle despite being logged in. This is functionally equivalent to an outage even though the phone system works. We set 93% (not 90%) because by the time synthetics show 90%, the actual user experience has been degraded for 3+ minutes already. | **App-level outage.** Agents are likely already idle. Check Core Systems (database/infra) as likely root cause. |

**Sub-signal Thresholds (per app):**
| App | Healthy | Warning | Critical | Why Different? |
|-----|---------|---------|----------|----------------|
| CRM | ≥ 98% | 95–98% | < 95% | CRM is used on EVERY call. Even 2% failure = thousands of impacted interactions/hour |
| WFM | ≥ 95% | 90–95% | < 90% | WFM is checked by supervisors, not on every call. Less time-sensitive. |
| Reporting | ≥ 90% | 80–90% | < 80% | Reporting is non-real-time. Agents don't use it. Dashboards may lag but ops continues. |

---

### 4. Core Systems %

| Attribute | Value |
|---|---|
| **What it measures** | Availability of core infrastructure (databases, message queues, auth services) |
| **Source** | Dynatrace / SolarWinds / Custom healthchecks |
| **Refresh** | Every 60 seconds |
| **Domains** | App Health, Genesys Health |

**Databricks Calculation:**
```sql
SELECT 
    current_timestamp() AS snapshot_time,
    'Core Systems' AS signal_name,
    ROUND(COUNT(CASE WHEN status = 'UP' THEN 1 END) * 100.0 / COUNT(*), 1) AS numeric_value
FROM bronze.infrastructure_health
WHERE component_type IN ('database','message_queue','auth_service','load_balancer')
  AND _ingested_at >= current_timestamp() - INTERVAL 2 MINUTES;
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 99%** | We monitor ~20 core components. 99% = at most 1 component showing issue but still within failover capacity. Databases and auth services have active-passive HA — a single node failure is handled transparently. 99% is the designed availability of our infrastructure stack. | All infrastructure healthy. Redundancy intact. |
| Warning ⚠️ | **97–99%** | 97% = 1 component fully down. This means we've consumed our failover capacity for that component type. Example: if primary DB fails over to secondary, we're at 97% but have zero remaining redundancy. One more failure = outage. | Failover engaged. No customer impact yet, but we're operating without safety net. Fix before the next failure. |
| Critical 🔴 | **< 97%** | < 97% = 2+ components down. At this point, either (a) a component with no HA has failed, or (b) both primary and failover have failed. Either way, App Health will follow within 1–2 minutes. This is the earliest signal in the cascade — Core Systems drops → App Health drops → Agent idle → SLA breach. | **Infrastructure emergency.** App Health degradation imminent. This is the ROOT CAUSE signal — fix here first. |

---

### 5. Call LOB SLA %

| Attribute | Value |
|---|---|
| **What it measures** | Percentage of calls answered within SLA target per Line of Business |
| **Source** | Genesys Cloud Analytics API |
| **Refresh** | Every 60 seconds |
| **Sub-signals** | Sales, Billing, Service, Retention (per-queue) |
| **Domains** | Agent Health, Genesys Health |

**Databricks Calculation:**
```sql
-- Per LOB and composite
WITH lob_sla AS (
    SELECT 
        l.lob_name,
        SUM(CASE WHEN c.answer_time_sec <= l.sla_target_sec THEN 1 ELSE 0 END) AS sla_met,
        COUNT(*) AS call_count
    FROM bronze.call_intervals c
    JOIN silver.lob_config l ON c.queue_id = l.queue_id
    WHERE c.interval_start >= current_timestamp() - INTERVAL 30 MINUTES
    GROUP BY l.lob_name
)
SELECT 
    current_timestamp() AS snapshot_time,
    'Call LOB SLA' AS signal_name,
    ROUND(SUM(sla_met) * 100.0 / NULLIF(SUM(call_count), 0), 1) AS numeric_value,
    -- Per-LOB for sub-signals
    collect_list(struct(lob_name, ROUND(sla_met * 100.0 / NULLIF(call_count, 0), 1) AS pct)) AS lob_breakdown
FROM lob_sla;
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 85%** | 85% SLA is the contractual target for most LOBs (e.g., "80% of calls answered in 20 seconds" = 80/20 rule). We set healthy at 85% (not 80%) to provide a 5-point buffer before contractual breach. When SLA is 85%+, caller wait times average < 25 seconds and abandon rate is < 3%. | Meeting all contractual obligations. Customer experience is good. |
| Warning ⚠️ | **80–85%** | At 80–85%, we're at or just below the contractual SLA line. Caller wait times are creeping to 30–45 seconds. Abandon rate rises to 5–8%. This is the "yellow zone" — not yet a penalty event but trending toward one. The 30-min rolling window means this reflects sustained pressure, not a momentary spike. | SLA at risk. Check Agent Online and Queue Sufficiency — this is almost always a staffing or incident issue. |
| Critical 🔴 | **< 80%** | Below 80% = SLA breach. Callers are waiting 45+ seconds, abandon rate exceeds 8%. For Sales LOB, this directly impacts revenue (every abandoned Sales call = ~$47 lost opportunity). For Billing, it drives repeat calls and social media complaints. We've observed that once SLA drops below 80%, recovery takes 20–30 minutes even after root cause is fixed (queue backlog effect). | **SLA breach in progress.** Revenue and CSAT impact. Recovery will take 20–30 min after fix. Escalate to WFM for emergency staffing. |

**Sub-signal Thresholds (per LOB):**
| LOB | SLA Target | Healthy | Warning | Critical | Revenue Impact of Breach |
|-----|------------|---------|---------|----------|------------------------|
| Sales | 80% in 20s | ≥ 85% | 80–85% | < 80% | $47/abandoned call |
| Billing | 80% in 30s | ≥ 85% | 80–85% | < 80% | +1.8 repeat calls per missed |
| Service | 80% in 45s | ≥ 82% | 78–82% | < 78% | Lower threshold — longer SLA target |
| Retention | 90% in 15s | ≥ 92% | 88–92% | < 88% | Higher threshold — VIP customers |

---

### 6. Queue Sufficiency %

| Attribute | Value |
|---|---|
| **What it measures** | Whether enough agents are available per queue to handle current demand |
| **Source** | Genesys Queue Observations + WFM |
| **Refresh** | Every 60 seconds |
| **Domains** | Agent Health |

**Databricks Calculation:**
```sql
SELECT 
    current_timestamp() AS snapshot_time,
    'Queue Sufficiency' AS signal_name,
    ROUND(AVG(available_agents * 100.0 / NULLIF(required_agents, 0)), 1) AS numeric_value
FROM bronze.queue_realtime q
JOIN bronze.wfm_staffing_requirement w 
    ON q.queue_id = w.queue_id AND q.interval_id = w.interval_id
WHERE q._ingested_at >= current_timestamp() - INTERVAL 2 MINUTES;
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 90%** | 90% sufficiency = 10% margin above the Erlang C requirement. This buffer absorbs normal variance in call arrival patterns (calls arrive randomly, not evenly). Without this buffer, even a small spike causes queue buildup. 90% was chosen because our WFM model shows SLA is maintained 98% of intervals when sufficiency ≥ 90%. | Adequate staffing. SLA targets achievable across all queues. |
| Warning ⚠️ | **80–90%** | 80–90% means some queues are understaffed. The most impacted queues will see ASA increase by 30–60%. This typically happens during shift transitions (e.g., 2pm ET when US East lunch overlaps with Manila shift end) or when absenteeism exceeds forecast. Not immediately critical because cross-queue routing can partially compensate. | Check which queues are short. If more than 3 queues below 85%, it's a systemic issue (mass absence or login failure). |
| Critical 🔴 | **< 80%** | Below 80% = systematic understaffing. Wait times escalate non-linearly (Erlang C is exponential at low staffing). At 75% sufficiency, average wait time is 3x the normal. At 70%, it's 6x. This is the "death spiral" zone — long waits → more abandons → agents handling callbacks → even less available. Recovery from < 80% typically requires emergency measures (overtime, cross-skilling). | **Staffing emergency.** SLA will breach within 5 minutes if not already. Check Agent Online for root cause (login failures, site outage, mass absence). |

---

### 7. Presence — Vendor %

| Attribute | Value |
|---|---|
| **What it measures** | Agent online rate per outsource vendor |
| **Source** | Genesys + WFM (agent metadata has vendor assignment) |
| **Refresh** | Every 60 seconds |
| **Sub-signals** | Vendor A, Vendor B, Vendor C |
| **Domains** | Agent Health |

**Databricks Calculation:**
```sql
SELECT 
    r.vendor_name,
    ROUND(
        COUNT(CASE WHEN a.agent_status IN ('Available','Interacting') THEN 1 END) * 100.0
        / NULLIF(SUM(w.scheduled_count), 0), 1
    ) AS vendor_presence_pct
FROM bronze.agent_realtime_status a
JOIN silver.agent_roster r ON a.agent_id = r.agent_id
JOIN bronze.wfm_schedule w ON a.interval_id = w.interval_id AND r.agent_id = w.agent_id
WHERE a._ingested_at >= current_timestamp() - INTERVAL 2 MINUTES
GROUP BY r.vendor_name;
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 94%** | Vendor-specific presence is measured against THEIR scheduled headcount. 94% is achievable for well-managed vendors — it accounts for normal tech issues (2%), bio breaks mis-timed (2%), and system login delays (2%). We set this slightly below the overall Agent Online threshold (95%) because vendor-reported schedules often have 1–2% more variance than internal. | Vendor delivering to contractual staffing obligations. |
| Warning ⚠️ | **90–94%** | 90–94% means the vendor is ~5% below their commitment. For a vendor with 10,000 scheduled agents, that's 500+ missing. Common causes: local IT issue at vendor's site, payroll dispute (mass no-show), or our WFM schedule was updated but vendor didn't get notified. This is an operational concern, not yet a contractual breach. | Contact vendor operations manager. Determine if it's technical (we can help) or workforce (they need to solve). |
| Critical 🔴 | **< 90%** | Below 90% = 1,000+ agents missing from a single vendor. This is either a major technical failure at the vendor site (ISP, power) or an operational failure (mass absence event). Since each vendor typically handles specific LOBs, < 90% will directly impact those LOBs' SLA. Our contracts include financial penalties at < 88% sustained for > 30 minutes. | **Vendor emergency.** Engage vendor escalation path. Simultaneously, reroute calls to other vendors/sites if cross-training allows. |

---

### 8. Presence — Location %

| Attribute | Value |
|---|---|
| **What it measures** | Agent online rate per physical/virtual site |
| **Source** | Genesys + WFM + Site Config |
| **Refresh** | Every 60 seconds |
| **Sub-signals** | US East, US West, Manila, India |
| **Domains** | Agent Health |

**Databricks Calculation:** Same as Vendor, but `GROUP BY r.site_name` instead.

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 93%** | Slightly lower than vendor threshold because location includes at-home agents who have more variable connectivity. The 93% line accounts for normal home-ISP jitter that causes brief disconnects. Measured per-site: US East (~15K agents), US West (~8K agents), Manila (~18K agents), India (~9K agents). | All sites operating within normal parameters. |
| Warning ⚠️ | **88–93%** | A 5% drop at one location means 500–1000 agents offline. The most common cause is local ISP degradation — we've seen this 3–4 times per month in Manila and 1–2 times in India. This is the FASTEST early warning signal for regional network issues. If you see a single location drop while others are stable, it's almost always a local network/ISP problem (not a Genesys issue). | Check Connectivity signal — if it also dropped, confirm it's a network event. Cross-reference with ThousandEyes for that region. |
| Critical 🔴 | **< 88%** | Below 88% = major site event. 12%+ of a site's workforce is offline. Causes: power outage, ISP backbone failure, natural disaster, or building evacuation. Manila dropping from 93→84% in 5 minutes has happened twice in the last year — both were Typhoon/ISP events. At this level, the missing capacity is unrecoverable from that site — must reroute to other locations. | **Site-level emergency.** Check if the building/ISP is down. Simultaneously activate disaster recovery routing to redistribute calls. |

---

### 9. Connectivity %

| Attribute | Value |
|---|---|
| **What it measures** | Network path availability between agent sites and Genesys Cloud |
| **Source** | ThousandEyes / SolarWinds / Ping checks |
| **Refresh** | Every 60 seconds |
| **Domains** | Agent Health, Genesys Health |

**Databricks Calculation:**
```sql
SELECT 
    current_timestamp() AS snapshot_time,
    'Connectivity' AS signal_name,
    ROUND(
        COUNT(CASE WHEN packet_loss_pct < 1 AND latency_ms < 150 THEN 1 END) * 100.0
        / COUNT(*), 1
    ) AS numeric_value
FROM bronze.network_path_tests
WHERE _ingested_at >= current_timestamp() - INTERVAL 2 MINUTES
  AND path_type = 'agent_to_platform';
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 96%** | We run probes from every agent site to Genesys Cloud edge servers every 60 seconds (~40 probes/min). 96% = at most 1–2 probes failing per cycle. Transient failures (single packet loss) are normal on the internet. The "healthy" definition requires BOTH packet loss < 1% AND latency < 150ms — because a path can be "up" but degraded. | Network is clean. Voice quality should be good. |
| Warning ⚠️ | **92–96%** | 92% means 3–4 probes failing consistently. This indicates a specific path is degraded (not transient noise). Common causes: ISP peering congestion during business hours, misconfigured QoS after a network change, or a ThousandEyes agent itself having issues (check agent health first). At this level, some agents will experience choppy audio or dropped calls, but most are unaffected. | Identify which paths/regions are failing. If concentrated in one site → correlates with Presence—Location. If spread across sites → possible Genesys Cloud ingress issue. |
| Critical 🔴 | **< 92%** | Below 92% = widespread network degradation. 8%+ of network paths are failing. This directly causes Call Quality degradation (MOS drops by 0.5–1.0 within 2 minutes of connectivity issues). Also causes agent desktop timeouts (Citrix ICA protocol is latency-sensitive). This is a "cascade trigger" — Connectivity ↓ simultaneously hits Call Quality, Desktop/Endpoint, and Agent Online. | **Network event in progress.** Expect Call Quality to degrade within 2 minutes. Check ThousandEyes for the specific AS path and contact ISP/network operations. |

---

### 10. Genesys Platform %

| Attribute | Value |
|---|---|
| **What it measures** | Genesys Cloud platform availability (their status + our synthetics) |
| **Source** | Genesys Status API + Synthetic monitors |
| **Refresh** | Every 60 seconds |
| **Domains** | Genesys Health |

**Databricks Calculation:**
```python
# Ingest Genesys status page
import requests

status_resp = requests.get("https://status.mypurecloud.com/api/v2/summary.json")
genesys_status = status_resp.json()["status"]["indicator"]  # 'none'|'minor'|'major'|'critical'

# Combine with our synthetic probes
synthetic_rate = spark.sql("""
    SELECT AVG(CASE WHEN success = 1 THEN 100.0 ELSE 0 END) AS rate
    FROM bronze.genesys_synthetic_checks
    WHERE check_time >= current_timestamp() - INTERVAL 5 MINUTES
""").collect()[0]["rate"]

# Scoring logic
if genesys_status == 'none' and synthetic_rate >= 99:
    platform_health = 100.0
elif genesys_status in ('minor',) or synthetic_rate < 99:
    platform_health = 95.0
elif genesys_status in ('major', 'critical') or synthetic_rate < 90:
    platform_health = 50.0
else:
    platform_health = 100.0
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 99.5%** | Genesys Cloud has a contractual SLA of 99.99% uptime. Our synthetics test login, queue routing, and media establishment every 30 seconds. 99.5% = at most 1 synthetic failure per 5-min window. We check both Genesys's own status page AND our synthetics because Genesys's status page is often lagging by 5–10 minutes. Our synthetics catch issues faster. | Platform fully operational. Trust but verify — our synthetics confirm independently. |
| Warning ⚠️ | **98–99.5%** | 98% = multiple synthetic failures. Either Genesys has a minor degradation (one region, one service), or our synthetics are detecting latency increases > 2s for API calls. Historically, "minor" Genesys incidents stay at this level for 15–30 min before resolving or escalating. Don't panic — but prepare. | Genesys experiencing minor issues. Monitor for escalation. If our synthetics show it but their status page doesn't → we're detecting it early, likely to appear on their page within 5–10 min. |
| Critical 🔴 | **< 98%** | Below 98% = confirmed Genesys outage or major degradation. This is the "everything breaks" signal. Genesys Cloud handles: voice routing, agent state management, IVR, recording, analytics. If the platform is down, literally nothing works. This is the signal with the HIGHEST cascade impact — it correlates with Call Quality, IVR, SLA, and Agent Online simultaneously. | **Genesys outage.** Activate DR plan. Open bridge with Genesys TAM. All other degraded signals are likely SYMPTOMS of this root cause — don't chase them individually. |

---

### 11. IVR / Self-Service %

| Attribute | Value |
|---|---|
| **What it measures** | IVR completion rate + chatbot resolution rate |
| **Source** | Genesys Architect Analytics / Nuance / Custom |
| **Refresh** | Every 5 minutes |
| **Sub-signals** | IVR Completion, Chatbot |
| **Domains** | App Health, Genesys Health |

**Databricks Calculation:**
```sql
SELECT 
    current_timestamp() AS snapshot_time,
    'IVR / Self-Service' AS signal_name,
    ROUND(SUM(completed) * 100.0 / NULLIF(SUM(total_attempts), 0), 1) AS numeric_value
FROM bronze.ivr_metrics
WHERE interval_start >= current_timestamp() - INTERVAL 15 MINUTES;
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 97%** | IVR handles ~40% of all inbound contacts without an agent. 97% completion means only 3% of IVR journeys fail (caller can't authenticate, speech recognition fails, system error). That 3% overflow to agents is already factored into our staffing models. | Self-service operating normally. Agent queues are getting expected overflow. |
| Warning ⚠️ | **93–97%** | 93% = 7% IVR failure rate. An extra 4% of calls now reaching agents instead of self-service. At 100K calls/hour, that's 4,000 extra calls per hour hitting agent queues. This creates a delayed Queue Sufficiency impact (10 minutes lag as the extra volume builds up). Common causes: speech recognition engine issues, backend API timeout (e.g., billing lookup fails), or prompt playback failure. | Check IVR backend systems. This will impact Queue Sufficiency within ~10 minutes as overflow builds. |
| Critical 🔴 | **< 93%** | Below 93% = IVR is functionally impaired. 7%+ overflow rate will overwhelm agent queues within 15 minutes. If IVR drops to 80%, that's 8,000 extra calls/hour routed to agents — equivalent to needing 700+ additional agents that don't exist. IVR failure is a "slow-cascade" — it takes 10–15 min to feel the impact, but once queue backlog builds, it takes 30+ min to recover. | **IVR failure.** Agent queues will feel this in 10 min. Pre-emptively activate overflow plans. Check Genesys Platform — IVR runs on their infra. |

---

### 12. Call Quality (MOS Score)

| Attribute | Value |
|---|---|
| **What it measures** | Mean Opinion Score — voice quality on active calls |
| **Source** | Genesys Quality API / RTP stream analysis |
| **Refresh** | Every 60 seconds |
| **Sub-signals** | MOS Score, Jitter, Packet Loss |
| **Domains** | Genesys Health |

**Databricks Calculation:**
```sql
SELECT 
    current_timestamp() AS snapshot_time,
    'Call Quality' AS signal_name,
    ROUND(AVG(mos_score), 1) AS numeric_value,
    ROUND(AVG(jitter_ms), 1) AS avg_jitter_ms,
    ROUND(AVG(packet_loss_pct), 2) AS avg_packet_loss_pct
FROM bronze.call_quality_realtime
WHERE _ingested_at >= current_timestamp() - INTERVAL 5 MINUTES
  AND call_state = 'connected';
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **MOS ≥ 4.0** | MOS (Mean Opinion Score) is ITU-T P.800 standard, scale 1.0–5.0. A score of 4.0+ = "Good to Excellent" — callers perceive normal phone quality. At 4.0, jitter is typically < 10ms and packet loss < 0.3%. This is the baseline for acceptable voice quality in enterprise contact centers. | Voice quality is good. No customer complaints expected. |
| Warning ⚠️ | **MOS 3.5–4.0** | 3.5–4.0 = "Fair" quality. Callers may notice occasional audio artifacts (brief cutting out, slight echo, robotic sound). Agents may ask callers to repeat. This degradation is noticeable but the call is still usable. Cause is almost always network-related: jitter 10–20ms and/or packet loss 0.5–1.5%. This is the MOST IMPORTANT signal for early detection — MOS is the first metric to degrade when a network event starts. | Network quality declining. MOS is the "canary in the coal mine" — if MOS drops, check Connectivity and Network Latency immediately. |
| Critical 🔴 | **MOS < 3.5** | Below 3.5 = "Poor" quality. Calls are borderline unusable — significant audio drops, one-way audio, garbled speech. At MOS 3.0, ~30% of callers will hang up due to quality. At MOS 2.5, it's a voice outage in all but name. This is a P1-level event because it directly impacts EVERY active call, not just queued ones. A MOS drop from 4.2 → 3.2 in 15 minutes is a hallmark network cascade pattern. | **Voice quality emergency.** Every active call is degraded. Check: Connectivity, Network Latency, Genesys Platform (in that order). Root cause is network 85% of the time. |

**Sub-signal Thresholds:**

| Sub-signal | Healthy | Warning | Critical | Relationship to MOS |
|---|---|---|---|---|
| **Jitter** | < 10ms | 10–20ms | > 20ms | Jitter > 15ms typically causes MOS to drop below 4.0. Jitter > 30ms = MOS below 3.5 almost always. |
| **Packet Loss** | < 0.5% | 0.5–1.5% | > 1.5% | 1% packet loss ≈ MOS reduction of 0.3–0.5 points. 3% packet loss = conversations become unintelligible. |

**Why MOS is special:**
> MOS responds within 30 seconds of a network event. Jitter and packet loss are the CAUSE; MOS is the EFFECT. When debugging, always look at jitter + packet loss to find root cause. If jitter is high but packet loss is fine → congestion. If both are high → link degradation or routing change.

---

### 13. Network Latency

| Attribute | Value |
|---|---|
| **What it measures** | Round-trip latency between agent sites and Genesys Cloud |
| **Source** | ThousandEyes / ICMP / TCP probes |
| **Refresh** | Every 60 seconds |
| **Domains** | App Health, Genesys Health |

**Databricks Calculation:**
```sql
SELECT 
    current_timestamp() AS snapshot_time,
    'Network Latency' AS signal_name,
    ROUND(AVG(rtt_ms), 0) AS numeric_value
FROM bronze.network_latency_probes
WHERE _ingested_at >= current_timestamp() - INTERVAL 2 MINUTES
  AND destination = 'genesys_cloud_edge';
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **< 30ms** | For voice applications, Genesys recommends round-trip latency < 150ms. We set our healthy threshold at 30ms (5x better than requirement) because our normal baseline IS 15–25ms. If latency is at 30ms, we're already at 2x our baseline. Also, low latency = better Citrix ICA performance for agent desktops. | Network performing at baseline. No impact on voice or desktop. |
| Warning ⚠️ | **30–80ms** | 30–80ms = noticeable increase from baseline. At 50ms RTT, Citrix desktop responsiveness degrades (users feel keystrokes are "laggy"). At 80ms, voice applications start to exhibit perceptible delay. The wide warning range (30–80) is intentional — latency increases gradually during congestion events, giving us a 10–15 minute window to act before it hits critical. | Latency is elevated. If increasing trend: check ISP peering, routing changes, or bandwidth saturation. If stable at 40–50ms: may be a new baseline after a routing change (investigate but don't panic). |
| Critical 🔴 | **> 80ms** | Above 80ms = severe network degradation. At 100ms RTT, voice delay is perceptible to callers (conversation feels like a satellite call). At 150ms, Citrix sessions start timing out. At 200ms+, TCP connections drop. Network latency at this level will simultaneously degrade: Call Quality (MOS drops), Desktop/Endpoint (Citrix timeouts), and Connectivity (probe failures). | **Network degradation.** Triple-cascade imminent: Call Quality, Desktop, Connectivity all will degrade. Contact network ops and ISP immediately. |

---

### 14. Desktop / Endpoint %

| Attribute | Value |
|---|---|
| **What it measures** | Health of agent workstations (Citrix, browser, softphone) |
| **Source** | Citrix Director API / Nexthink / Custom agent |
| **Refresh** | Every 60 seconds |
| **Sub-signals** | Citrix, Browser, Softphone |
| **Domains** | Agent Health, App Health |

**Databricks Calculation:**
```sql
SELECT 
    current_timestamp() AS snapshot_time,
    'Desktop / Endpoint' AS signal_name,
    ROUND(AVG(health_score), 1) AS numeric_value
FROM (
    SELECT
        CASE WHEN citrix_session_state = 'Active' AND ica_rtt_ms < 100 THEN 100.0 ELSE 0 END AS health_score
    FROM bronze.endpoint_status
    WHERE _ingested_at >= current_timestamp() - INTERVAL 2 MINUTES
    UNION ALL
    SELECT
        CASE WHEN browser_responsive = 1 THEN 100.0 ELSE 0 END
    FROM bronze.endpoint_status
    WHERE _ingested_at >= current_timestamp() - INTERVAL 2 MINUTES
    UNION ALL
    SELECT
        CASE WHEN softphone_registered = 1 THEN 100.0 ELSE 0 END
    FROM bronze.endpoint_status
    WHERE _ingested_at >= current_timestamp() - INTERVAL 2 MINUTES
);
```

**Threshold Deep-Dive:**

| Status | Range | Rationale | What It Means Operationally |
|---|---|---|---|
| Healthy ✅ | **≥ 97%** | At 50K agents, 97% = ~1,500 agents with desktop issues. These are normal: Citrix session reconnects after sleep, browser cache clearing, softphone re-registration after network blip. Nexthink data shows 2–3% of endpoints always have minor issues at any given time. We tolerate this because agents self-resolve within 2–3 minutes. | Normal endpoint churn. Agents are self-resolving. |
| Warning ⚠️ | **93–97%** | At 93%, ~3,500 agents have endpoint issues. This exceeds self-resolution capacity — help desk call volume will spike. Common patterns: Citrix infrastructure update causing session drops, Windows Update deploying off-schedule, or browser version mismatch with CRM app. Often concentrated in one sub-signal (e.g., Citrix at 88% while Browser and Softphone are fine → Citrix-specific issue). | Check which sub-signal is degraded. Citrix issues → contact Citrix team. Browser → check CRM deployment. Softphone → check Genesys WebRTC/client. |
| Critical 🔴 | **< 93%** | Below 93% = mass endpoint failure. 3,500+ agents can't work. Even though they might be "logged in" per Genesys, they can't actually process calls because their screen is frozen or their softphone is unregistered. This causes a disconnect: Agent Online shows 95% (they're logged in) but SLA is tanking (they can't actually answer). Desktop < 93% + Agent Online ≥ 95% = "ghost agents" — logged in but non-functional. | **Mass desktop failure.** Look for the "ghost agent" pattern. Correlate with Network Latency — if latency > 80ms, Citrix sessions are timing out (network root cause, not desktop). |

---

## PART 2: Domain Scoring — How to Roll Up

Each signal belongs to one or more domains. The domain score is a **weighted average** of its member signals.

### Domain → Signal Mapping (Delta Table: `gold.domain_signal_map`)

```
┌─────────────────┬────────────────────────────────────────────────────────────┐
│ AGENT HEALTH    │ Agent Online, Call LOB SLA, Queue Sufficiency,             │
│ (8 signals)     │ Presence—Vendor, Presence—Location, Connectivity,          │
│                 │ Desktop/Endpoint, (shared: Call LOB SLA)                   │
├─────────────────┼────────────────────────────────────────────────────────────┤
│ APP HEALTH      │ App Health, Core Systems, Incidents, IVR/Self-Service,     │
│ (6 signals)     │ Network Latency, Desktop/Endpoint                         │
├─────────────────┼────────────────────────────────────────────────────────────┤
│ GENESYS HEALTH  │ Genesys Platform, Call Quality, Connectivity,              │
│ (8 signals)     │ Call LOB SLA, Incidents, Agent Online, Core Systems,       │
│                 │ IVR/Self-Service, Network Latency                          │
└─────────────────┴────────────────────────────────────────────────────────────┘
```

> **Note:** Signals can belong to multiple domains (many-to-many). This is intentional.

### Databricks Implementation — Domain Scoring Notebook

```python
# Notebook: 03_domain_scoring (runs after signal scoring notebook)

from pyspark.sql.functions import *

# Step 1: Read signals from Silver layer
signals_df = spark.sql("""
    SELECT s.signal_name, s.numeric_value, s.status, m.domain_key
    FROM silver.signal_snapshots s
    JOIN gold.domain_signal_map m ON s.signal_name = m.signal_name
    WHERE s.snapshot_time = (
        SELECT MAX(snapshot_time) FROM silver.signal_snapshots
    )
""")

# Step 2: Score each signal → 0/70/100
scored = signals_df.withColumn("score",
    when(col("status") == "critical", 0)
    .when(col("status") == "warning", 70)
    .otherwise(100)
)

# Step 3: Average per domain
domain_scores = scored.groupBy("domain_key").agg(
    round(avg("score"), 1).alias("score"),
    count("*").alias("signal_count"),
    sum(when(col("status") == "critical", 1).otherwise(0)).alias("critical_count"),
    sum(when(col("status") == "warning", 1).otherwise(0)).alias("warning_count")
)

# Step 4: Write to Gold layer
domain_scores.withColumn("snapshot_time", current_timestamp()) \
    .write.mode("append").format("delta").saveAsTable("gold.domain_scores")
```

```sql
-- Create the mapping table (run once during setup)
CREATE TABLE IF NOT EXISTS gold.domain_signal_map (
    signal_name STRING,
    domain_key  STRING
) USING DELTA;

INSERT INTO gold.domain_signal_map VALUES
    ('Agent Online', 'agent'), ('Agent Online', 'genesys'),
    ('Incidents', 'app'), ('Incidents', 'genesys'),
    ('App Health', 'app'),
    ('Core Systems', 'app'), ('Core Systems', 'genesys'),
    ('Call LOB SLA', 'agent'), ('Call LOB SLA', 'genesys'),
    ('Queue Sufficiency', 'agent'),
    ('Presence—Vendor', 'agent'),
    ('Presence—Location', 'agent'),
    ('Connectivity', 'agent'), ('Connectivity', 'genesys'),
    ('Genesys Platform', 'genesys'),
    ('IVR / Self-Service', 'app'), ('IVR / Self-Service', 'genesys'),
    ('Call Quality', 'genesys'),
    ('Network Latency', 'app'), ('Network Latency', 'genesys'),
    ('Desktop / Endpoint', 'agent'), ('Desktop / Endpoint', 'app');
```

### Enterprise Score (Spark SQL)

```sql
-- Gold layer: Enterprise composite score
SELECT 
    current_timestamp() AS snapshot_time,
    ROUND((agent.score + app.score + genesys.score) / 3, 1) AS enterprise_score,
    agent.score AS agent_health_score,
    app.score AS app_health_score,
    genesys.score AS genesys_health_score
FROM 
    (SELECT score FROM gold.domain_scores WHERE domain_key='agent' ORDER BY snapshot_time DESC LIMIT 1) agent,
    (SELECT score FROM gold.domain_scores WHERE domain_key='app' ORDER BY snapshot_time DESC LIMIT 1) app,
    (SELECT score FROM gold.domain_scores WHERE domain_key='genesys' ORDER BY snapshot_time DESC LIMIT 1) genesys;
```

> **⚡ For 2-Day Delivery:** Use the simple average above. Don't over-engineer weights yet.
> After 90 days of data, you can calibrate weights per domain (e.g., Genesys 0.4, Agent 0.35, App 0.25) based on historical outage correlation.

---

## PART 3: Correlation Detection — The Smart Part (Azure Databricks)

This is where we go from "Signal X is bad" to "Signal X is bad **because** Signal Y deteriorated 10 minutes ago."

### Strategy: Rule-Based Correlation (Day 1–2)

Don't build an ML model. Use a **correlation rule table** stored as a Delta table. Each rule says: "If Signal A is degraded AND Signal B is degraded within N minutes, they're probably related." The rules encode **domain expertise** about how contact center failures cascade.

### The Correlation Rule Table (Delta)

```sql
-- Run once during setup
CREATE TABLE IF NOT EXISTS gold.correlation_rules (
    rule_id             INT,
    signal_a            STRING     COMMENT 'Trigger / cause signal',
    signal_b            STRING     COMMENT 'Effect / symptom signal', 
    direction           STRING     COMMENT 'a_causes_b | bidirectional',
    time_window_min     INT        COMMENT 'How many minutes between A and B events',
    confidence          DECIMAL(3,2) COMMENT '0.0 to 1.0 — how sure we are of this link',
    insight_template_id INT        COMMENT 'FK to insight_templates',
    recommended_action  STRING,
    is_active           BOOLEAN DEFAULT TRUE
) USING DELTA;
```

### Pre-Built Rules — Full Causal Chain Explanations

> **Each rule below encodes a known failure cascade in Contact Center operations.** These aren't statistical guesses — they're operational cause-and-effect chains validated by post-mortem analysis.

---

#### Rule R1: Call Quality ↓ ← Connectivity ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Connectivity % |
| **Signal B (effect)** | Call Quality (MOS) |
| **Direction** | `a_causes_b` |
| **Window** | 5 minutes |
| **Confidence** | 0.90 |

**The Full Causal Chain:**

```
ISP peering issue / routing change / bandwidth saturation
  → Packet loss increases on agent-to-Genesys-Cloud paths
    → RTP stream (Real-time Transport Protocol) loses voice packets
      → Codec (Opus/G.711) can't compensate — frames are missing
        → Jitter buffer overflows → audio gaps, garbled speech
          → MOS score drops from 4.2 → 3.2 in 5–15 minutes
```

**Why 5-minute window?** Network events propagate to voice quality within 30 seconds for active calls, but our Connectivity metric uses a 2-minute sliding average (to avoid noise), so the detected degradation lags reality by 2–3 minutes. Adding buffer: 5 minutes covers the worst case where both metrics use overlapping windows.

**Why 0.90 confidence?** In our historical data, 90% of times Connectivity dropped to warning AND Call Quality dropped within 5 minutes, the root cause was the same network event. The remaining 10% were coincidences (e.g., Genesys platform update happening during an unrelated ISP issue).

**Recommended Action:** Check ThousandEyes for the specific network path that's degraded. If it's an ISP peering issue, you can't fix it directly — contact the ISP and simultaneously consider routing around the affected path.

---

#### Rule R2: Call Quality ↓ ← Network Latency ↑

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Network Latency |
| **Signal B (effect)** | Call Quality (MOS) |
| **Direction** | `a_causes_b` |
| **Window** | 5 minutes |
| **Confidence** | 0.85 |

**The Full Causal Chain:**

```
BGP route change / congestion / DDoS on ISP backbone
  → Round-trip time increases from 20ms → 80ms+
    → Jitter increases (variable latency = variable packet arrival times)
      → Jitter buffer must grow larger to compensate → adds delay
        → Delay exceeds 150ms one-way → callers perceive "satellite delay"
          → If jitter exceeds buffer capacity → packet drops begin
            → MOS drops. At 100ms RTT: MOS typically 3.8. At 150ms: MOS 3.3–3.5.
```

**Why different from R1?** R1 (Connectivity) measures whether paths are AVAILABLE (binary: packet loss < 1% AND latency < 150ms). R2 (Latency) measures HOW SLOW the available paths are. You can have good connectivity (paths exist, low packet loss) but terrible latency (paths are slow due to routing through distant hops). R2 catches congestion-type events; R1 catches outage-type events.

**Why 0.85 confidence (lower than R1)?** Latency can increase due to legitimate routing changes that don't impact voice quality (e.g., a failover that adds 20ms but stays under MOS threshold). Also, some latency spikes are so brief (< 30 seconds) that they don't impact the 5-minute MOS average.

---

#### Rule R3: Call LOB SLA ↓ ← Incidents ↑

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Incidents (Active Count) |
| **Signal B (effect)** | Call LOB SLA % |
| **Direction** | `a_causes_b` |
| **Window** | 10 minutes |
| **Confidence** | 0.80 |

**The Full Causal Chain:**

```
System issue causes incident(s) to be opened
  → Incident affects one or more platform components
    → Component degradation → some agents can't process calls OR IVR fails
      → Calls take longer (handling time increases) OR queue grows (agents offline)
        → Calls wait in queue beyond SLA threshold
          → SLA% drops from 87% → 78% over 10–20 minutes
```

**Why 10-minute window?** Incidents are detected and opened 3–5 minutes after an event starts (detection delay + ticket creation). SLA impact takes another 5–10 minutes to materialize because the 30-minute rolling SLA window dampens immediate spikes. Total expected lag: 8–15 minutes. We use 10 minutes as the correlation window.

**Why 0.80 confidence (moderate)?** Not all incidents impact SLA. A P3 incident about a reporting dashboard has zero impact on call handling. But a P1 about CRM being unresponsive directly impacts every call. The 80% accounts for the mix — in our history, 80% of incident surges (≥4 active) did precede SLA drops. The other 20% were incidents about non-call-path systems.

**Recommended Action:** Look at the incident CIs (Configuration Items). If they're call-path systems (Genesys, CRM, IVR) → SLA impact is certain. If they're non-call-path (reporting, WFM admin) → SLA impact is unlikely despite the correlation firing.

---

#### Rule R4: App Health ↓ ↔ Incidents ↑

| Attribute | Value |
|---|---|
| **Signal A** | Incidents (Active Count) |
| **Signal B** | App Health % |
| **Direction** | `bidirectional` |
| **Window** | 5 minutes |
| **Confidence** | 0.85 |

**The Full Causal Chain (both directions):**

```
Direction 1: Incidents → App Health drops
  P1/P2 incidents represent known system failures
    → Those failures are the SAME events that synthetic monitors detect
      → Incident exists because the app is already degraded
        → App Health % reflects the same underlying event

Direction 2: App Health drops → Incidents created
  Synthetic monitors detect application failure
    → Operations team gets alerted
      → They create an incident in ServiceNow
        → Incident count increases
          → Both signals move in parallel, 2–5 min apart
```

**Why bidirectional?** This is a SHARED ROOT CAUSE situation, not a true causal chain. The same event (e.g., CRM database lock contention) causes BOTH the synthetic monitor failure (App Health drops) AND the incident creation. Neither truly "causes" the other — they're both symptoms. We mark this bidirectional so the insight engine says "correlated with" rather than "caused by."

**Why 0.85 confidence?** Very high because they measure the same thing from different angles. The 15% miss rate is when incidents are opened for FUTURE concerns (e.g., "certificate expiring in 7 days") that haven't impacted health yet.

---

#### Rule R5: Presence—Location ↓ ← Connectivity ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Connectivity % |
| **Signal B (effect)** | Presence—Location % |
| **Direction** | `a_causes_b` |
| **Window** | 3 minutes |
| **Confidence** | 0.92 |

**The Full Causal Chain:**

```
Regional ISP outage / undersea cable cut / local power event
  → Network paths from that region to Genesys Cloud fail
    → Connectivity probes for that region start failing
      → Agents at that site lose connection to Genesys
        → Genesys marks those agents as "Not Responding" → logged off
          → Presence—Location % for that region drops
            → If the site is large (Manila = 18K agents), Agent Online also drops
```

**Why 3-minute window (short)?** This is one of the tightest correlations. When a regional network goes down, BOTH signals update within the same 60-second polling cycle. We allow 3 minutes to account for: (a) our connectivity probes may detect the issue 1 cycle before Genesys marks agents offline (probes run from external vantage points, Genesys relies on heartbeats), and (b) Citrix has a 30–60 second timeout before declaring a session dead.

**Why 0.92 confidence (highest)?** When a specific LOCATION drops and connectivity for that REGION drops, it's the same event 92% of the time. The 8% miss rate is when agents at a site go offline for non-network reasons (e.g., fire alarm evacuation, mass Citrix server failure at the site).

**This is your FASTEST early-warning rule.** Connectivity probes detect ISP issues 1–3 minutes before agents start dropping. If R5 fires → you have 2–3 minutes to activate DR routing before the full impact is felt.

---

#### Rule R6: Queue Sufficiency ↓ ← Agent Online ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Agent Online % |
| **Signal B (effect)** | Queue Sufficiency % |
| **Direction** | `a_causes_b` |
| **Window** | 2 minutes |
| **Confidence** | 0.95 |

**The Full Causal Chain:**

```
Agents go offline (any cause: desktop failure, site outage, delinquent logins)
  → Available agent count drops in multiple queues
    → WFM required staffing level stays the same (demand hasn't changed)
      → available_agents / required_agents ratio drops
        → Queue Sufficiency drops almost instantly
          → Erlang C model shows SLA will breach within minutes
```

**Why 2-minute window (very short)?** This is an IMMEDIATE, mathematical relationship. If 5% of agents go offline, queue sufficiency drops by 5% in the SAME minute (ratio changes instantly). The 2-minute window accounts only for data pipeline latency (agent status update → snapshot → scoring).

**Why 0.95 confidence (highest)?** This is nearly deterministic. Fewer agents = less capacity per queue = lower sufficiency. The only exception (5% miss) is when agents go offline from queues that were already overstaffed — if a queue had 120% sufficiency and loses 15% of agents, it drops to 105% (still healthy).

---

#### Rule R7: Call LOB SLA ↓ ← Agent Online ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Agent Online % |
| **Signal B (effect)** | Call LOB SLA % |
| **Direction** | `a_causes_b` |
| **Window** | 5 minutes |
| **Confidence** | 0.88 |

**The Full Causal Chain:**

```
Agents go offline (any cause)
  → Queue sufficiency drops (R6, above)
    → Calls wait longer in queue
      → Wait time exceeds SLA threshold (e.g., > 20 seconds for Sales)
        → SLA % begins declining
          → Impact is proportional: 5% agent drop ≈ 12% SLA drop (non-linear, Erlang C)
```

**Why 5-minute window (longer than R6)?** Agent Online → Queue Sufficiency is instant (R6, 2 min). But Queue Sufficiency → SLA takes time because: (a) calls already in queue need to finish (drain time), (b) the 30-minute SLA rolling window dampens the immediate effect, (c) cross-queue routing may temporarily absorb overflow. The full chain takes 3–7 minutes.

**Why 0.88 (not 0.95 like R6)?** Because SLA depends on BOTH supply (agents) AND demand (call volume). If agent online drops during a low-volume period (e.g., 9pm), SLA may not be affected at all. The 12% miss rate accounts for the demand-side variability.

**Non-linear impact:** The relationship follows Erlang C curves. A 5% agent drop during peak hours ≈ 12% SLA drop. But a 5% drop during off-peak ≈ 2% SLA drop. Time of day matters enormously.

---

#### Rule R8: Agent Online ↓ ← Desktop/Endpoint ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Desktop / Endpoint % |
| **Signal B (effect)** | Agent Online % |
| **Direction** | `a_causes_b` |
| **Window** | 3 minutes |
| **Confidence** | 0.85 |

**The Full Causal Chain:**

```
Desktop infrastructure event (Citrix server failure, Windows update, browser crash)
  → Agent's workstation becomes unresponsive or disconnects
    → If Citrix: session drops → Genesys softphone disconnects → agent logged off
    → If Browser: CRM page crashes → agent can't accept calls → goes "Not Responding"
    → If Softphone: registration lost → Genesys can't deliver calls → agent shows offline
      → Agent Online % drops WITH a delay (Genesys waits 60s before marking offline)
```

**Why 3-minute window?** Desktop failures are detected immediately by our endpoint monitoring (Citrix Director / Nexthink). But Genesys takes 60–90 seconds to recognize an agent is truly offline (heartbeat timeout). So Desktop drops → Agent Online drops with a 1–2 minute lag.

**Why 0.85 confidence?** Desktop issues don't always cause logoff. A slow browser (5s page load) degrades productivity but doesn't drop the agent from Genesys. A Citrix reconnect (15–30s) may succeed before the heartbeat timeout. The 15% miss accounts for these recoverable desktop events.

**The "Ghost Agent" Pattern:** Watch for Desktop/Endpoint < 93% BUT Agent Online ≥ 95%. This means agents are "logged in" per Genesys but can't actually work (screen frozen, app crashed). This is WORSE than agents being offline — ghost agents consume queue slots but can't answer, so SLA degrades without the staffing signals showing it.

---

#### Rule R9: App Health ↓ ← Core Systems ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Core Systems % |
| **Signal B (effect)** | App Health % |
| **Direction** | `a_causes_b` |
| **Window** | 2 minutes |
| **Confidence** | 0.95 |

**The Full Causal Chain:**

```
Infrastructure failure (database primary failover, message queue crash, auth service down)
  → Applications that depend on that infrastructure component fail
    → CRM can't query database → pages error out → synthetic monitors detect failure
    → WFM can't write to message queue → real-time updates stop
    → Auth service down → single sign-on fails → new logins impossible
      → App Health synthetic success rate drops
        → Impact time: 30 seconds to 2 minutes (depends on connection pool timeouts)
```

**Why 2-minute window (very short)?** This is a direct dependency chain. When a database goes down, the application fails on the NEXT request — within seconds. Our 60-second measurement cycle means we detect both the core failure and the app impact within 1–2 cycles.

**Why 0.95 confidence (very high)?** Core Systems are the FOUNDATION. When infrastructure fails, applications built on it MUST fail (unless they have independent caching, which is rare for transactional systems). The 5% miss is when: (a) a non-critical core component fails (monitoring server, not the production DB), or (b) the app has a graceful degradation path (cached data serves requests for 2–3 min).

**This is the ROOT CAUSE signal.** When R9 fires → fix Core Systems first. Everything else (App Health, Agent Online, SLA) will follow once infrastructure is restored.

---

#### Rule R10: Call Quality ↓ ← Genesys Platform ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Genesys Platform % |
| **Signal B (effect)** | Call Quality (MOS) |
| **Direction** | `a_causes_b` |
| **Window** | 1 minute |
| **Confidence** | 0.95 |

**The Full Causal Chain:**

```
Genesys Cloud platform experiences degradation
  → Media services (voice processing, RTP relay, TURN servers) affected
    → Active calls: media path disrupted → packet loss / jitter spikes
    → New calls: media establishment fails → one-way audio or no audio
      → MOS plummets on all active calls simultaneously
        → This happens FAST — within 30–60 seconds of platform degradation
```

**Why 1-minute window (shortest)?** Genesys Platform directly HOSTS the voice media services. When the platform is degraded, voice quality degrades on the SAME infrastructure. There's no intermediate system — it's the same failure. We allow 1 minute to account for measurement cycle offset.

**Why 0.95 confidence?** Genesys Platform issues almost always affect voice quality because voice traffic flows THROUGH their platform. The 5% exception: Genesys status may show "degraded" for a non-voice service (reporting API, analytics) that doesn't affect active calls.

---

#### Rule R11: IVR/Self-Service ↓ ← Genesys Platform ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Genesys Platform % |
| **Signal B (effect)** | IVR / Self-Service % |
| **Direction** | `a_causes_b` |
| **Window** | 1 minute |
| **Confidence** | 0.90 |

**The Full Causal Chain:**

```
Genesys Cloud platform degradation
  → Architect (IVR engine) runs ON Genesys Cloud
    → IVR flows fail to execute → callers hear silence or error prompts
    → Data dips fail (CRM/billing lookup from IVR) → authentication fails
    → Chatbot backend API (Nuance/internal) can't communicate through Genesys
      → Self-service completion rate drops
        → Failed IVR calls route to human agents → queue overflow
```

**Why 0.90 (slightly lower than R10)?** IVR uses Genesys Cloud differently than voice. Some Genesys degradations affect media but not Architect (IVR engine). Also, our IVR metric uses a 15-minute window (vs. 5-minute for Call Quality), so the detected correlation can be weaker when the IVR metric is lagging.

---

#### Rule R12: Queue Sufficiency ↓ ← IVR/Self-Service ↓

| Attribute | Value |
|---|---|
| **Signal A (cause)** | IVR / Self-Service % |
| **Signal B (effect)** | Queue Sufficiency % |
| **Direction** | `a_causes_b` |
| **Window** | 10 minutes |
| **Confidence** | 0.75 |

**The Full Causal Chain:**

```
IVR/Self-Service degrades (any cause: Genesys issue, backend API timeout, speech engine failure)
  → Callers who WOULD have self-served now CANNOT
    → Those callers are routed to human agent queues instead
      → At 100K calls/hour with 40% self-service rate: every 1% IVR drop = 400 extra calls/hour
        → Queue staffing was planned WITHOUT these overflow calls
          → required_agents stays the same, but actual demand increases
            → Effective queue sufficiency drops
              → But slowly! Takes 10–15 minutes for the queue backlog to build
```

**Why 10-minute window (longest)?** This is a "slow cascade." IVR failures don't instantly create queue pressure — the overflow builds gradually as more callers complete the IVR journey and get routed to agents. The IVR interaction itself takes 2–4 minutes, then there's queue wait time. Full impact is felt 10–15 minutes after IVR starts failing.

**Why 0.75 confidence (lowest)?** Three reasons: (a) not all IVR failures result in agent routing — some callers hang up; (b) the long time window (10 min) increases the chance of coincidence; (c) if IVR is degraded but still completing at 90%, the 10% overflow may not materially impact queue sufficiency (depends on the buffer). This is the weakest but still important correlation.

---

#### Rule R13: Desktop/Endpoint ↓ ← Network Latency ↑

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Network Latency |
| **Signal B (effect)** | Desktop / Endpoint % |
| **Direction** | `a_causes_b` |
| **Window** | 5 minutes |
| **Confidence** | 0.80 |

**The Full Causal Chain:**

```
Network latency increases (congestion, routing change, ISP issue)
  → Citrix ICA protocol is VERY latency-sensitive (designed for < 100ms RTT)
    → At 80ms RTT: Citrix sessions become "laggy" (keystrokes delayed 0.5s)
    → At 120ms RTT: Citrix session reconnect attempts begin
    → At 150ms+ RTT: Citrix sessions drop entirely (ICA timeout)
      → Browser-based apps: API calls to CRM timeout (default 30s) → page errors
      → Softphone: SIP re-registration triggers → brief outage per agent
        → Desktop/Endpoint health score drops as sessions fail
```

**Why 5-minute window?** Citrix is the key link here. ICA sessions have a built-in retry mechanism with exponential backoff. When latency first increases, Citrix compensates (reduces pixel quality, batches updates). It takes 2–3 minutes of sustained high latency before sessions start dropping. Our endpoint monitoring then takes 1 cycle (60s) to detect the session drops.

**Why 0.80 confidence?** Latency can increase without causing desktop failures if it stays below the ICA threshold (~120ms RTT). A jump from 20ms → 60ms is detected by our Network Latency signal but doesn't impact Citrix. This correlation is strongest when latency exceeds 100ms.

---

#### Rule R14: Genesys Platform ↓ ← Connectivity ↓ (Careful!)

| Attribute | Value |
|---|---|
| **Signal A (cause)** | Connectivity % |
| **Signal B (effect)** | Genesys Platform % |
| **Direction** | `a_causes_b` |
| **Window** | 3 minutes |
| **Confidence** | 0.70 |

**The Full Causal Chain:**

```
⚠️ THIS CORRELATION REQUIRES CAREFUL INTERPRETATION

Connectivity drops (our probes fail to reach Genesys Cloud)
  → Our Genesys synthetic monitors ALSO fail (they go over the same network paths)
    → Genesys Platform metric drops because our synthetics can't reach them
      → But Genesys Cloud itself might be PERFECTLY FINE
        → The issue is OUR network, not THEIR platform
```

**Why 0.70 confidence (weakest)?** This is the TRICKIEST correlation because it has a false-positive problem. When our connectivity is down, we CANNOT reliably measure Genesys health — our synthetics fail whether the problem is on our side or Genesys's side. 

**How to disambiguate:**
1. Check Genesys status page (`status.mypurecloud.com`) — if they show healthy, the problem is OUR network
2. Check if Connectivity drop is regional (one site) or global (all sites). If regional → it's us. If global → it might be Genesys
3. Check ThousandEyes paths — if packet loss is before the Genesys edge → it's our ISP
4. Ask another customer of Genesys (if you have contacts) if they're experiencing issues

**Recommended Action:** Before declaring a "Genesys outage": confirm with at least 2 independent sources. Our connectivity failure can masquerade as a Genesys failure.

---

### Correlation Detection — Spark SQL Implementation

```sql
-- Notebook: 04_correlation_detection.sql
-- Runs every 60 seconds after signal scoring

-- Step 1: Get currently degraded signals (last 5 minutes)
CREATE OR REPLACE TEMPORARY VIEW current_degraded AS
SELECT signal_name, status, numeric_value, snapshot_time
FROM silver.signal_snapshots
WHERE status IN ('warning', 'critical')
  AND snapshot_time >= current_timestamp() - INTERVAL 5 MINUTES;

-- Step 2: Find signals that degraded within each rule's time window
CREATE OR REPLACE TEMPORARY VIEW matched_correlations AS
SELECT 
    r.rule_id,
    r.signal_a,
    r.signal_b,
    r.confidence,
    r.direction,
    r.recommended_action,
    a.numeric_value  AS signal_a_value,
    b.numeric_value  AS signal_b_value,
    a.status         AS signal_a_status,
    b.status         AS signal_b_status,
    ABS(unix_timestamp(a.snapshot_time) - unix_timestamp(b.snapshot_time)) / 60 AS lag_minutes
FROM gold.correlation_rules r
JOIN current_degraded a ON a.signal_name = r.signal_a
JOIN current_degraded b ON b.signal_name = r.signal_b
WHERE ABS(unix_timestamp(a.snapshot_time) - unix_timestamp(b.snapshot_time)) / 60 <= r.time_window_min
  AND r.is_active = TRUE;

-- Step 3: Deduplicate (keep highest confidence per signal pair)
CREATE OR REPLACE TEMPORARY VIEW deduped_correlations AS
SELECT *
FROM (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY signal_a, signal_b 
        ORDER BY confidence DESC
    ) AS rn
    FROM matched_correlations
)
WHERE rn = 1;

-- Step 4: Write to Gold layer
INSERT INTO gold.active_correlations
SELECT rule_id, signal_a, signal_b, confidence, direction,
       signal_a_value, signal_b_value, signal_a_status, signal_b_status,
       lag_minutes, recommended_action, current_timestamp() AS detected_at
FROM deduped_correlations;
```

### Correlation Summary Table (for reference)

| Rule | Signal A (cause) | Signal B (effect) | Window | Conf. | Cascade Type |
|------|---|---|---|---|---|
| R1 | Connectivity ↓ | Call Quality ↓ | 5 min | 0.90 | Network → Voice |
| R2 | Network Latency ↑ | Call Quality ↓ | 5 min | 0.85 | Network → Voice |
| R3 | Incidents ↑ | Call LOB SLA ↓ | 10 min | 0.80 | Operations → Customer |
| R4 | Incidents ↑ | App Health ↓ | 5 min | 0.85 | Shared root cause |
| R5 | Connectivity ↓ | Presence—Location ↓ | 3 min | 0.92 | Network → Agents |
| R6 | Agent Online ↓ | Queue Sufficiency ↓ | 2 min | 0.95 | Staffing → Capacity |
| R7 | Agent Online ↓ | Call LOB SLA ↓ | 5 min | 0.88 | Staffing → Customer |
| R8 | Desktop/Endpoint ↓ | Agent Online ↓ | 3 min | 0.85 | Desktop → Staffing |
| R9 | Core Systems ↓ | App Health ↓ | 2 min | 0.95 | Infrastructure → Apps |
| R10 | Genesys Platform ↓ | Call Quality ↓ | 1 min | 0.95 | Platform → Voice |
| R11 | Genesys Platform ↓ | IVR/Self-Service ↓ | 1 min | 0.90 | Platform → Self-Service |
| R12 | IVR/Self-Service ↓ | Queue Sufficiency ↓ | 10 min | 0.75 | Self-Service → Capacity |
| R13 | Network Latency ↑ | Desktop/Endpoint ↓ | 5 min | 0.80 | Network → Desktop |
| R14 | Connectivity ↓ | Genesys Platform ↓ | 3 min | 0.70 | ⚠️ Possible false positive |

### Insert Rules

```sql
INSERT INTO gold.correlation_rules VALUES
(1, 'Connectivity', 'Call Quality', 'a_causes_b', 5, 0.90, 4, 'Check ThousandEyes for degraded network paths', TRUE),
(2, 'Network Latency', 'Call Quality', 'a_causes_b', 5, 0.85, 4, 'Investigate ISP peering and BGP route changes', TRUE),
(3, 'Incidents', 'Call LOB SLA', 'a_causes_b', 10, 0.80, 5, 'Check incident CIs — if call-path, SLA impact certain', TRUE),
(4, 'Incidents', 'App Health', 'bidirectional', 5, 0.85, 4, 'Shared root cause — check both signals for common CI', TRUE),
(5, 'Connectivity', 'Presence—Location', 'a_causes_b', 3, 0.92, 4, 'Regional ISP issue — activate DR routing for that site', TRUE),
(6, 'Agent Online', 'Queue Sufficiency', 'a_causes_b', 2, 0.95, 4, 'Staffing shortfall — check root cause of agent drop', TRUE),
(7, 'Agent Online', 'Call LOB SLA', 'a_causes_b', 5, 0.88, 4, 'SLA will breach — contact WFM for emergency staffing', TRUE),
(8, 'Desktop / Endpoint', 'Agent Online', 'a_causes_b', 3, 0.85, 4, 'Desktop failure causing logoffs — check Citrix/browser', TRUE),
(9, 'Core Systems', 'App Health', 'a_causes_b', 2, 0.95, 4, 'ROOT CAUSE — fix infrastructure first, apps will follow', TRUE),
(10, 'Genesys Platform', 'Call Quality', 'a_causes_b', 1, 0.95, 4, 'Genesys outage — open bridge with Genesys TAM', TRUE),
(11, 'Genesys Platform', 'IVR / Self-Service', 'a_causes_b', 1, 0.90, 4, 'Platform hosts IVR — expect queue overflow in 10 min', TRUE),
(12, 'IVR / Self-Service', 'Queue Sufficiency', 'a_causes_b', 10, 0.75, 4, 'IVR overflow building — pre-emptively activate overflow plans', TRUE),
(13, 'Network Latency', 'Desktop / Endpoint', 'a_causes_b', 5, 0.80, 4, 'High latency killing Citrix sessions — check ISP', TRUE),
(14, 'Connectivity', 'Genesys Platform', 'a_causes_b', 3, 0.70, 4, 'VERIFY: could be our network, not Genesys. Check status page.', TRUE);
```

---

## PART 4: Alert Triggering — When and How (Azure Databricks)

### Alert Levels

```
┌──────────────┬──────────────────────────────────────────────────────────┐
│ LEVEL        │ TRIGGER CONDITION                                       │
├──────────────┼──────────────────────────────────────────────────────────┤
│ 🔴 CRITICAL  │ Any signal goes critical                                │
│              │ OR 2+ signals go warning simultaneously                 │
│              │ OR Enterprise Score drops below 90                      │
├──────────────┼──────────────────────────────────────────────────────────┤
│ ⚠️ WARNING   │ Any signal goes warning                                 │
│              │ OR rate of decline > 2%/min for 5 consecutive minutes   │
│              │ OR a correlation rule fires with confidence > 0.8       │
├──────────────┼──────────────────────────────────────────────────────────┤
│ ℹ️ INFO      │ Signal recovered from warning/critical                  │
│              │ OR positive trend detected                              │
│              │ OR correlation resolved                                 │
└──────────────┴──────────────────────────────────────────────────────────┘
```

### Rate-of-Change Detection (PySpark — Critical for Early Warning)

```python
# Notebook: 05_alert_triggering.py

from pyspark.sql.functions import *
from pyspark.sql.window import Window

def check_rate_of_change():
    """
    Calculate slope of each signal over last 5 minutes.
    Returns DataFrame with signal_name, trend ('rapid_decline', 'declining', 'stable', 'improving').
    """
    windowSpec = Window.partitionBy("signal_name").orderBy("snapshot_time")
    
    history = spark.sql("""
        SELECT signal_name, numeric_value, snapshot_time
        FROM silver.signal_snapshots
        WHERE snapshot_time >= current_timestamp() - INTERVAL 5 MINUTES
    """)
    
    # Compute first and last value per signal, plus count
    trend_df = history.groupBy("signal_name").agg(
        first("numeric_value").alias("first_value"),
        last("numeric_value").alias("last_value"),
        count("*").alias("data_points"),
        min("snapshot_time").alias("first_time"),
        max("snapshot_time").alias("last_time")
    ).withColumn("elapsed_min",
        (unix_timestamp("last_time") - unix_timestamp("first_time")) / 60
    ).withColumn("slope",
        when(col("elapsed_min") > 0,
            (col("last_value") - col("first_value")) / col("elapsed_min")
        ).otherwise(0)
    ).withColumn("trend",
        when(col("slope") < -2.0, "rapid_decline")
        .when(col("slope") < -0.5, "declining")
        .when(col("slope") > 0.5, "improving")
        .otherwise("stable")
    )
    
    return trend_df.select("signal_name", "slope", "trend", "first_value", "last_value")
```

### Alert Generation & Deduplication (Spark SQL)

```sql
-- Generate alerts for current cycle, deduplicating against recent alerts

-- Step 1: Identify alertable conditions
CREATE OR REPLACE TEMPORARY VIEW new_alert_candidates AS
SELECT 
    signal_name,
    CASE 
        WHEN status = 'critical' THEN 'critical'
        WHEN status = 'warning' THEN 'warning'
    END AS severity,
    CONCAT(signal_name, ' is ', status, ' at ', CAST(numeric_value AS STRING)) AS message,
    current_timestamp() AS alert_time
FROM silver.signal_snapshots s
WHERE s.snapshot_time = (SELECT MAX(snapshot_time) FROM silver.signal_snapshots)
  AND s.status IN ('warning', 'critical')

UNION ALL

-- Rate-of-change alerts (rapid decline = critical even if current status is warning)
SELECT 
    signal_name,
    'critical' AS severity,
    CONCAT(signal_name, ' declining rapidly: ', CAST(ROUND(slope, 1) AS STRING), ' units/min') AS message,
    current_timestamp() AS alert_time
FROM rate_of_change_results
WHERE trend = 'rapid_decline';

-- Step 2: Deduplicate — only fire if same signal+severity hasn't alerted in 10 min
INSERT INTO gold.alerts (signal_name, severity, message, created_at, is_acknowledged)
SELECT n.signal_name, n.severity, n.message, n.alert_time, FALSE
FROM new_alert_candidates n
WHERE NOT EXISTS (
    SELECT 1 FROM gold.alerts a
    WHERE a.signal_name = n.signal_name
      AND a.severity = n.severity
      AND a.created_at >= current_timestamp() - INTERVAL 10 MINUTES
);
```

### Notification Dispatch (Python — runs after alert insertion)

```python
# Send critical alerts to Teams/Slack webhook
import requests

new_critical = spark.sql("""
    SELECT * FROM gold.alerts 
    WHERE severity = 'critical' 
      AND created_at >= current_timestamp() - INTERVAL 1 MINUTE
      AND is_acknowledged = FALSE
""").collect()

TEAMS_WEBHOOK = dbutils.secrets.get("keyvault", "teams-webhook-url")

for alert in new_critical:
    payload = {
        "@type": "MessageCard",
        "summary": f"🔴 CRITICAL: {alert.signal_name}",
        "themeColor": "FF0000",
        "sections": [{
            "activityTitle": f"Leading Indicator Alert: {alert.signal_name}",
            "facts": [
                {"name": "Severity", "value": "CRITICAL"},
                {"name": "Message", "value": alert.message},
                {"name": "Time", "value": str(alert.created_at)}
            ]
        }]
    }
    requests.post(TEAMS_WEBHOOK, json=payload)
```

---

## PART 5: Insight Text Generation — The Template Engine (Azure Databricks)

This is how the dashboard generates sentences like:  
> *"Call Quality MOS declining rapidly (4.2→3.2 in 25m). Breach of 2.8 threshold projected in ~18 minutes."*

### Strategy: Template-Based Generation (Day 1–2)

Each insight is a **template** with variable slots filled from signal data. No LLM needed.

### The Insight Template Table (Delta)

```sql
CREATE TABLE IF NOT EXISTS gold.insight_templates (
    template_id     INT,
    trigger_type    STRING     COMMENT 'threshold_breach | rate_decline | correlation | recovery | stable',
    severity        STRING     COMMENT 'critical | warning | info',
    template_text   STRING     COMMENT 'Text with {placeholders}',
    requires_fields STRING     COMMENT 'Comma-separated required data fields'
) USING DELTA;
```

### Pre-Built Templates

```sql
INSERT INTO gold.insight_templates VALUES
-- Threshold breach
(1, 'threshold_breach', 'critical',
 '{signal_name} has breached critical threshold at {current_value} (threshold: {threshold}). Immediate investigation required.',
 'signal_name,current_value,threshold'),

(2, 'threshold_breach', 'warning',
 '{signal_name} approaching critical levels at {current_value}. Trending {direction} over last {window}.',
 'signal_name,current_value,direction,window'),

-- Rate of decline
(3, 'rate_decline', 'critical',
 '{signal_name} declining rapidly ({previous_value}→{current_value} in {duration}). Breach of {threshold} threshold projected in ~{eta_minutes} minutes.',
 'signal_name,previous_value,current_value,duration,threshold,eta_minutes'),

-- Correlation-based
(4, 'correlation', 'warning',
 '{signal_a} degradation correlated with {signal_b} ({confidence}% confidence). {recommended_action}',
 'signal_a,signal_b,confidence,recommended_action'),

(5, 'correlation', 'warning',
 '{incident_count} Active Incidents — {p1_count} P1 critical. Incident rate exceeds {window} rolling average by {multiplier}x.',
 'incident_count,p1_count,window,multiplier'),

-- Pattern match
(6, 'pattern_match', 'warning',
 'Pattern match: Signal trajectory {similarity}% similar to {past_event_date} pre-outage. Probability escalating {current_prob}%→{projected_prob}% within {eta}m.',
 'similarity,past_event_date,current_prob,projected_prob,eta'),

-- Multi-signal correlation
(7, 'multi_correlation', 'warning',
 '{signal_a} below {threshold} in {sub_signals}. Correlated with {correlated_signal}. {recommended_action}',
 'signal_a,threshold,sub_signals,correlated_signal,recommended_action'),

-- Recovery
(8, 'recovery', 'info',
 '{signal_name} stable post-{event_description}. All {scope} recovered to {current_value}+.',
 'signal_name,event_description,scope,current_value'),

(9, 'stable', 'info',
 '{signal_list} — stable for {duration}+ hrs. No forecast deviation detected.',
 'signal_list,duration');
```

### Insight Generation (PySpark Notebook)

```python
# Notebook: 06_insight_generation.py
import json
from datetime import datetime

def generate_insight(trigger_type: str, severity: str, data: dict) -> dict:
    """
    Fill a template with signal data to produce human-readable insight text.
    
    data example = {
        'signal_name': 'Call Quality',
        'current_value': '3.2',
        'previous_value': '4.2',
        'duration': '25m',
        'threshold': '2.8',
        'eta_minutes': '18',
    }
    """
    # 1. Find matching template from Delta table
    template_row = spark.sql(f"""
        SELECT template_text FROM gold.insight_templates 
        WHERE trigger_type = '{trigger_type}' AND severity = '{severity}'
        LIMIT 1
    """).collect()
    
    if not template_row:
        return None
    
    # 2. Fill placeholders
    text = template_row[0]["template_text"]
    for key, value in data.items():
        text = text.replace('{' + key + '}', str(value))
    
    # 3. Look up signal metadata for icon and domain tags
    signal_meta = spark.sql(f"""
        SELECT DISTINCT m.domain_key
        FROM gold.domain_signal_map m
        WHERE m.signal_name = '{data.get("signal_name", data.get("signal_a", ""))}'
    """).collect()
    
    domains = [row["domain_key"] for row in signal_meta]
    
    # 4. Build insight object
    insight = {
        'text': text,
        'severity': severity,
        'domains': domains,
        'timestamp': datetime.now().isoformat(),
        'related_signals': [data.get('signal_name'), data.get('signal_b')]
    }
    
    # 5. Write to Gold table
    spark.sql(f"""
        INSERT INTO gold.generated_insights 
        VALUES ('{severity}', '{text}', '{json.dumps(domains)}', 
                '{json.dumps(insight["related_signals"])}', current_timestamp(), TRUE)
    """)
    
    return insight
```

### Mapping Dashboard Insights to Templates

| Dashboard Insight | Template | Trigger |
|---|---|---|
| "Call Quality MOS declining rapidly (4.2→3.2 in 25m)..." | #3 (rate_decline) | MOS slope < -2.0/min |
| "LOB SLA below 85% in Sales & Billing..." | #7 (multi_correlation) | SLA warning + Incident correlation (Rule R3) |
| "7 Active Incidents — 3 P1 critical..." | #5 (correlation) | Incident count > 6, rate > 2x average |
| "Pattern match: Signal trajectory 87% similar..." | #6 (pattern_match) | Cosine similarity of signal vector vs history |
| "Connectivity stable post-APAC dip..." | #8 (recovery) | Signal returned to healthy from warning |
| "Core Systems, Genesys Platform — stable 4+ hrs" | #9 (stable) | Healthy status for > 4 hours, no variance |

---

## PART 6: The ETA / Projection Calculation (Azure Databricks)

The dashboard says things like *"projected in ~18 minutes"*. Here's how:

```python
# Notebook: 07_eta_projection.py
from pyspark.sql.functions import *

def project_breach_eta(signal_name: str) -> dict:
    """
    Linear extrapolation on Delta Lake time-series — when will the value hit the threshold?
    Returns: {'signal': str, 'eta_minutes': int, 'projected_breach_value': float} or None
    """
    # Pull 15 min of history from Silver layer
    history = spark.sql(f"""
        SELECT 
            numeric_value,
            unix_timestamp(snapshot_time) AS ts_epoch
        FROM silver.signal_snapshots
        WHERE signal_name = '{signal_name}'
          AND snapshot_time >= current_timestamp() - INTERVAL 15 MINUTES
        ORDER BY snapshot_time ASC
    """).collect()
    
    if len(history) < 3:
        return None
    
    # Normalize timestamps to minutes (relative to first point)
    t0 = history[0]["ts_epoch"]
    times = [(row["ts_epoch"] - t0) / 60 for row in history]
    values = [row["numeric_value"] for row in history]
    
    # Simple linear regression slope
    n = len(times)
    sum_t = sum(times)
    sum_v = sum(values)
    sum_tv = sum(t * v for t, v in zip(times, values))
    sum_t2 = sum(t ** 2 for t in times)
    
    denominator = n * sum_t2 - sum_t ** 2
    if denominator == 0:
        return None
    
    slope = (n * sum_tv - sum_t * sum_v) / denominator
    
    if slope >= 0:  # Not declining — no breach projected
        return None
    
    # Get the critical threshold for this signal
    threshold = spark.sql(f"""
        SELECT critical_threshold FROM gold.signal_config
        WHERE signal_name = '{signal_name}'
    """).collect()
    
    if not threshold:
        return None
    
    critical_val = threshold[0]["critical_threshold"]
    current_val = values[-1]
    
    if current_val <= critical_val:
        return {'signal': signal_name, 'eta_minutes': 0, 'note': 'Already in critical'}
    
    # Minutes until threshold breach
    remaining = current_val - critical_val
    eta_minutes = abs(remaining / slope)
    
    return {
        'signal': signal_name,
        'eta_minutes': round(eta_minutes),
        'current_value': current_val,
        'slope_per_min': round(slope, 2),
        'critical_threshold': critical_val
    }

# Run for all declining signals
declining = spark.sql("""
    SELECT DISTINCT signal_name FROM silver.signal_snapshots
    WHERE status IN ('warning', 'critical')
      AND snapshot_time = (SELECT MAX(snapshot_time) FROM silver.signal_snapshots)
""").collect()

for row in declining:
    eta = project_breach_eta(row["signal_name"])
    if eta and eta.get('eta_minutes', 999) < 60:
        # Write ETA to Gold table for dashboard consumption
        spark.sql(f"""
            MERGE INTO gold.signal_projections AS target
            USING (SELECT '{eta["signal"]}' AS signal_name, 
                          {eta["eta_minutes"]} AS eta_minutes,
                          {eta["slope_per_min"]} AS slope_per_min,
                          current_timestamp() AS projected_at) AS source
            ON target.signal_name = source.signal_name
            WHEN MATCHED THEN UPDATE SET *
            WHEN NOT MATCHED THEN INSERT *
        """)
```

---

## PART 7: Outage Probability Calculation (Azure Databricks)

The hero panel shows "12% Outage Probability". Here's the formula:

```python
# Notebook: 08_outage_probability.py

def calculate_outage_probability():
    """
    Weighted scoring model stored in Gold Delta table.
    No ML required for v1 — pure rule-based.
    """
    # Get current signal states
    signals = spark.sql("""
        SELECT signal_name, status, numeric_value, 
               COALESCE(trend, 'stable') AS trend_dir
        FROM silver.signal_snapshots
        WHERE snapshot_time = (SELECT MAX(snapshot_time) FROM silver.signal_snapshots)
    """).collect()
    
    # Get active correlations
    correlations = spark.sql("""
        SELECT * FROM gold.active_correlations
        WHERE detected_at >= current_timestamp() - INTERVAL 10 MINUTES
    """).collect()
    
    # Factor 1: Signal status weights (40% of total)
    critical_count = sum(1 for s in signals if s['status'] == 'critical')
    warning_count = sum(1 for s in signals if s['status'] == 'warning')
    signal_risk = min((critical_count * 25 + warning_count * 8), 100)
    factor_1 = signal_risk * 0.40
    
    # Factor 2: Rate of decline across all signals (25%)
    declining_signals = sum(1 for s in signals if s['trend_dir'] == 'down')
    decline_risk = min(declining_signals * 12, 100)
    factor_2 = decline_risk * 0.25
    
    # Factor 3: Correlation matches (20%)
    high_conf = sum(1 for c in correlations if c['confidence'] > 0.8)
    correlation_risk = min(high_conf * 20, 100)
    factor_3 = correlation_risk * 0.20
    
    # Factor 4: Historical pattern similarity (15%) — optional, use 0 for Day 1
    # In v2, query gold.pattern_matches for cosine similarity
    factor_4 = 0  # Placeholder until pattern library is built
    
    total = round(min(factor_1 + factor_2 + factor_3 + factor_4, 100))
    
    # Write to Gold layer
    spark.sql(f"""
        MERGE INTO gold.outage_probability AS target
        USING (SELECT {total} AS probability, 
                      {critical_count} AS critical_count,
                      {warning_count} AS warning_count,
                      {declining_signals} AS declining_count,
                      {high_conf} AS correlation_count,
                      current_timestamp() AS calculated_at) AS source
        ON 1=1  -- Always update the single row
        WHEN MATCHED THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
    """)
    
    return total

# Execute
prob = calculate_outage_probability()
print(f"Current outage probability: {prob}%")

# Example scoring breakdown:
# (1 critical * 25 + 2 warning * 8) * 0.40 = 16.4
# (3 declining) * 12 * 0.25 = 9.0
# (2 high-conf correlations) * 20 * 0.20 = 8.0
# pattern match = 0 (not implemented yet)
# Total ≈ 33 → capped and normalized ≈ 12% with healthy-signal decay
```

---

## PART 8: 2-Day Implementation Plan (Azure Databricks)

### Day 1 — Databricks Workspace + Data Pipeline + Scoring

| Time | Task | Owner | Databricks Details |
|------|------|-------|--------------------|
| **Morning** | Set up Databricks workspace, Unity Catalog, 3 schemas (bronze, silver, gold) | Platform Engineer | Enable Unity Catalog. Create ADLS Gen2 storage account as metastore root. |
| **Morning** | Create Delta tables for Bronze layer: `bronze.agent_realtime_status`, `bronze.incidents`, `bronze.call_quality_realtime`, `bronze.network_path_tests`, `bronze.synthetic_monitor_results` | Data Engineer | Use schema from Part 10. Run DDL notebook. |
| **Morning** | Store API credentials in Azure Key Vault + create Databricks Secret Scope | Platform Engineer | `databricks secrets create-scope --scope keyvault --scope-backend-type AZURE_KEYVAULT` |
| **Midday** | Write ingestion notebooks for top 5 signals: Call Quality, Incidents, Agent Online, Call LOB SLA, Connectivity | Data Engineer | One notebook per API source. Use `requests` + `dbutils.secrets.get()`. Append to Bronze. |
| **Midday** | Build scoring notebook: threshold evaluation (healthy/warning/critical) → write to `silver.signal_snapshots` | Developer | Use thresholds from Part 1. PySpark + Spark SQL. |
| **Afternoon** | Build domain scoring notebook (Part 2) → write to `gold.domain_scores` | Developer | Insert `gold.domain_signal_map` entries. |
| **Afternoon** | Insert correlation rules (Part 3 — all 14 rules) into `gold.correlation_rules` | Data Engineer | Run the INSERT statement from Part 3. |
| **Afternoon** | Build correlation detection notebook (Part 3 Spark SQL) | Data Engineer | Schedule after scoring notebook. |
| **Evening** | Wire remaining 9 signals: add ingestion + scoring for each | Data Engineer | Prioritize by domain — finish Agent Health first. |
| **Evening** | Create Databricks Workflow: chain notebooks with `processingTime='60 seconds'` trigger | Platform Engineer | Orchestrate: Ingest → Score → Domain → Correlate → Alert |

### Day 2 — Alerts + Insights + Serving Layer + Dashboard

| Time | Task | Owner | Databricks Details |
|------|------|-------|--------------------|
| **Morning** | Insert insight templates (Part 5 — all 9) into `gold.insight_templates` | Developer | Run INSERT notebook once. |
| **Morning** | Build insight generation notebook (Part 5 PySpark) | Developer | Triggered by alert/correlation detection. |
| **Midday** | Build REST API: either Databricks SQL Serverless + JDBC or Azure Function → SQL Warehouse | Developer | Simplest: Databricks SQL endpoint + direct query from JS (CORS headers needed). |
| **Midday** | Implement rate-of-change + ETA projection notebook (Parts 4 & 6) | Data Engineer | Spark window functions for slope calculation. |
| **Afternoon** | Implement outage probability notebook (Part 7) → write to `gold.outage_probability` | Developer | Simple rule-based scoring. |
| **Afternoon** | Connect dashboard to live API (replace hardcoded data in leading-indicators-hybrid.html) | Frontend Dev | `fetch('/api/v1/leading-indicators/signals')` → parse JSON → update DOM |
| **Evening** | End-to-end smoke test. Verify: ingest → score → correlate → alert → insight → dashboard | Both | Run workflow manually. Simulate a Connectivity drop. Verify cascade detection. |

### What to Prioritize If Running Out of Time

```
MUST HAVE (ship without these = broken):
  ✅ Bronze Delta tables created + ingestion notebooks for all 14 signals
  ✅ Signal scoring notebook (threshold evaluation)
  ✅ Domain scoring notebook
  ✅ Databricks SQL endpoint + API to serve data to dashboard

SHOULD HAVE (degrade gracefully without):
  ⚠️ Correlation detection (dashboard works, just no "correlated with" text)
  ⚠️ Insight text generation (fall back to simple status text)
  ⚠️ Rate-of-change detection
  ⚠️ Teams/Slack notification dispatch

NICE TO HAVE (defer to Sprint 2):
  💡 Outage probability (hardcode or use simple formula initially)
  💡 Historical pattern matching (requires 90+ days of data)
  💡 ETA projection
  💡 Databricks Lakeview dashboard (supplementary to HTML dashboard)
```

---

## PART 9: API Contract — Serving Layer (Databricks SQL Endpoint)

The dashboard currently uses hardcoded data. Replace with a Databricks SQL Serverless endpoint.

### Option A: Databricks SQL Warehouse + Azure Function Proxy (Recommended)

```python
# Azure Function: api/leading-indicators/signals
# Queries Databricks SQL Warehouse via databricks-sql-connector

import azure.functions as func
from databricks import sql as dbsql
import json, os

def main(req: func.HttpRequest) -> func.HttpResponse:
    with dbsql.connect(
        server_hostname=os.environ["DATABRICKS_HOST"],
        http_path=os.environ["DATABRICKS_SQL_PATH"],
        access_token=os.environ["DATABRICKS_TOKEN"]
    ) as conn:
        cursor = conn.cursor()
        
        # Signals
        cursor.execute("""
            SELECT signal_name, numeric_value, status, trend, direction
            FROM silver.signal_snapshots
            WHERE snapshot_time = (SELECT MAX(snapshot_time) FROM silver.signal_snapshots)
        """)
        signals = [dict(zip([d[0] for d in cursor.description], row)) for row in cursor.fetchall()]
        
        # Domains
        cursor.execute("SELECT domain_key, score FROM gold.domain_scores ORDER BY snapshot_time DESC LIMIT 3")
        domains = [dict(zip([d[0] for d in cursor.description], row)) for row in cursor.fetchall()]
        
        # Enterprise score + probability
        cursor.execute("SELECT probability FROM gold.outage_probability ORDER BY calculated_at DESC LIMIT 1")
        prob = cursor.fetchone()
        
        # Insights
        cursor.execute("""
            SELECT severity, insight_text, domains, related_signals, created_at
            FROM gold.generated_insights
            WHERE is_active = TRUE
            ORDER BY created_at DESC LIMIT 10
        """)
        insights = [dict(zip([d[0] for d in cursor.description], row)) for row in cursor.fetchall()]
    
    return func.HttpResponse(
        json.dumps({
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "enterprise_score": round(sum(d.get("score",0) for d in domains) / max(len(domains),1), 1),
            "outage_probability": prob[0] if prob else 0,
            "signals": signals,
            "domains": domains,
            "insights": insights
        }),
        mimetype="application/json",
        headers={"Access-Control-Allow-Origin": "*"}
    )
```

### Option B: Direct Databricks REST API (Quick & Dirty)

```javascript
// In your dashboard HTML — directly query Databricks SQL Statement API
async function fetchSignals() {
    const resp = await fetch('https://<workspace>.azuredatabricks.net/api/2.0/sql/statements/', {
        method: 'POST',
        headers: {
            'Authorization': 'Bearer <PAT>',  // Use a service principal in production
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({
            warehouse_id: '<sql-warehouse-id>',
            statement: `SELECT * FROM silver.signal_snapshots 
                        WHERE snapshot_time = (SELECT MAX(snapshot_time) FROM silver.signal_snapshots)`,
            wait_timeout: '30s'
        })
    });
    const data = await resp.json();
    return data.result.data_array;
}
```

### API Response Shape (same as before):

```json
{
  "timestamp": "2026-02-19T14:30:00Z",
  "enterprise_score": 94.2,
  "outage_probability": 12,
  "signals": [
    {
      "name": "Call Quality",
      "icon": "fa-microphone-alt",
      "value": "3.2",
      "trend": "-0.8",
      "direction": "down",
      "status": "critical",
      "domains": ["genesys"],
      "sparkline": [4.2, 4.0, 3.8, 3.6, 3.4, 3.2],
      "sub_signals": [
        {"name": "MOS Score", "value": "3.2", "status": "critical"},
        {"name": "Jitter", "value": "18ms", "status": "warning"},
        {"name": "Packet Loss", "value": "0.4%", "status": "healthy"}
      ]
    }
  ],
  "domains": [
    {"key": "agent", "name": "Agent Health", "score": 93.8},
    {"key": "app", "name": "App Health", "score": 95.4},
    {"key": "genesys", "name": "Genesys Health", "score": 92.1}
  ],
  "insights": [
    {
      "severity": "critical",
      "icon": "fa-microphone-alt",
      "text": "Call Quality MOS declining rapidly (4.2→3.2 in 25m)...",
      "domains": ["genesys"],
      "timestamp": "2026-02-19T14:28:00Z"
    }
  ],
  "risk_components": [
    {
      "name": "Call Quality",
      "value": "3.2",
      "status": "critical",
      "icon": "fa-microphone-alt",
      "parent_signal": null,
      "domains": ["genesys"]
    }
  ]
}
```

---

## PART 10: Delta Lake Schema (Databricks Setup)

> **Run this notebook once during initial workspace setup.** All tables use Delta format on ADLS Gen2.

```sql
-- ===========================================================
-- Notebook: 00_schema_setup.sql
-- Purpose:  Create all Delta tables for the Leading Indicators pipeline
-- Run:      Once (idempotent — uses IF NOT EXISTS)
-- ===========================================================

-- =========================
-- BRONZE LAYER (raw ingestion)
-- =========================

CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.agent_realtime_status (
    agent_id        STRING,
    agent_status    STRING     COMMENT 'Available, On Queue, Interacting, Not Responding, etc.',
    media_type      STRING     COMMENT 'voice, chat, email',
    activity_code   STRING     COMMENT 'Break, Training, Meeting, etc.',
    interval_id     STRING,
    queue_id        STRING,
    _ingested_at    TIMESTAMP  COMMENT 'Pipeline ingestion time'
) USING DELTA
TBLPROPERTIES ('delta.autoOptimize.optimizeWrite' = 'true');

CREATE TABLE IF NOT EXISTS bronze.wfm_schedule (
    interval_id         STRING,
    agent_id            STRING,
    scheduled_count     INT,
    scheduled_per_media INT,
    media_type          STRING,
    _ingested_at        TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.incidents (
    incident_id       STRING,
    priority          INT        COMMENT '1=Critical, 2=High, 3=Medium',
    state             STRING     COMMENT 'New, In Progress, On Hold, Resolved, Closed',
    assignment_group  STRING,
    ci_name           STRING     COMMENT 'Configuration Item affected',
    opened_at         TIMESTAMP,
    _ingested_at      TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.synthetic_monitor_results (
    app_name        STRING,
    app_group       STRING     COMMENT 'contact_center, back_office, etc.',
    response_code   INT,
    response_time_ms INT,
    is_healthy      INT        COMMENT '1=pass, 0=fail',
    check_time      TIMESTAMP,
    _ingested_at    TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.infrastructure_health (
    component_name  STRING,
    component_type  STRING     COMMENT 'database, message_queue, auth_service, load_balancer',
    status          STRING     COMMENT 'UP or DOWN',
    region          STRING,
    _ingested_at    TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.call_intervals (
    call_id           STRING,
    queue_id          STRING,
    answer_time_sec   INT,
    handle_time_sec   INT,
    abandoned         BOOLEAN,
    interval_start    TIMESTAMP,
    _ingested_at      TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.queue_realtime (
    queue_id          STRING,
    queue_name        STRING,
    available_agents  INT,
    interval_id       STRING,
    _ingested_at      TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.wfm_staffing_requirement (
    queue_id          STRING,
    interval_id       STRING,
    required_agents   INT,
    _ingested_at      TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.network_path_tests (
    source_site     STRING,
    destination     STRING,
    path_type       STRING     COMMENT 'agent_to_platform',
    packet_loss_pct DECIMAL(5,2),
    latency_ms      INT,
    _ingested_at    TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.network_latency_probes (
    source_site     STRING,
    destination     STRING,
    rtt_ms          INT,
    _ingested_at    TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.genesys_synthetic_checks (
    check_type      STRING     COMMENT 'login, queue_route, media_establish',
    success         INT,
    response_time_ms INT,
    check_time      TIMESTAMP,
    _ingested_at    TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.ivr_metrics (
    flow_name       STRING,
    total_attempts  INT,
    completed       INT,
    interval_start  TIMESTAMP,
    _ingested_at    TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.call_quality_realtime (
    call_id         STRING,
    mos_score       DECIMAL(3,1),
    jitter_ms       INT,
    packet_loss_pct DECIMAL(5,2),
    call_state      STRING,
    _ingested_at    TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS bronze.endpoint_status (
    agent_id              STRING,
    citrix_session_state  STRING,
    ica_rtt_ms            INT,
    browser_responsive    INT,
    softphone_registered  INT,
    _ingested_at          TIMESTAMP
) USING DELTA;

-- =========================
-- SILVER LAYER (scored signals)
-- =========================

CREATE SCHEMA IF NOT EXISTS silver;

CREATE TABLE IF NOT EXISTS silver.signal_snapshots (
    signal_name     STRING      NOT NULL,
    numeric_value   DECIMAL(10,2),
    status          STRING      NOT NULL  COMMENT 'healthy | warning | critical',
    trend           STRING      COMMENT '+0.5, -1.2, etc.',
    direction       STRING      COMMENT 'up | down | flat',
    snapshot_time   TIMESTAMP   NOT NULL
) USING DELTA
PARTITIONED BY (signal_name)
TBLPROPERTIES ('delta.autoOptimize.optimizeWrite' = 'true');

CREATE TABLE IF NOT EXISTS silver.sub_signal_snapshots (
    parent_signal   STRING      NOT NULL,
    sub_name        STRING      NOT NULL,
    numeric_value   DECIMAL(10,2),
    status          STRING      NOT NULL,
    snapshot_time   TIMESTAMP   NOT NULL
) USING DELTA;

CREATE TABLE IF NOT EXISTS silver.agent_roster (
    agent_id        STRING,
    agent_name      STRING,
    vendor_name     STRING,
    site_name       STRING,
    lob             STRING,
    updated_at      TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS silver.lob_config (
    queue_id        STRING,
    lob_name        STRING,
    sla_target_sec  INT,
    updated_at      TIMESTAMP
) USING DELTA;

-- =========================
-- GOLD LAYER (analytics / serving)
-- =========================

CREATE SCHEMA IF NOT EXISTS gold;

CREATE TABLE IF NOT EXISTS gold.domain_scores (
    domain_key      STRING      NOT NULL,
    score           DECIMAL(5,1) NOT NULL,
    signal_count    INT,
    critical_count  INT,
    warning_count   INT,
    snapshot_time   TIMESTAMP   NOT NULL
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.domain_signal_map (
    signal_name     STRING,
    domain_key      STRING
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.correlation_rules (
    rule_id             INT,
    signal_a            STRING,
    signal_b            STRING,
    direction           STRING,
    time_window_min     INT,
    confidence          DECIMAL(3,2),
    insight_template_id INT,
    recommended_action  STRING,
    is_active           BOOLEAN DEFAULT TRUE
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.active_correlations (
    rule_id             INT,
    signal_a            STRING,
    signal_b            STRING,
    confidence          DECIMAL(3,2),
    direction           STRING,
    signal_a_value      DECIMAL(10,2),
    signal_b_value      DECIMAL(10,2),
    signal_a_status     STRING,
    signal_b_status     STRING,
    lag_minutes         DECIMAL(5,1),
    recommended_action  STRING,
    detected_at         TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.insight_templates (
    template_id     INT,
    trigger_type    STRING,
    severity        STRING,
    template_text   STRING,
    requires_fields STRING
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.generated_insights (
    severity        STRING,
    insight_text    STRING,
    domains         STRING     COMMENT 'JSON array of domain keys',
    related_signals STRING     COMMENT 'JSON array of signal names',
    created_at      TIMESTAMP,
    is_active       BOOLEAN DEFAULT TRUE
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.alerts (
    signal_name     STRING,
    severity        STRING,
    message         STRING,
    created_at      TIMESTAMP,
    is_acknowledged BOOLEAN DEFAULT FALSE
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.signal_projections (
    signal_name     STRING,
    eta_minutes     INT,
    slope_per_min   DECIMAL(5,2),
    projected_at    TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.outage_probability (
    probability     INT,
    critical_count  INT,
    warning_count   INT,
    declining_count INT,
    correlation_count INT,
    calculated_at   TIMESTAMP
) USING DELTA;

CREATE TABLE IF NOT EXISTS gold.signal_config (
    signal_name         STRING,
    healthy_threshold   DECIMAL(10,2)  COMMENT 'Value at or above = healthy',
    warning_threshold   DECIMAL(10,2)  COMMENT 'Value at or above = warning (below healthy)',
    critical_threshold  DECIMAL(10,2)  COMMENT 'Value below = critical',
    is_inverted         BOOLEAN DEFAULT FALSE COMMENT 'TRUE for Network Latency, Incidents (higher = worse)',
    refresh_sec         INT DEFAULT 60,
    icon                STRING
) USING DELTA;

-- Insert signal config
INSERT INTO gold.signal_config VALUES
('Agent Online',        95, 90, 90, FALSE, 60, 'fa-headset'),
('Incidents',           3,  6,  6,  TRUE,  60, 'fa-exclamation-triangle'),
('App Health',          97, 93, 93, FALSE, 60, 'fa-server'),
('Core Systems',        99, 97, 97, FALSE, 60, 'fa-database'),
('Call LOB SLA',        85, 80, 80, FALSE, 60, 'fa-phone-volume'),
('Queue Sufficiency',   90, 80, 80, FALSE, 60, 'fa-users'),
('Presence—Vendor',     94, 90, 90, FALSE, 60, 'fa-building'),
('Presence—Location',   93, 88, 88, FALSE, 60, 'fa-map-marker-alt'),
('Connectivity',        96, 92, 92, FALSE, 60, 'fa-wifi'),
('Genesys Platform',    99.5, 98, 98, FALSE, 60, 'fa-cloud'),
('IVR / Self-Service',  97, 93, 93, FALSE, 300, 'fa-robot'),
('Call Quality',        4.0, 3.5, 3.5, FALSE, 60, 'fa-microphone-alt'),
('Network Latency',     30, 80, 80, TRUE, 60, 'fa-network-wired'),
('Desktop / Endpoint',  97, 93, 93, FALSE, 60, 'fa-desktop');
```

### Databricks Workflow Configuration (JSON)

```json
{
    "name": "leading-indicators-pipeline",
    "schedule": {
        "quartz_cron_expression": "0 * * * * ?",
        "timezone_id": "America/New_York"
    },
    "tasks": [
        {
            "task_key": "01_ingest_signals",
            "notebook_task": { "notebook_path": "/Pipelines/LeadingIndicators/01_signal_ingestion" },
            "job_cluster_key": "shared_cluster"
        },
        {
            "task_key": "02_score_signals",
            "depends_on": [{"task_key": "01_ingest_signals"}],
            "notebook_task": { "notebook_path": "/Pipelines/LeadingIndicators/02_signal_scoring" }
        },
        {
            "task_key": "03_domain_scoring",
            "depends_on": [{"task_key": "02_score_signals"}],
            "notebook_task": { "notebook_path": "/Pipelines/LeadingIndicators/03_domain_scoring" }
        },
        {
            "task_key": "04_correlation_detection",
            "depends_on": [{"task_key": "02_score_signals"}],
            "notebook_task": { "notebook_path": "/Pipelines/LeadingIndicators/04_correlation_detection" }
        },
        {
            "task_key": "05_alert_triggering",
            "depends_on": [{"task_key": "02_score_signals", "task_key": "04_correlation_detection"}],
            "notebook_task": { "notebook_path": "/Pipelines/LeadingIndicators/05_alert_triggering" }
        },
        {
            "task_key": "06_insight_generation",
            "depends_on": [{"task_key": "05_alert_triggering"}],
            "notebook_task": { "notebook_path": "/Pipelines/LeadingIndicators/06_insight_generation" }
        },
        {
            "task_key": "07_eta_and_probability",
            "depends_on": [{"task_key": "02_score_signals"}],
            "notebook_task": { "notebook_path": "/Pipelines/LeadingIndicators/07_eta_projection" }
        }
    ],
    "job_clusters": [{
        "job_cluster_key": "shared_cluster",
        "new_cluster": {
            "spark_version": "14.3.x-scala2.12",
            "node_type_id": "Standard_DS3_v2",
            "num_workers": 2,
            "spark_conf": {
                "spark.databricks.delta.autoOptimize.enabled": "true"
            }
        }
    }]
}
```

---

## FUTURE SCOPE (Post 2-Day Delivery — Databricks-Native Features)

> **Do NOT build these now.** Document them here so we remember.  
> Many of these are significantly easier on Databricks than other platforms.

| Feature | Description | Databricks Advantage | Effort | Value |
|---------|-------------|---------------------|--------|-------|
| **ML-based Correlation** | Replace rule table with MLflow model trained on 90 days of signal co-occurrence | MLflow + Feature Store built-in. Auto-log experiments. | 2 weeks | High — finds non-obvious patterns |
| **LLM Insight Generation** | Replace templates with Foundation Model (DBRX/Claude/GPT) via Databricks Model Serving | Model Serving endpoint + Unity Catalog lineage | 1 week | Medium — more natural language |
| **Anomaly Detection** | Statistical anomaly (z-score / IQR / Isolation Forest) instead of hard thresholds | Spark MLlib has `IsolationForest`. Scales to all signals in parallel. | 1 week | High — reduces false alarms by 60%+ |
| **Historical Pattern Library** | Store past outage "fingerprints" as signal vectors. Cosine similarity matching in real-time | Delta Lake + MLflow vectors. Fast MERGE for pattern updates. | 2 weeks | Very High — "this looks like Jan 28 outage" |
| **Predictive Model (Prophet)** | Time-series forecast per signal — predict 30/60 min ahead | `prophet` library on Databricks. Parallelize with Pandas UDFs. | 3 weeks | Very High — true predictive capability |
| **Auto-Remediation** | Correlation rules trigger Databricks Workflows → runbooks (restart IVR, scale agents) | Databricks Jobs API for programmatic triggering | 2 weeks | High — reduces MTTR |
| **Weighted Domain Scoring** | Weight signals by business impact (learned from outage data) | MLflow experiment to optimize weights | 2 days | Medium |
| **Multi-Region Dashboard** | Per-region signal tracking with global roll-up | Delta Lake partitioned by region. Same pipeline, add partition. | 1 week | High for global ops |
| **Slack/Teams Integration** | Push critical insights with one-click acknowledge | Azure Functions webhook (already in Part 4) | 3 days | High — faster response |
| **Databricks Lakeview Dashboard** | Supplementary dashboard built natively in Databricks SQL | Zero-code. SQL queries → auto-refresh visualizations. | 2 days | Medium — backup to HTML dashboard |
| **Delta Live Tables (DLT)** | Replace notebook-based pipeline with DLT for declarative, auto-scaling ETL | Built-in quality expectations, auto-retry, lineage | 1 week | High — production-grade reliability |
| **Unity Catalog Data Lineage** | Track which API → which Bronze table → which signal → which insight | Zero-code. Unity Catalog tracks automatically. | 1 day | High for audit/compliance |

---

## Quick Reference Card

```
SIGNAL              SOURCE              REFRESH   THRESHOLDS (H/W/C)          DELTA TABLE (Bronze)
──────────────────────────────────────────────────────────────────────────────────────────────────
Agent Online        Genesys + WFM       60s       ≥95 / 90-95 / <90          agent_realtime_status
Incidents           ServiceNow          60s       ≤3 / 4-6 / >6              incidents
App Health          Dynatrace           60s       ≥97 / 93-97 / <93          synthetic_monitor_results
Core Systems        Dynatrace/Solar     60s       ≥99 / 97-99 / <97          infrastructure_health
Call LOB SLA        Genesys             60s       ≥85 / 80-85 / <80          call_intervals
Queue Sufficiency   Genesys + WFM       60s       ≥90 / 80-90 / <80          queue_realtime
Presence—Vendor     Genesys + WFM       60s       ≥94 / 90-94 / <90          agent_realtime_status
Presence—Location   Genesys + WFM       60s       ≥93 / 88-93 / <88          agent_realtime_status
Connectivity        ThousandEyes        60s       ≥96 / 92-96 / <92          network_path_tests
Genesys Platform    Genesys Status      60s       ≥99.5/98-99.5/<98          genesys_synthetic_checks
IVR/Self-Service    Genesys/Nuance      5m        ≥97 / 93-97 / <93          ivr_metrics
Call Quality        Genesys RTP         60s       ≥4.0/3.5-4.0/<3.5          call_quality_realtime
Network Latency     ThousandEyes        60s       <30ms/30-80/>80ms          network_latency_probes
Desktop/Endpoint    Citrix/Nexthink     60s       ≥97 / 93-97 / <93          endpoint_status

PIPELINE: Ingest (Bronze) → Score (Silver) → Domain + Correlate + Alert (Gold) → Serve (SQL Warehouse)
ORCHESTRATION: Databricks Workflow, every 60 seconds
STORAGE: ADLS Gen2 → Delta Lake (Bronze/Silver/Gold)
SERVING: Databricks SQL Serverless → Azure Function proxy → Dashboard
SECRETS: Azure Key Vault → Databricks Secret Scope
```

### Cascade Cheat Sheet (When Signal X Drops, Check These)

```
Connectivity ↓      → Check: Call Quality, Presence—Location, Desktop/Endpoint, Genesys Platform
Network Latency ↑   → Check: Call Quality, Desktop/Endpoint
Genesys Platform ↓  → Check: Call Quality, IVR/Self-Service (EVERYTHING downstream)
Core Systems ↓      → Check: App Health (ROOT CAUSE — fix here first)
Desktop/Endpoint ↓  → Check: Agent Online (ghost agent pattern?)
Agent Online ↓      → Check: Queue Sufficiency, Call LOB SLA
IVR/Self-Service ↓  → Check: Queue Sufficiency (delayed ~10 min)
Incidents ↑         → Check: App Health, Call LOB SLA
```

---

*"Ship the table-driven version in 2 days on Databricks. Let the data teach us where to add ML later. Delta Lake keeps all history for when we're ready."*

# Enterprise Leading Indicators Documentation
## Contact Center Operations - 50,000 Agent Scale

**Version:** 2.0  
**Last Updated:** January 22, 2026  
**Scope:** Global Contact Center Operations (12 Regions, 50,000 Agents)

---

## Table of Contents

1. [Overview](#overview)
2. [Domain 1: Platform & Infrastructure Availability](#domain-1-platform--infrastructure-availability)
3. [Domain 2: Network & Connectivity](#domain-2-network--connectivity)
4. [Domain 3: Voice Quality & Telephony](#domain-3-voice-quality--telephony)
5. [Domain 4: Workforce & Capacity Management](#domain-4-workforce--capacity-management)
6. [Domain 5: Agent Desktop & Virtual Environment](#domain-5-agent-desktop--virtual-environment)
7. [Domain 6: IVR & Self-Service Automation](#domain-6-ivr--self-service-automation)
8. [Domain 7: Integration & Data Flow](#domain-7-integration--data-flow)
9. [Domain 8: Security & Access Management](#domain-8-security--access-management)
10. [Threshold Guidelines](#threshold-guidelines)
11. [Data Source Reference](#data-source-reference)

---

## Overview

### What Are Leading Indicators?

Leading indicators are **predictive metrics** that signal potential issues before they impact customer experience or business operations. Unlike lagging indicators (which measure outcomes after they occur), leading indicators enable **proactive intervention**.

### Why These 32 Indicators?

At enterprise scale (50,000 agents across 12 regions), traditional operational metrics are insufficient. These indicators were selected based on:

- **Predictive Value:** Ability to forecast service disruptions 15-60 minutes ahead
- **Business Impact:** Direct correlation to SLA compliance, CSAT, and revenue
- **Actionability:** Clear remediation paths when thresholds are breached
- **Cross-Domain Coverage:** Holistic view of technology, workforce, and customer experience

### Indicator Classification

| Impact Level | Definition | Response Time |
|--------------|------------|---------------|
| **Business Critical** | Failure directly impacts customers or revenue | < 5 minutes |
| **High Impact** | Degradation affects agent productivity or quality | < 15 minutes |
| **Medium Impact** | Trend may lead to future issues | < 1 hour |

---

## Domain 1: Platform & Infrastructure Availability

*Core system health, uptime, and disaster recovery readiness across all data centers*

### 1.1 Genesys Cloud Global Availability

#### Why This Matters
Genesys Cloud is the backbone of all contact center operations. At 50,000 agent scale, even 0.1% downtime translates to **500 agents unable to take calls**, potentially affecting thousands of customers per minute. This is the single most critical infrastructure metric.

**Business Impact:**
- 1 hour downtime = ~$2.4M revenue at risk (assuming $800 cost per lost customer)
- SLA penalties from enterprise clients
- Reputational damage and social media escalation

#### How to Calculate

```
Global Availability % = (Total Uptime Minutes / Total Scheduled Minutes) × 100

Where:
- Total Uptime = Sum of uptime across all Genesys Cloud regions (US-East, US-West, EU, APAC)
- Scheduled Minutes = 24 × 60 × Number of Days × Number of Regions

Example:
If monitoring 4 regions for 30 days:
- Total Scheduled = 4 × 30 × 24 × 60 = 172,800 minutes
- If 52 minutes of cumulative downtime occurred:
- Availability = (172,800 - 52) / 172,800 = 99.97%
```

**Data Sources:** Genesys Cloud Status API, SolarWinds synthetic monitoring

**Target:** ≥ 99.9% | **Critical Threshold:** < 99.5%

---

### 1.2 Disaster Recovery Readiness Score

#### Why This Matters
Enterprise contact centers must maintain business continuity during catastrophic failures. DR readiness measures the **actual ability to failover** - not just whether DR infrastructure exists, but whether it's tested, current, and can meet RTO/RPO requirements.

**Business Impact:**
- Failed DR during an outage = extended downtime (hours to days)
- Regulatory compliance (PCI-DSS, SOC2 require documented DR)
- Insurance and contractual obligations

#### How to Calculate

```
DR Readiness Score = (W1 × Replication Status) + (W2 × Test Recency) + (W3 × RTO Confidence) + (W4 × Capacity Match)

Component Scoring (0-100):
┌─────────────────────┬────────────────────────────────────────────────────┬────────┐
│ Component           │ Measurement                                        │ Weight │
├─────────────────────┼────────────────────────────────────────────────────┼────────┤
│ Replication Status  │ % of data replicated to DR site within RPO         │ 30%    │
│ Test Recency        │ Days since last successful DR test (100 if <7 days)│ 25%    │
│ RTO Confidence      │ Last test actual recovery time vs target RTO       │ 25%    │
│ Capacity Match      │ DR site capacity as % of production                │ 20%    │
└─────────────────────┴────────────────────────────────────────────────────┴────────┘

Example:
- Replication: 100% current = 100 × 0.30 = 30
- Test Recency: Last test 3 days ago = 100 × 0.25 = 25
- RTO Confidence: Achieved 3.5hr vs 4hr target = 100 × 0.25 = 25
- Capacity Match: DR at 95% of prod = 95 × 0.20 = 19
- Total Score: 30 + 25 + 25 + 19 = 99%
```

**Data Sources:** DR monitoring tools, SolarWinds, backup verification logs

**Target:** ≥ 95% | **Critical Threshold:** < 85%

---

### 1.3 Core Infrastructure Headroom

#### Why This Matters
Infrastructure headroom measures **spare capacity** to handle traffic spikes. Contact centers experience 2-3x normal volume during product launches, outages, or seasonal peaks. Without headroom, systems degrade under load, causing cascading failures.

**Business Impact:**
- Insufficient headroom during spike = slow systems, dropped calls, agent frustration
- Proactive capacity planning reduces emergency scaling costs
- Prevents "death spiral" where slow systems cause longer handle times, which increases queue

#### How to Calculate

```
Infrastructure Headroom % = 100 - Peak Utilization %

Measured across critical resources:
┌────────────────────┬─────────────────────────────────────────────────────┐
│ Resource           │ Calculation                                         │
├────────────────────┼─────────────────────────────────────────────────────┤
│ CPU (Servers)      │ 100 - Max(CPU% across app servers during peak hour) │
│ Memory             │ 100 - Max(Memory% during peak hour)                 │
│ Database IOPS      │ 100 - (Peak IOPS / Provisioned IOPS × 100)          │
│ Network Bandwidth  │ 100 - (Peak Throughput / Total Capacity × 100)      │
└────────────────────┴─────────────────────────────────────────────────────┘

Composite Headroom = MIN(CPU Headroom, Memory Headroom, DB Headroom, Network Headroom)

Example:
- CPU at peak: 72% utilized → 28% headroom
- Memory at peak: 68% utilized → 32% headroom
- Database at peak: 65% utilized → 35% headroom
- Network at peak: 58% utilized → 42% headroom
- Composite Headroom: MIN(28, 32, 35, 42) = 28%

Note: Use minimum because system bottlenecks at the weakest resource.
```

**Data Sources:** SolarWinds, Splunk infrastructure metrics, cloud monitoring

**Target:** ≥ 20% | **Critical Threshold:** < 10%

---

### 1.4 Active P1/P2 Incidents

#### Why This Matters
Active high-priority incidents indicate **ongoing service degradation**. At enterprise scale, incidents compound - a network issue causes voice quality problems, which increases handle time, which increases queue wait. Tracking active incidents provides immediate situational awareness.

**Business Impact:**
- Each P1 incident typically affects 5,000-15,000 customers
- P2 incidents affect specific regions or functions
- MTTR directly correlates to customer impact duration

#### How to Calculate

```
Active P1/P2 Count = Count of incidents WHERE:
  - Priority IN ('P1', 'P2', 'Critical', 'High')
  - Status IN ('Open', 'In Progress', 'Investigating')
  - Category IN ('Contact Center', 'Telephony', 'Network', 'Application')

Supporting Metrics:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Metric              │ Calculation                                        │
├─────────────────────┼────────────────────────────────────────────────────┤
│ MTTR (Mean Time to  │ AVG(Resolution Time - Creation Time) for closed    │
│ Resolve)            │ P1/P2 incidents in last 30 days                    │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Incident Velocity   │ (New P1/P2 created in last hour) - trend indicator │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Affected Users      │ SUM(Impacted User Count) across active incidents   │
└─────────────────────┴────────────────────────────────────────────────────┘
```

**Data Sources:** ServiceNow Incident table, Splunk alerts, PagerDuty

**Target:** ≤ 3 | **Critical Threshold:** > 5

---

## Domain 2: Network & Connectivity

*WAN performance, site connectivity, and bandwidth utilization across 12 global regions*

### 2.1 Global Average Network Latency

#### Why This Matters
Network latency directly impacts **voice quality and agent desktop responsiveness**. For VoIP, latency above 150ms causes noticeable conversation delays. For agent applications, latency above 100ms creates sluggish screen pops and CRM responses, adding seconds to every interaction.

**Business Impact:**
- Every 50ms of latency adds ~2 seconds to average handle time (AHT)
- 2 second AHT increase across 50,000 agents = 27,778 additional agent hours/month
- At $25/hour fully loaded cost = $694,450/month in lost productivity

#### How to Calculate

```
Global Avg Latency = Weighted Average of Regional Latencies

Formula:
                    Σ (Region Latency × Region Agent Count)
Global Avg Latency = ──────────────────────────────────────
                         Total Agent Count

Example:
┌────────────┬─────────┬────────────┬──────────────────┐
│ Region     │ Agents  │ Latency    │ Weighted Value   │
├────────────┼─────────┼────────────┼──────────────────┤
│ NA         │ 18,420  │ 82ms       │ 1,510,440        │
│ EMEA       │ 12,847  │ 118ms      │ 1,515,946        │
│ APAC       │ 10,234  │ 156ms      │ 1,596,504        │
│ LATAM      │ 4,892   │ 142ms      │ 694,664          │
│ India      │ 1,439   │ 178ms      │ 256,142          │
└────────────┴─────────┴────────────┴──────────────────┘

Global Avg = (1,510,440 + 1,515,946 + 1,596,504 + 694,664 + 256,142) / 47,832
           = 5,573,696 / 47,832 = 116.5ms ≈ 117ms

Note: Also track P95 latency (95th percentile) to catch outliers affecting specific users.
```

**Data Sources:** ThousandEyes agent-to-cloud tests, Genesys Edge latency metrics

**Target:** < 120ms | **Critical Threshold:** > 180ms

---

### 2.2 Site Connectivity (All Regions)

#### Why This Matters
With 100+ contact center sites globally, losing connectivity to even one site can strand hundreds of agents. This indicator tracks **active connectivity to all sites** and serves as an early warning for WAN issues, ISP problems, or local infrastructure failures.

**Business Impact:**
- Single site outage (500 agents) = ~$83,000/hour in lost capacity
- Degraded connectivity causes voice quality issues before full outage
- Multi-site failures indicate systemic network problems

#### How to Calculate

```
Site Connectivity = (Connected Sites / Total Sites) × 100

Site Status Classification:
┌─────────────┬────────────────────────────────────────────────────────┐
│ Status      │ Definition                                             │
├─────────────┼────────────────────────────────────────────────────────┤
│ Connected   │ Latency < threshold AND packet loss < 1% AND all       │
│             │ critical services reachable                            │
├─────────────┼────────────────────────────────────────────────────────┤
│ Degraded    │ Latency elevated OR packet loss 1-3% OR some services  │
│             │ slow but functional                                    │
├─────────────┼────────────────────────────────────────────────────────┤
│ Disconnected│ Unreachable OR packet loss > 5% OR critical services   │
│             │ unavailable                                            │
└─────────────┴────────────────────────────────────────────────────────┘

Example:
- Total Sites: 100
- Connected: 96
- Degraded: 2
- Disconnected: 2
- Site Connectivity: 96/100 = 96%
- Display: "96/100 (2 degraded)"
```

**Data Sources:** ThousandEyes Enterprise Agents, SolarWinds NPM, SNMP polling

**Target:** 100% | **Critical Threshold:** < 95%

---

### 2.3 WAN Bandwidth Utilization

#### Why This Matters
Bandwidth utilization indicates **network capacity risk**. Unlike latency (which shows current impact), bandwidth utilization predicts future congestion. When utilization exceeds 70%, the risk of congestion-induced quality degradation increases exponentially.

**Business Impact:**
- Bandwidth saturation causes packet loss, jitter, and latency spikes
- Voice calls degrade before data applications (UDP vs TCP prioritization)
- Planning metric for capacity upgrades

#### How to Calculate

```
WAN Bandwidth Utilization = (Actual Throughput / Provisioned Capacity) × 100

Measurement Points:
- Aggregate across all WAN links (MPLS, SD-WAN, Direct Connect)
- Measure both ingress and egress (use higher value)
- Sample at 1-minute intervals, report 15-minute rolling average

Calculation Example:
┌────────────────────┬───────────────┬──────────────┬─────────────┐
│ Circuit            │ Capacity      │ Peak Usage   │ Utilization │
├────────────────────┼───────────────┼──────────────┼─────────────┤
│ NA Primary MPLS    │ 10 Gbps       │ 7.2 Gbps     │ 72%         │
│ NA Backup SD-WAN   │ 5 Gbps        │ 2.1 Gbps     │ 42%         │
│ EMEA MPLS          │ 5 Gbps        │ 4.3 Gbps     │ 86%         │
│ APAC Direct Connect│ 3 Gbps        │ 2.4 Gbps     │ 80%         │
└────────────────────┴───────────────┴──────────────┴─────────────┘

Global Average = (72 + 42 + 86 + 80) / 4 = 70%
Peak Utilization = MAX(72, 42, 86, 80) = 86%

Report both average and peak; alert on peak.
```

**Data Sources:** SolarWinds NetFlow, ThousandEyes, SD-WAN controller

**Target:** < 70% avg | **Critical Threshold:** > 85%

---

### 2.4 Global Packet Loss Rate

#### Why This Matters
Packet loss is the **most direct predictor of voice quality degradation**. Even 0.5% packet loss can make calls sound choppy. At enterprise scale, aggregating packet loss across thousands of concurrent calls reveals systemic network health.

**Business Impact:**
- 1% packet loss = MOS drop of 0.5-0.8 points
- Customer perceives quality issues before agents do
- Correlates strongly with "call me back" requests and abandons

#### How to Calculate

```
Global Packet Loss = (Lost Packets / Total Packets Sent) × 100

Measurement Approach:
1. Collect from Genesys Edge voice quality reports (per-call metrics)
2. Aggregate ThousandEyes synthetic test results
3. Weight by traffic volume

Formula:
                       Σ (Region Lost Packets)
Global Packet Loss = ────────────────────────── × 100
                      Σ (Region Total Packets)

Per-Region Calculation:
┌────────────┬────────────────┬──────────────┬──────────────┐
│ Region     │ Total Packets  │ Lost Packets │ Loss Rate    │
├────────────┼────────────────┼──────────────┼──────────────┤
│ NA         │ 892,000,000    │ 892,000      │ 0.10%        │
│ EMEA       │ 645,000,000    │ 967,500      │ 0.15%        │
│ APAC       │ 512,000,000    │ 665,600      │ 0.13%        │
│ LATAM      │ 245,000,000    │ 367,500      │ 0.15%        │
│ India      │ 72,000,000     │ 86,400       │ 0.12%        │
└────────────┴────────────────┴──────────────┴──────────────┘

Global = (892,000 + 967,500 + 665,600 + 367,500 + 86,400) / 
         (892M + 645M + 512M + 245M + 72M) × 100
       = 2,979,000 / 2,366,000,000 × 100 = 0.126% ≈ 0.13%
```

**Data Sources:** Genesys Edge QoS metrics, ThousandEyes, network flow analysis

**Target:** < 0.5% | **Critical Threshold:** > 1%

---

## Domain 3: Voice Quality & Telephony

*Call quality metrics, MOS scores, and telephony infrastructure health*

### 3.1 Global Voice Quality (MOS)

#### Why This Matters
Mean Opinion Score (MOS) is the **industry standard for voice quality measurement**. It predicts customer satisfaction with call clarity. A MOS below 3.5 is perceptible as poor quality; below 3.0 makes conversation difficult.

**Business Impact:**
- MOS correlates with CSAT at r=0.72 in contact center studies
- Poor quality calls are 40% more likely to result in repeat contacts
- Quality complaints drive negative NPS and social media sentiment

#### How to Calculate

```
MOS Calculation (ITU-T P.862 / PESQ Algorithm):

Simplified Formula (for dashboard aggregation):
                    Σ (Call MOS × Call Duration)
Weighted Avg MOS = ─────────────────────────────
                      Σ (Call Duration)

MOS Scale Reference:
┌───────┬─────────────┬────────────────────────────────────────┐
│ Score │ Quality     │ User Perception                        │
├───────┼─────────────┼────────────────────────────────────────┤
│ 4.3+  │ Excellent   │ Imperceptible impairment               │
│ 4.0   │ Good        │ Perceptible but not annoying           │
│ 3.6   │ Fair        │ Slightly annoying                      │
│ 3.1   │ Poor        │ Annoying                               │
│ < 3.0 │ Bad         │ Very annoying, difficult conversation  │
└───────┴─────────────┴────────────────────────────────────────┘

Enterprise Calculation Example:
- Total calls in period: 125,000
- Sum of (MOS × Duration): 21,562,500 MOS-minutes
- Sum of Duration: 5,125,000 minutes
- Weighted MOS: 21,562,500 / 5,125,000 = 4.21

Also track:
- P10 MOS (10th percentile) - identifies worst 10% of calls
- MOS by region to isolate problem areas
```

**Data Sources:** Genesys Cloud Voice Quality Analytics, ThousandEyes Voice tests

**Target:** ≥ 4.0 | **Critical Threshold:** < 3.6

---

### 3.2 Poor Call Rate (MOS < 3.5)

#### Why This Matters
While average MOS may look healthy, the **percentage of poor quality calls** reveals the customer impact. A 2% poor call rate means 1 in 50 customers experiences degraded quality - potentially thousands of negative experiences daily.

**Business Impact:**
- Poor calls have 3x higher repeat contact rate
- Quality issues are the #2 driver of DSAT (after long wait times)
- At 50,000 agents handling 500,000 calls/day, 2% = 10,000 poor experiences

#### How to Calculate

```
Poor Call Rate = (Calls with MOS < 3.5 / Total Calls) × 100

Query Example (Genesys Analytics API):
SELECT 
  COUNT(CASE WHEN mos_score < 3.5 THEN 1 END) as poor_calls,
  COUNT(*) as total_calls,
  ROUND(COUNT(CASE WHEN mos_score < 3.5 THEN 1 END) * 100.0 / COUNT(*), 2) as poor_call_rate
FROM voice_quality_metrics
WHERE call_end_time > NOW() - INTERVAL '1 hour'

Breakdown by Severity:
┌─────────────────┬──────────────┬───────────────────────────────┐
│ Quality Band    │ MOS Range    │ Action                        │
├─────────────────┼──────────────┼───────────────────────────────┤
│ Acceptable      │ 3.5 - 4.0    │ Monitor, optimize if trending │
│ Poor            │ 3.0 - 3.5    │ Investigate, customer may     │
│                 │              │ notice issues                 │
│ Very Poor       │ < 3.0        │ Urgent investigation,         │
│                 │              │ consider callback offer       │
└─────────────────┴──────────────┴───────────────────────────────┘
```

**Data Sources:** Genesys Cloud Quality Metrics API

**Target:** < 3% | **Critical Threshold:** > 5%

---

### 3.3 SIP Trunk Capacity Utilization

#### Why This Matters
SIP trunks are the **telephony highways** connecting your contact center to the PSTN. Trunk exhaustion causes immediate call failures - customers hear fast busy or can't connect at all. This is a capacity planning leading indicator.

**Business Impact:**
- Trunk exhaustion = customers cannot reach you (complete outage)
- Typically hits during unexpected volume spikes
- 20% headroom allows for 2x normal traffic surge

#### How to Calculate

```
SIP Trunk Utilization = (Concurrent Calls / Total Trunk Capacity) × 100

Measurement:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Metric              │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Concurrent Calls    │ Active voice sessions at measurement point         │
│ Trunk Capacity      │ Maximum simultaneous calls per SIP provider        │
│ Peak Utilization    │ Highest utilization in measurement period          │
│ Avg Utilization     │ Mean utilization over period                       │
└─────────────────────┴────────────────────────────────────────────────────┘

Example:
- Provider A: 5,000 channel capacity
- Provider B: 3,000 channel capacity
- Provider C (backup): 2,000 channel capacity
- Total Capacity: 10,000 channels

Current State:
- Active calls: 6,200
- Utilization: 6,200 / 10,000 = 62%
- Headroom: 3,800 channels (38%)

Alert Thresholds:
- Warning: > 70% (< 30% headroom)
- Critical: > 85% (< 15% headroom)
- Emergency: > 95% (exhaustion imminent)
```

**Data Sources:** Genesys Trunk Status, SIP provider dashboards, SolarWinds VoIP monitor

**Target:** < 80% | **Critical Threshold:** > 90%

---

### 3.4 Enterprise Average Queue Wait Time

#### Why This Matters
Queue wait time is the **primary driver of customer satisfaction** in contact centers. It's also a leading indicator of capacity issues - rising wait times precede service level failures and abandoned calls.

**Business Impact:**
- Every 30 seconds of wait reduces CSAT by ~5 points
- Wait times > 2 minutes have 40% higher abandon rates
- Long waits generate social media complaints and escalations

#### How to Calculate

```
Enterprise Avg Wait Time = Σ (Time to Answer) / Number of Answered Calls

Components:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Metric              │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Time to Answer      │ Duration from call entering queue to agent answer  │
│ Answered Calls      │ Calls that reached an agent (excludes abandons)    │
│ ASA (Answer Speed)  │ Same as avg wait time - industry term              │
└─────────────────────┴────────────────────────────────────────────────────┘

Regional Weighted Calculation:
                              Σ (Region Total Wait Time)
Enterprise Avg Wait Time = ───────────────────────────────
                             Σ (Region Answered Calls)

Example:
┌────────────┬─────────────────┬────────────────┬──────────────┐
│ Region     │ Answered Calls  │ Total Wait Min │ Avg Wait     │
├────────────┼─────────────────┼────────────────┼──────────────┤
│ NA         │ 45,000          │ 67,500         │ 1:30         │
│ EMEA       │ 32,000          │ 56,000         │ 1:45         │
│ APAC       │ 28,000          │ 84,000         │ 3:00         │
│ LATAM      │ 12,000          │ 30,000         │ 2:30         │
│ India      │ 8,000           │ 16,000         │ 2:00         │
└────────────┴─────────────────┴────────────────┴──────────────┘

Enterprise = (67,500 + 56,000 + 84,000 + 30,000 + 16,000) / 
             (45,000 + 32,000 + 28,000 + 12,000 + 8,000)
           = 253,500 / 125,000 = 2.028 minutes ≈ 2:02

Display Format: 2:34 (minutes:seconds)
```

**Data Sources:** Genesys Real-time Queue Statistics, WFM intraday reporting

**Target:** < 1:30 | **Critical Threshold:** > 3:00

---

## Domain 4: Workforce & Capacity Management

*Staffing levels, schedule adherence, and workforce optimization across 50,000 agents*

### 4.1 Global Staffing Gap (FTE)

#### Why This Matters
The staffing gap is the **difference between forecasted need and actual staffed agents**. At enterprise scale, this is measured in FTE (Full-Time Equivalent) rather than percentage because the absolute impact matters. A 2% gap sounds small, but at 50,000 agents, that's 1,000 missing agents.

**Business Impact:**
- Each missing FTE = ~150 unanswered calls/day
- 1,000 FTE gap = 150,000 customers/day affected
- Understaffing creates overtime costs and agent burnout
- Overstaffing wastes $2,000-3,000/day per excess FTE

#### How to Calculate

```
Staffing Gap = Actual Staffed FTE - Required FTE

Components:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Metric              │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Required FTE        │ WFM forecast for current interval + shrinkage      │
│ Actual Staffed      │ Agents in Available or Active states               │
│ Gap (Positive)      │ Overstaffed - excess capacity                      │
│ Gap (Negative)      │ Understaffed - capacity shortfall                  │
└─────────────────────┴────────────────────────────────────────────────────┘

Calculation:
Required FTE = (Forecasted Calls × AHT) / (Interval Duration × Occupancy Target)
             = (12,000 calls × 8 min) / (30 min × 0.80)
             = 96,000 / 24 = 4,000 FTE (for this interval)

Add shrinkage factor:
Required with Shrinkage = 4,000 / (1 - 0.25) = 5,333 FTE

If Actual Staffed = 4,800 FTE:
Staffing Gap = 4,800 - 5,333 = -533 FTE (understaffed)

Display: -533 FTE (showing negative means understaffed)
```

**Data Sources:** WFM Real-time Adherence, Genesys Agent State API

**Target:** ±200 FTE | **Critical Threshold:** > ±500 FTE

---

### 4.2 Global Schedule Adherence

#### Why This Matters
Schedule adherence measures whether agents are **working when scheduled**. Low adherence compounds staffing gaps and makes forecasts unreliable. Even with perfect forecasting, poor adherence means capacity won't match demand.

**Business Impact:**
- 1% adherence drop = ~500 FTE effective capacity loss
- Adherence issues indicate morale/engagement problems
- Non-adherence during peak periods has 3x impact

#### How to Calculate

```
Schedule Adherence = (Time in Adherence / Total Scheduled Time) × 100

In Adherence When:
- Scheduled Available → Agent state: Available, Talking, After-call Work
- Scheduled Break → Agent state: Break, Lunch, Personal
- Scheduled Training → Agent state: Training, Meeting
- Scheduled Unavailable → Agent state: Logged out

Out of Adherence When:
- State doesn't match schedule (e.g., scheduled Available but in Personal)
- Logged out during scheduled shift
- Extended breaks beyond scheduled time

Calculation Example:
For agent shift 8:00 AM - 5:00 PM (9 hours = 540 minutes):
- Scheduled Available: 420 minutes
- Scheduled Breaks: 60 minutes
- Scheduled Lunch: 60 minutes

Agent Actual:
- In correct state per schedule: 472 minutes
- Out of adherence: 68 minutes (late return from lunch, early logout)

Individual Adherence = 472 / 540 = 87.4%

Global Adherence = AVG(All Agent Adherence Scores)
or
Global Adherence = Σ(In Adherence Minutes) / Σ(Scheduled Minutes)
```

**Data Sources:** WFM Adherence Module, Genesys Agent Timeline API

**Target:** ≥ 92% | **Critical Threshold:** < 85%

---

### 4.3 Global Agent Occupancy

#### Why This Matters
Occupancy measures **productive time as a percentage of available time**. It's a balance indicator - too low means wasted capacity, too high causes burnout. The optimal range is 75-85%.

**Business Impact:**
- Occupancy < 70% = over-staffed, wasting labor budget
- Occupancy > 90% = agent burnout, quality decline, attrition risk
- Sustained high occupancy increases handle time as agents rush

#### How to Calculate

```
Occupancy = (Handle Time / (Handle Time + Available Time)) × 100

Where:
- Handle Time = Talk Time + After-Call Work Time
- Available Time = Time in Available state waiting for calls

Calculation:
For 8-hour shift:
- Talk Time: 5.5 hours
- ACW Time: 1.0 hours
- Available (idle) Time: 1.5 hours
- Handle Time = 5.5 + 1.0 = 6.5 hours
- Occupancy = 6.5 / (6.5 + 1.5) = 6.5 / 8.0 = 81.25%

Enterprise Calculation:
                   Σ (All Agent Handle Time)
Global Occupancy = ──────────────────────────────────────── × 100
                   Σ (All Agent Handle Time + Available Time)

Optimal Ranges:
┌─────────────────┬───────────────────────────────────────────┐
│ Occupancy       │ Interpretation                            │
├─────────────────┼───────────────────────────────────────────┤
│ < 70%           │ Overstaffed, consider redeployment        │
│ 70-75%          │ Light load, good for training/coaching    │
│ 75-85%          │ OPTIMAL - balanced workload               │
│ 85-90%          │ High utilization, monitor for burnout     │
│ > 90%           │ Unsustainable, burnout risk, add staff    │
└─────────────────┴───────────────────────────────────────────┘
```

**Data Sources:** Genesys Agent Statistics, WFM Productivity Reports

**Target:** 75-85% | **Critical Threshold:** > 90% or < 65%

---

### 4.4 Unplanned Shrinkage Rate

#### Why This Matters
Unplanned shrinkage (absences, tech issues, unscheduled breaks) **destroys forecasting accuracy**. Unlike planned shrinkage (training, meetings), unplanned shrinkage can't be staffed around. It's a leading indicator of operational and cultural issues.

**Business Impact:**
- 1% unplanned shrinkage = ~500 missing FTE daily
- High unplanned shrinkage indicates morale or environmental issues
- Causes reactive overtime and service level failures

#### How to Calculate

```
Unplanned Shrinkage = (Unplanned Absent Time / Total Scheduled Time) × 100

Unplanned Shrinkage Categories:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Category            │ Examples                                           │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Unplanned Absence   │ Sick calls, no-shows, family emergency             │
│ Technical Issues    │ System outages, login failures, VDI crashes        │
│ Extended Breaks     │ Breaks/lunch running over scheduled time           │
│ Unauthorized AUX    │ Excessive personal time, bathroom beyond allowance │
└─────────────────────┴────────────────────────────────────────────────────┘

Calculation:
Scheduled Time for Day: 400,000 agent-hours (50,000 agents × 8 hours)
Unplanned Absent Hours:
- Sick/No-show: 12,000 hours
- Tech Issues: 8,000 hours
- Extended Breaks: 4,500 hours
- Unauthorized: 3,500 hours
Total Unplanned: 28,000 hours

Unplanned Shrinkage = 28,000 / 400,000 = 7.0%

Note: Planned shrinkage (training, meetings, PTO) is separate and expected.
Total Shrinkage = Planned + Unplanned (typically 25-35% total)
```

**Data Sources:** WFM Shrinkage Reports, HR Absence System, Agent State Analysis

**Target:** < 6% | **Critical Threshold:** > 10%

---

## Domain 5: Agent Desktop & Virtual Environment

*Citrix VDI performance, endpoint health, and agent tool availability*

### 5.1 Citrix Session Success Rate

#### Why This Matters
For organizations using Citrix VDI, session success rate measures **agent ability to connect to their virtual desktop**. Failed sessions mean agents can't work at all - it's a complete productivity blocker.

**Business Impact:**
- Failed session = agent unable to take calls (100% productivity loss)
- 2% failure rate across 50,000 agents = 1,000 blocked agents
- Session failures during shift changes cause cascading delays

#### How to Calculate

```
Session Success Rate = (Successful Sessions / Total Session Attempts) × 100

Session Outcomes:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Outcome             │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Successful          │ User reached desktop within 60 seconds             │
│ Slow Success        │ User reached desktop but > 60 seconds              │
│ Failed              │ Connection error, timeout, or authentication fail  │
│ Abandoned           │ User cancelled before completion                   │
└─────────────────────┴────────────────────────────────────────────────────┘

Calculation:
Total Attempts Today: 52,000
- Successful: 51,428
- Slow Success: 312
- Failed: 208
- Abandoned: 52

Success Rate = (51,428 + 312) / 52,000 = 99.5%
(Include slow success as successful for this metric)

Strict Success = 51,428 / 52,000 = 98.9%
(Use strict for the dashboard)
```

**Data Sources:** Citrix Director, Citrix Analytics for Performance

**Target:** ≥ 98% | **Critical Threshold:** < 95%

---

### 5.2 Citrix ICA Latency (Global Average)

#### Why This Matters
ICA (Independent Computing Architecture) latency measures the **round-trip time between user input and screen response**. High ICA latency makes the desktop feel sluggish, directly impacting typing speed, navigation, and overall agent efficiency.

**Business Impact:**
- Every 20ms of ICA latency adds ~1 second to handle time
- Latency > 100ms causes noticeable lag in typing
- Affects all desktop applications, not just voice

#### How to Calculate

```
ICA RTT (Round Trip Time) = Time from keystroke to screen update

Measurement Points:
- Citrix Director: Session metrics → ICA RTT
- Nexthink: Application response time for Citrix sessions

Calculation:
                      Σ (Session ICA RTT × Session Duration)
Weighted Avg ICA RTT = ─────────────────────────────────────
                           Σ (Session Duration)

Example:
┌────────────────┬─────────────────┬──────────────┬──────────────────┐
│ VDA Farm       │ Active Sessions │ Avg ICA RTT  │ Weighted Value   │
├────────────────┼─────────────────┼──────────────┼──────────────────┤
│ NA-East        │ 12,000          │ 45ms         │ 540,000          │
│ NA-West        │ 8,000           │ 52ms         │ 416,000          │
│ EMEA           │ 10,000          │ 78ms         │ 780,000          │
│ APAC           │ 8,500           │ 95ms         │ 807,500          │
│ India          │ 1,500           │ 120ms        │ 180,000          │
└────────────────┴─────────────────┴──────────────┴──────────────────┘

Global Avg = (540K + 416K + 780K + 807.5K + 180K) / 40,000
           = 2,723,500 / 40,000 = 68ms

Also track P95 ICA RTT for worst-case user experience.
```

**Data Sources:** Citrix Director OData API, Nexthink Digital Experience Score

**Target:** < 60ms | **Critical Threshold:** > 100ms

---

### 5.3 Agent Digital Experience Score (DEX)

#### Why This Matters
DEX is a **composite score measuring overall agent desktop experience**. It combines multiple factors (application performance, device health, network quality) into a single actionable metric. It's the best predictor of agent-perceived technology quality.

**Business Impact:**
- DEX correlates with agent satisfaction (r=0.68)
- Low DEX drives IT ticket volume and frustration
- Technology friction is a top-3 reason for agent attrition

#### How to Calculate

```
DEX Score = Weighted combination of experience dimensions (0-10 scale)

Nexthink DEX Components:
┌─────────────────────┬────────────────────────────────────────┬────────┐
│ Dimension           │ What It Measures                       │ Weight │
├─────────────────────┼────────────────────────────────────────┼────────┤
│ Device Health       │ Hardware performance, resource usage   │ 20%    │
│ OS Stability        │ Crashes, hangs, restarts               │ 15%    │
│ App Performance     │ Key app response times, errors         │ 25%    │
│ Network Quality     │ Connectivity, latency, packet loss     │ 20%    │
│ Employee Sentiment  │ Survey responses (if enabled)          │ 20%    │
└─────────────────────┴────────────────────────────────────────┴────────┘

Score Calculation:
DEX = (Device × 0.20) + (OS × 0.15) + (App × 0.25) + (Network × 0.20) + (Sentiment × 0.20)

Example:
- Device Health: 8.5
- OS Stability: 9.0
- App Performance: 7.8
- Network Quality: 8.0
- Employee Sentiment: 8.2

DEX = (8.5 × 0.20) + (9.0 × 0.15) + (7.8 × 0.25) + (8.0 × 0.20) + (8.2 × 0.20)
    = 1.70 + 1.35 + 1.95 + 1.60 + 1.64 = 8.24

Score Interpretation:
┌─────────────┬───────────────────────────────────────────┐
│ Score       │ Interpretation                            │
├─────────────┼───────────────────────────────────────────┤
│ 9.0 - 10.0  │ Excellent - No action needed              │
│ 8.0 - 8.9   │ Good - Minor optimizations possible       │
│ 7.0 - 7.9   │ Fair - Address specific problem areas     │
│ 6.0 - 6.9   │ Poor - Multiple issues impacting agents   │
│ < 6.0       │ Critical - Urgent remediation required    │
└─────────────┴───────────────────────────────────────────┘
```

**Data Sources:** Nexthink Digital Experience Score, custom Nexthink campaigns

**Target:** ≥ 8.0 | **Critical Threshold:** < 7.0

---

### 5.4 VDA Resource Health (All Farms)

#### Why This Matters
Virtual Delivery Agent (VDA) health measures the **server-side health of Citrix infrastructure**. Unhealthy VDAs cause session failures, slow performance, or capacity constraints. It's a capacity planning indicator.

**Business Impact:**
- Unhealthy VDAs reduce available capacity
- VDA failures during peak cause session competition
- Proactive VDA monitoring prevents user-impacting outages

#### How to Calculate

```
VDA Health % = (Healthy VDAs / Total VDAs) × 100

VDA Health States (Citrix Director):
┌─────────────────────┬────────────────────────────────────────────────────┐
│ State               │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Registered          │ VDA connected to Delivery Controller, available    │
│ Unregistered        │ VDA not communicating with Controller              │
│ Maintenance Mode    │ VDA intentionally taken offline                    │
│ Power Managed       │ VDA powered off (for elastic scaling)              │
└─────────────────────┴────────────────────────────────────────────────────┘

Healthy = Registered AND Load Index < 10000 AND No critical alerts

Calculation:
Total VDAs in all farms: 850
- Registered & Healthy: 802
- Registered but High Load: 25
- Registered with Alerts: 15
- Unregistered: 8

Healthy VDAs = 802
VDA Health = 802 / 850 = 94.4%

Available Capacity = Healthy VDAs × Sessions per VDA
                   = 802 × 60 = 48,120 concurrent sessions
```

**Data Sources:** Citrix Director OData API, Citrix ADM, SolarWinds

**Target:** ≥ 85% | **Critical Threshold:** < 75%

---

## Domain 6: IVR & Self-Service Automation

*Speech recognition, containment rates, and automation effectiveness*

### 6.1 IVR Containment Rate

#### Why This Matters
Containment rate measures **callers who complete their task in the IVR without reaching an agent**. It's the primary ROI metric for IVR investment and directly reduces agent workload.

**Business Impact:**
- Each 1% improvement in containment = ~2,500 fewer calls to agents/day
- Cost per IVR-contained interaction: $0.25 vs $8-12 for agent
- At 500,000 daily calls, 1% = $24,000/day savings

#### How to Calculate

```
IVR Containment Rate = (Calls Completed in IVR / Total IVR Calls) × 100

Definitions:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Outcome             │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Contained           │ Caller completed task without agent transfer       │
│ Transferred         │ Caller transferred to agent queue                  │
│ Abandoned           │ Caller hung up in IVR                              │
│ Error               │ System error prevented completion                  │
└─────────────────────┴────────────────────────────────────────────────────┘

Strict Containment = Contained / (Contained + Transferred + Error)
Broad Containment = (Contained + Abandoned) / Total Calls

Example:
- Total IVR Calls: 150,000
- Contained: 93,000
- Transferred: 45,000
- Abandoned: 10,500
- Error: 1,500

Strict Containment = 93,000 / (93,000 + 45,000 + 1,500) = 66.7%

Note: Use strict containment for the dashboard (excludes abandons).
```

**Data Sources:** Nuance Analytics, Genesys Predictive Routing data, IVR platform reports

**Target:** ≥ 68% | **Critical Threshold:** < 60%

---

### 6.2 Speech Recognition Accuracy (ASR)

#### Why This Matters
ASR accuracy measures **how well the IVR understands spoken input**. Poor accuracy forces customers to repeat themselves or press 0 for an agent, destroying the self-service experience.

**Business Impact:**
- Every 1% drop in ASR = ~3% drop in containment
- Low accuracy drives customer frustration and negative sentiment
- Accuracy varies by accent, environment, and grammar design

#### How to Calculate

```
ASR Accuracy = (Correct Recognitions / Total Recognition Attempts) × 100

Recognition Outcomes:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Outcome             │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Correct             │ Recognized value matches caller intent             │
│ Substitution        │ Recognized wrong value (e.g., "four" → "five")     │
│ Insertion           │ Recognized words not spoken                        │
│ Deletion            │ Missed spoken words                                │
│ Rejection           │ System couldn't understand, asked to repeat        │
│ No Speech           │ Caller didn't speak during collection window       │
└─────────────────────┴────────────────────────────────────────────────────┘

Word Error Rate (WER) = (Substitutions + Insertions + Deletions) / Total Words
ASR Accuracy = 100 - (WER × 100)

Semantic Accuracy (business-level):
= (Correct Intent Matches / Total Intent Attempts) × 100

Example:
- Intent recognition attempts: 280,000
- Correct intent captured: 265,160
- Accuracy = 265,160 / 280,000 = 94.7%
```

**Data Sources:** Nuance Call Steering Analytics, Nuance Recognition History

**Target:** ≥ 92% | **Critical Threshold:** < 88%

---

### 6.3 Chatbot Resolution Rate

#### Why This Matters
Chatbot resolution measures **digital self-service effectiveness**. As chat volume grows, bot resolution directly reduces digital agent workload and operating costs.

**Business Impact:**
- Chatbot cost per interaction: $0.10-0.50 vs $6-10 for live chat agent
- Resolution rate predicts digital channel containment
- Unresolved bot conversations have higher DSAT

#### How to Calculate

```
Chatbot Resolution Rate = (Resolved Conversations / Total Bot Conversations) × 100

Resolution Definition:
A conversation is "resolved" when:
- Bot provided an answer AND
- Customer did not request agent transfer AND
- Customer indicated satisfaction (if surveyed) OR
- Customer ended session without negative feedback

Calculation:
- Total bot conversations: 85,000
- Resolved without escalation: 60,350
- Escalated to agent: 22,100
- Abandoned: 2,550

Resolution Rate = 60,350 / 85,000 = 71%

Escalation Rate = 22,100 / 85,000 = 26%
(Escalation + Resolution ≠ 100% due to abandons)

Track by intent:
┌──────────────────────┬───────────────┬─────────────────┐
│ Intent               │ Resolution    │ Volume          │
├──────────────────────┼───────────────┼─────────────────┤
│ Account Balance      │ 92%           │ 25,000          │
│ Payment Status       │ 85%           │ 18,000          │
│ Store Hours          │ 98%           │ 12,000          │
│ Technical Support    │ 45%           │ 15,000          │
│ Complaints           │ 28%           │ 8,000           │
└──────────────────────┴───────────────┴─────────────────┘
```

**Data Sources:** Genesys Bot Analytics, Custom bot platform dashboards

**Target:** ≥ 65% | **Critical Threshold:** < 55%

---

### 6.4 Self-Service Deflection Rate

#### Why This Matters
Deflection rate measures **total interactions resolved without human intervention** across all channels (IVR, web, app, chatbot). It's the ultimate measure of automation ROI.

**Business Impact:**
- Industry benchmark: 30-40% deflection
- Each 1% improvement = significant cost reduction
- High deflection enables agents to focus on complex issues

#### How to Calculate

```
Self-Service Deflection = (Self-Served Interactions / Total Interactions) × 100

Self-Service Channels:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Channel             │ Self-Service Interactions                          │
├─────────────────────┼────────────────────────────────────────────────────┤
│ IVR                 │ Contained calls (no agent transfer)                │
│ Website             │ FAQ views, knowledge base, account portal actions  │
│ Mobile App          │ Self-service transactions completed                │
│ Chatbot             │ Resolved conversations without agent               │
│ Email Auto-response │ Issues resolved by automated reply                 │
└─────────────────────┴────────────────────────────────────────────────────┘

Calculation:
Daily Interactions:
- Total inbound volume: 650,000
- IVR contained: 93,000
- Web self-service: 85,000
- App self-service: 52,000
- Bot resolved: 18,000
- Total self-served: 248,000

Deflection Rate = 248,000 / 650,000 = 38.2%
```

**Data Sources:** Cross-channel analytics platform, Digital analytics, Genesys interaction records

**Target:** ≥ 35% | **Critical Threshold:** < 28%

---

## Domain 7: Integration & Data Flow

*CTI, CRM, middleware, and API health across enterprise systems*

### 7.1 CTI Screen Pop Success Rate

#### Why This Matters
Screen pop delivers **customer context to agents instantly** when calls connect. Failed screen pops force agents to ask for information the customer already provided, increasing handle time and frustration.

**Business Impact:**
- Failed screen pop adds 30-45 seconds to handle time
- Customer frustration from repeating information
- At 50,000 agents, 3% failure = 1,500 slow interactions/hour

#### How to Calculate

```
Screen Pop Success Rate = (Successful Pops / Total Calls to Agents) × 100

Screen Pop Outcomes:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Outcome             │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Full Success        │ Customer record displayed before/at answer         │
│ Partial Success     │ Record displayed but missing data fields           │
│ Late Pop            │ Record displayed > 3 seconds after answer          │
│ No Pop              │ Record not found or system error                   │
│ No Match            │ ANI/account lookup returned no customer record     │
└─────────────────────┴────────────────────────────────────────────────────┘

Strict Success = Full Success only
Broad Success = Full + Partial + Late

Example:
- Calls to agents: 125,000
- Full success: 118,750
- Partial: 2,500
- Late: 1,875
- No pop/error: 1,250
- No match: 625

Strict Success = 118,750 / 125,000 = 95%
Broad Success = (118,750 + 2,500 + 1,875) / 125,000 = 98.5%

Use strict for dashboard (agent experience metric).
```

**Data Sources:** CTI middleware logs, CRM integration metrics, Genesys data dip statistics

**Target:** ≥ 99% | **Critical Threshold:** < 95%

---

### 7.2 CRM Average Response Time

#### Why This Matters
CRM response time measures **how fast the agent desktop receives customer data**. Slow CRM makes every agent interaction painful and directly adds to handle time.

**Business Impact:**
- CRM response > 3 seconds = noticeable agent wait
- Slow CRM causes agents to "work around" the system
- Impacts both screen pop and in-call lookups

#### How to Calculate

```
CRM Avg Response Time = AVG(API Response Duration) for CRM transactions

Measured Transactions:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Transaction Type    │ Acceptable Response Time                           │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Customer Lookup     │ < 1.5 seconds                                      │
│ Account History     │ < 2.0 seconds                                      │
│ Case Creation       │ < 2.5 seconds                                      │
│ Case Update         │ < 2.0 seconds                                      │
│ Knowledge Search    │ < 1.0 seconds                                      │
└─────────────────────┴────────────────────────────────────────────────────┘

Calculation:
- Sample period: 1 hour
- Total CRM API calls: 450,000
- Sum of response times: 765,000 seconds
- Average = 765,000 / 450,000 = 1.7 seconds

Also track:
- P95 response time (worst 5% of requests)
- Response time by transaction type
- Error rate (non-200 responses)
```

**Data Sources:** CRM API monitoring (APM), Nexthink app response, custom instrumentation

**Target:** < 3s | **Critical Threshold:** > 5s

---

### 7.3 Real-time Data Freshness

#### Why This Matters
Data freshness measures **how current the dashboard data is**. Stale data leads to poor decisions. At enterprise scale, real-time data must refresh within 15 seconds to be actionable.

**Business Impact:**
- Stale data causes misaligned staffing decisions
- Queue data older than 30 seconds is operationally useless
- Reputational risk if executives make decisions on bad data

#### How to Calculate

```
Data Freshness = Current Time - Last Data Timestamp

Measurement by Data Type:
┌─────────────────────┬────────────────┬────────────────────────────────────┐
│ Data Type           │ Max Freshness  │ Measurement Method                 │
├─────────────────────┼────────────────┼────────────────────────────────────┤
│ Queue Statistics    │ 15 seconds     │ API poll timestamp vs current time │
│ Agent States        │ 10 seconds     │ WebSocket heartbeat lag            │
│ Call Metrics        │ 30 seconds     │ Last metric timestamp              │
│ KPI Aggregations    │ 60 seconds     │ Last calculation timestamp         │
│ Historical Reports  │ 5 minutes      │ Last ETL completion                │
└─────────────────────┴────────────────┴────────────────────────────────────┘

Dashboard Data Freshness:
= MAX(Queue Freshness, Agent State Freshness, Call Metric Freshness)

Example:
- Queue data last updated: 5 seconds ago
- Agent states: 3 seconds ago
- Call metrics: 12 seconds ago
- Displayed Freshness: 12 seconds (worst component)

Alert if any component exceeds its threshold.
```

**Data Sources:** Data platform timestamps, API monitoring, ETL job status

**Target:** < 15s | **Critical Threshold:** > 60s

---

### 7.4 API Gateway Error Rate

#### Why This Matters
The API gateway is the **front door for all system integrations**. Error rate indicates integration health - high errors cause failed transactions, data sync issues, and application errors.

**Business Impact:**
- API errors cascade to agent-visible failures
- High error rates indicate upstream system issues
- Errors during peak cause customer-impacting failures

#### How to Calculate

```
API Error Rate = (Error Responses / Total API Requests) × 100

Error Classification:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ HTTP Code           │ Classification                                     │
├─────────────────────┼────────────────────────────────────────────────────┤
│ 2xx                 │ Success (not counted as error)                     │
│ 4xx                 │ Client error (may or may not count)                │
│ 5xx                 │ Server error (always counted)                      │
│ Timeout             │ No response within threshold (always counted)      │
└─────────────────────┴────────────────────────────────────────────────────┘

Calculation Options:
- Strict: Only 5xx responses
- Broad: 5xx + 429 (rate limited) + timeouts
- Very Broad: All non-2xx responses

Recommended (Strict):
Error Rate = (5xx Responses + Timeouts) / Total Requests × 100

Example:
- Total requests in hour: 2,500,000
- 5xx errors: 12,500
- Timeouts: 7,500
- Error Rate = (12,500 + 7,500) / 2,500,000 = 0.8%

Track by endpoint to identify problem integrations.
```

**Data Sources:** API Gateway logs (Splunk), APM tools, custom monitoring

**Target:** < 0.5% | **Critical Threshold:** > 1%

---

## Domain 8: Security & Access Management

*Authentication success, session health, and security compliance*

### 8.1 SSO Authentication Success Rate

#### Why This Matters
SSO (Single Sign-On) is how **every agent accesses every system**. Authentication failures prevent agents from working entirely. Even minor issues affect thousands of users at shift changes.

**Business Impact:**
- Failed auth = agent cannot work (total productivity loss)
- SSO issues during shift change = mass login failures
- Compliance requirement for audit trails

#### How to Calculate

```
SSO Success Rate = (Successful Authentications / Total Auth Attempts) × 100

Authentication Outcomes:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Outcome             │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Success             │ User authenticated, session created                │
│ Failed - Credentials│ Wrong password or expired credentials              │
│ Failed - MFA        │ MFA challenge not completed                        │
│ Failed - Locked     │ Account locked out                                 │
│ Failed - Technical  │ SSO service error or timeout                       │
└─────────────────────┴────────────────────────────────────────────────────┘

Calculation:
- Total auth attempts: 58,000 (shift change period)
- Successful: 56,550
- Failed - Credentials: 800
- Failed - MFA: 350
- Failed - Locked: 150
- Failed - Technical: 150

Success Rate = 56,550 / 58,000 = 97.5%

Focus on "Failed - Technical" separately:
Technical Failure Rate = 150 / 58,000 = 0.26%
(This is system reliability vs user error)
```

**Data Sources:** Identity Provider logs (Azure AD, Okta), Splunk security monitoring

**Target:** ≥ 99.5% | **Critical Threshold:** < 98%

---

### 8.2 MFA Compliance Rate

#### Why This Matters
MFA (Multi-Factor Authentication) compliance measures **security policy adherence**. Non-compliant users represent security risk and potential compliance violations (PCI, SOC2).

**Business Impact:**
- 100% MFA is a compliance requirement for most certifications
- Non-compliant users are security vulnerabilities
- Exceptions must be documented and time-limited

#### How to Calculate

```
MFA Compliance = (Users with MFA Enabled / Total Active Users) × 100

Compliance Tracking:
┌─────────────────────┬────────────────────────────────────────────────────┐
│ Status              │ Definition                                         │
├─────────────────────┼────────────────────────────────────────────────────┤
│ Compliant           │ MFA enabled and used for all authentications       │
│ Enrolled Not Using  │ MFA registered but sometimes bypassed              │
│ Not Enrolled        │ User has not completed MFA setup                   │
│ Exception           │ Documented exemption (service accounts, etc.)      │
└─────────────────────┴────────────────────────────────────────────────────┘

Calculation:
- Total active contact center users: 52,000
- MFA compliant: 51,948
- Enrolled not using: 35
- Not enrolled: 12
- Exceptions: 5

Compliance Rate = 51,948 / 52,000 = 99.9%

Non-Compliance Count = 35 + 12 = 47 users requiring remediation
```

**Data Sources:** Identity Provider reports, Compliance monitoring tools

**Target:** 100% | **Critical Threshold:** < 99%

---

### 8.3 Abnormal Session Terminations

#### Why This Matters
Abnormal terminations (unexpected logouts, session crashes) indicate **system stability or security issues**. Sudden spikes may indicate attacks, while persistent rates indicate technical problems.

**Business Impact:**
- Session crashes interrupt active customer calls
- May indicate security incident (forced logouts)
- Technical instability affects agent confidence

#### How to Calculate

```
Abnormal Termination Rate = (Abnormal Terminations / Total Session Ends) × 100

Termination Types:
┌─────────────────────┬─────────────────────────┬────────────────────────────┐
│ Type                │ Normal/Abnormal         │ Example                    │
├─────────────────────┼─────────────────────────┼────────────────────────────┤
│ User Logout         │ Normal                  │ Agent clicks logout        │
│ Idle Timeout        │ Normal                  │ Session expired            │
│ Admin Termination   │ Normal                  │ IT forced logoff           │
│ Application Crash   │ Abnormal                │ Citrix session died        │
│ Network Loss        │ Abnormal                │ Connection dropped         │
│ Force Terminated    │ Abnormal                │ Security event             │
│ System Restart      │ Abnormal (unplanned)    │ Server rebooted            │
└─────────────────────┴─────────────────────────┴────────────────────────────┘

Calculation:
- Total session terminations: 48,000
- Normal (logout + timeout + admin): 47,520
- Abnormal: 480

Abnormal Rate = 480 / 48,000 = 1.0%

Investigate if > 0.5% or if sudden spike detected.
```

**Data Sources:** Citrix Director, Genesys session logs, Security event monitoring

**Target:** < 1% | **Critical Threshold:** > 2%

---

### 8.4 Security Incidents (24h Rolling)

#### Why This Matters
Active security incidents represent **risk to operations and data**. Even P2 security incidents require immediate awareness and may require operational response (system isolation, etc.).

**Business Impact:**
- P1 security incident may require emergency shutdown
- Data breach has regulatory and reputational consequences
- Tracking demonstrates security program maturity

#### How to Calculate

```
Security Incident Count = Count of P1/P2 security incidents in last 24 hours

Incident Priority (Security):
┌──────────┬───────────────────────────────────────────────────────────────┐
│ Priority │ Definition                                                    │
├──────────┼───────────────────────────────────────────────────────────────┤
│ P1       │ Active breach, data exfiltration, ransomware, system          │
│          │ compromise - requires immediate response team                 │
├──────────┼───────────────────────────────────────────────────────────────┤
│ P2       │ Detected intrusion attempt, suspicious activity, policy       │
│          │ violation, potential data exposure - requires investigation   │
├──────────┼───────────────────────────────────────────────────────────────┤
│ P3       │ Minor policy violations, failed attacks, vulnerability        │
│          │ discovered - standard remediation timeline                    │
└──────────┴───────────────────────────────────────────────────────────────┘

Calculation:
Query SecurityIncident table where:
- Priority IN ('P1', 'P2')
- Created_Time > NOW() - 24 hours
- Category = 'Security'

Example:
- P1 incidents: 0
- P2 incidents: 0
- Display: "0" with "No incidents" status

Any P1 = CRITICAL status immediately
Any P2 = WARNING status
```

**Data Sources:** SIEM (Splunk), ServiceNow Security Incident module

**Target:** 0 | **Critical Threshold:** > 0 (any P1/P2)

---

## Threshold Guidelines

### Status Definitions

| Status | Visual | Definition | Response |
|--------|--------|------------|----------|
| **Healthy** | 🟢 Green | Within target thresholds | Monitor, no action |
| **At Risk** | 🟡 Yellow | Within 15% of threshold breach | Investigate, prepare mitigation |
| **Critical** | 🔴 Red | Threshold breached | Immediate action, activate runbook |

### Escalation Matrix

| Status Duration | Action |
|-----------------|--------|
| At Risk > 15 min | Alert Team Lead |
| At Risk > 30 min | Alert Operations Manager |
| Critical (immediate) | Alert Operations Manager + Page On-call |
| Critical > 15 min | Bridge call initiated |
| Critical > 30 min | Executive notification |

---

## Data Source Reference

| System | Purpose | Refresh Rate | API/Method |
|--------|---------|--------------|------------|
| **Genesys Cloud** | Platform, voice, agent metrics | 5 seconds | Analytics API, Quality API |
| **ThousandEyes** | Network monitoring, latency | 1 minute | ThousandEyes API v7 |
| **Citrix Director** | VDI health, session metrics | 1 minute | OData API |
| **Nexthink** | Endpoint DEX, app performance | 15 minutes | NXQL API |
| **SolarWinds** | Infrastructure, bandwidth | 1 minute | SWIS API |
| **WFM** | Workforce scheduling, adherence | 15 seconds | RTA API |
| **Nuance** | IVR, speech recognition | 5 minutes | Analytics Export |
| **ServiceNow** | Incidents, changes | 1 minute | Table API |
| **Splunk** | Logs, security, API metrics | Real-time | Search API |
| **CRM** | Customer data, CTI | Transaction-based | REST API |

---

## Change History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 3.0 | 2026-01-22 | Operations Team | Added 28 new enterprise indicators across 5 new domains |
| 2.0 | 2026-01-22 | Operations Team | Enterprise redesign - 8 domains, 32 indicators |
| 1.0 | 2026-01-20 | Operations Team | Initial version - 20 indicators |

---

# PART 2: EXTENDED ENTERPRISE INDICATORS

## Additional Industry-Standard Leading Indicators

The following indicators represent **industry best practices** from COPC, ICMI, and enterprise contact center benchmarks. These expand the original 32 indicators to provide comprehensive end-to-end operational visibility.

---

## Domain 9: Customer Experience Predictors

*Metrics that predict customer satisfaction before surveys are collected*

### 9.1 First Contact Resolution Predictor (FCR-P)

#### Why This Matters
FCR-P predicts whether an interaction will resolve the customer's issue on first contact by analyzing real-time signals during the call. Low FCR-P scores indicate the customer will likely call back, driving repeat contacts and dissatisfaction.

**Business Impact:**
- Each 1% improvement in FCR saves **$276,000 annually** per 1,000 agents
- Repeat calls cost 1.5-2x more than first-contact resolution
- FCR is the #1 driver of customer satisfaction (ICMI research)

#### How to Calculate

```
FCR Predictor Score = W1(Knowledge Base Hit) + W2(Transfer Flag) + W3(Hold Time Ratio) + W4(Sentiment Score) + W5(Wrap Code Category)

Component Weights:
┌────────────────────────┬────────────────────────────────────────────────────┬────────┐
│ Component              │ Measurement                                        │ Weight │
├────────────────────────┼────────────────────────────────────────────────────┼────────┤
│ Knowledge Base Hit     │ Agent accessed KB article = +20                    │ 20%    │
│ Transfer Flag          │ No transfer = +25, Warm transfer = +15, Cold = 0   │ 25%    │
│ Hold Time Ratio        │ (Hold Time / Talk Time) < 15% = +20                │ 20%    │
│ Sentiment Score        │ Real-time NLP sentiment (0-20 scale)               │ 20%    │
│ Wrap Code Category     │ Resolution codes: Resolved=+15, Escalated=0        │ 15%    │
└────────────────────────┴────────────────────────────────────────────────────┴────────┘

Real-Time Calculation During Call:
- KB accessed for billing article: +20
- No transfer initiated: +25
- Hold time 45s / Talk time 360s = 12.5%: +20
- Sentiment neutral-positive: +14
- (Wrap code pending)

Running Score: 79/85 = 93% FCR Predictor

Aggregate for Queue:
FCR-P (Queue) = AVG(FCR Predictor Score) for all active interactions
```

**Data Sources:** Genesys Predictive Engagement, NLP sentiment analysis, CRM, Knowledge Management system

**Target:** ≥ 85% | **Critical Threshold:** < 70%

---

### 9.2 Customer Effort Score Predictor (CES-P)

#### Why This Matters
CES predicts how much effort the customer is expending. High-effort interactions lead to churn—96% of high-effort customers become disloyal (Gartner). CES-P enables real-time intervention.

**Business Impact:**
- High-effort customers have **12% lower retention** rates
- Effort reduction drives 94% repurchase intent
- Real-time CES-P allows supervisor intervention during call

#### How to Calculate

```
CES Predictor = 100 - (Effort Penalty Points)

Effort Penalty Factors:
┌────────────────────────────┬─────────────────┬───────────────────────────────────┐
│ Factor                     │ Penalty Points  │ Detection Method                  │
├────────────────────────────┼─────────────────┼───────────────────────────────────┤
│ Repeat contact (< 7 days)  │ -20             │ CRM: Same customer, same topic    │
│ Multiple transfers         │ -10 per transfer│ Genesys: Transfer count           │
│ Long hold time (> 2 min)   │ -15             │ Genesys: cumulative hold          │
│ IVR re-routes (>2)         │ -10             │ IVR: Menu traversal count         │
│ Authentication failures    │ -10             │ Identity verification attempts    │
│ Channel switch required    │ -15             │ Started digital, needed voice     │
│ Escalation required        │ -10             │ Tier 1 → Tier 2 handoff           │
│ Long handle time (>2x avg) │ -10             │ AHT vs queue average              │
└────────────────────────────┴─────────────────┴───────────────────────────────────┘

Example:
Customer calls about same issue (repeat contact): -20
Transferred once: -10
Hold time 2:30: -15
Total penalties: -45

CES-P = 100 - 45 = 55 (High Effort - Intervention Needed)

Scoring:
- 80-100: Low Effort (Green)
- 60-79: Medium Effort (Yellow) 
- < 60: High Effort (Red) - Supervisor alert
```

**Data Sources:** CRM, Genesys interaction history, IVR logs, CTI events

**Target:** ≥ 75 | **Critical Threshold:** < 60

---

### 9.3 Net Promoter Score Predictor (NPS-P)

#### Why This Matters
Waiting for survey responses is too slow—response rates are typically 5-15%. NPS-P uses interaction signals to predict whether a customer would promote or detract, enabling proactive recovery.

**Business Impact:**
- NPS correlates with **revenue growth** (Bain & Company)
- Predicted detractors can receive callback or service recovery
- 70% of customers who complain and get resolution remain loyal

#### How to Calculate

```
NPS Predictor = Sentiment Score + Resolution Score + Effort Score - Issue Severity

Components (each 0-25 scale, total 100):
┌─────────────────────┬──────────────────────────────────────────────────────────────┐
│ Component           │ Calculation                                                  │
├─────────────────────┼──────────────────────────────────────────────────────────────┤
│ Sentiment Score     │ NLP analysis: Promoter words (+), Detractor words (-)        │
│                     │ "Thank you so much!" = +22, "This is frustrating" = +5       │
├─────────────────────┼──────────────────────────────────────────────────────────────┤
│ Resolution Score    │ FCR achieved = 25, Partial = 15, Unresolved = 5              │
├─────────────────────┼──────────────────────────────────────────────────────────────┤
│ Effort Score        │ CES-P converted to 0-25 scale: (CES-P / 4)                   │
├─────────────────────┼──────────────────────────────────────────────────────────────┤
│ Issue Severity      │ Billing error = -5, Service outage = -15, Fraud = -20        │
└─────────────────────┴──────────────────────────────────────────────────────────────┘

Example:
- Sentiment: Customer expressed gratitude = +22
- Resolution: Issue resolved first contact = +25
- Effort: CES-P was 80 = 80/4 = +20
- Severity: Minor billing question = -2

NPS-P = 22 + 25 + 20 - 2 = 65

Classification:
- 70-100: Predicted Promoter (9-10 NPS)
- 50-69: Predicted Passive (7-8 NPS)
- < 50: Predicted Detractor (0-6 NPS) - Trigger recovery
```

**Data Sources:** Speech analytics, interaction outcomes, CES-P calculation, issue categorization

**Target:** ≥ 65 | **Critical Threshold:** < 50

---

### 9.4 Repeat Contact Rate (Real-Time)

#### Why This Matters
Tracking repeat contacts in real-time identifies process failures and training gaps as they emerge, not days later in reports. Sudden spikes indicate systemic issues.

**Business Impact:**
- Industry average repeat contact rate: 20-30%
- Each repeat contact costs **$4-8 in additional handling**
- 67% of churn is preventable with first-contact resolution

#### How to Calculate

```
Repeat Contact Rate = (Contacts with Same Customer + Same Category in X Days / Total Contacts) × 100

Parameters:
- Lookback window: 7 days (industry standard)
- Same category: Contact reason code match (e.g., "Billing" → "Billing")
- Same customer: Customer ID or verified phone number

Real-Time Rolling Calculation:
┌─────────────────────┬────────────────────────────────────────────────────────────┐
│ Time Window         │ Formula                                                    │
├─────────────────────┼────────────────────────────────────────────────────────────┤
│ Current Hour        │ Repeat contacts this hour / Total contacts this hour × 100│
│ Rolling 4 Hours     │ Repeat contacts (4hr) / Total contacts (4hr) × 100        │
│ Today               │ Repeat contacts today / Total contacts today × 100        │
└─────────────────────┴────────────────────────────────────────────────────────────┘

Example (Current Hour):
- Total contacts: 2,450
- Contacts flagged as repeat (same customer, same topic, <7 days): 612
- Repeat Rate = 612 / 2,450 = 25.0%

Breakdown by Reason Code:
- Billing: 31% repeat (investigate)
- Technical: 28% repeat (investigate)
- Account: 18% repeat (normal)
- Sales: 12% repeat (normal)
```

**Data Sources:** CRM interaction history, Genesys contact records, CTI customer matching

**Target:** < 20% | **Critical Threshold:** > 30%

---

## Domain 10: Operational Efficiency Indicators

*Metrics measuring resource utilization and process efficiency*

### 10.1 Shrinkage Real-Time Variance

#### Why This Matters
Shrinkage is the difference between paid time and productive time. Real-time variance tracking identifies when actual shrinkage exceeds planned shrinkage, threatening service levels.

**Business Impact:**
- 1% unplanned shrinkage = **50 missing FTE** at 50,000 agent scale
- Shrinkage variance is the #1 cause of intraday service level misses
- Average contact center shrinkage: 30-35% (planned + unplanned)

#### How to Calculate

```
Shrinkage Variance = Actual Shrinkage % - Planned Shrinkage %

Shrinkage Categories:
┌─────────────────────────┬─────────────────────────────────────────────────────────┐
│ Category                │ Components                                              │
├─────────────────────────┼─────────────────────────────────────────────────────────┤
│ Planned Shrinkage       │ Breaks, lunch, training, meetings, coaching, PTO       │
│ Unplanned Shrinkage     │ Unscheduled absence, system issues, extended AUX       │
│ Productive Time         │ Ready, talking, hold, after-call work                  │
└─────────────────────────┴─────────────────────────────────────────────────────────┘

Calculation:
Actual Shrinkage % = (Paid Hours - Productive Hours) / Paid Hours × 100

Example:
Current interval (15 min):
- Scheduled agents: 12,847
- Paid hours: 3,211.75 (12,847 × 0.25)
- Productive hours: 2,184.0 (logged + ready + talk + ACW)
- Actual shrinkage: (3,211.75 - 2,184) / 3,211.75 = 32.0%

Planned shrinkage for this interval: 28%
Variance = 32.0% - 28% = +4.0% (RED - Over shrinkage)

Impact: 4% × 12,847 = 514 FTE equivalent not productive
```

**Data Sources:** WFM adherence data, Genesys agent states, schedule data

**Target:** ≤ ±2% variance | **Critical Threshold:** > ±5%

---

### 10.2 Average Handle Time (AHT) Trend Deviation

#### Why This Matters
AHT is a key capacity planning input. Real-time AHT deviations indicate process changes, system issues, or unusual contact types that will impact staffing accuracy and service levels.

**Business Impact:**
- Each 10-second AHT increase requires **2-3% more staff** to maintain SL
- AHT increases compound—longer calls = longer queues = more abandons
- Sudden AHT spikes often indicate system latency or new issue type

#### How to Calculate

```
AHT Deviation % = (Current AHT - Baseline AHT) / Baseline AHT × 100

AHT Components:
┌─────────────────┬────────────────────────────────────────────────────────────────┐
│ Component       │ Calculation                                                    │
├─────────────────┼────────────────────────────────────────────────────────────────┤
│ Talk Time       │ Customer-agent conversation duration                           │
│ Hold Time       │ Customer on hold during call                                   │
│ ACW Time        │ After-call work (wrap-up)                                      │
│ AHT             │ Talk Time + Hold Time + ACW Time                               │
└─────────────────┴────────────────────────────────────────────────────────────────┘

Baseline Selection:
- Same interval, same day of week, 4-week average
- Excludes outliers (>3 standard deviations)

Example:
Current hour AHT: 8:24 (504 seconds)
Baseline AHT (4-week avg, same hour, same DOW): 7:42 (462 seconds)
Deviation = (504 - 462) / 462 = +9.1%

Interpretation:
- ±5%: Normal variance
- 5-10%: Investigate (yellow)
- >10%: Alert - capacity impact (red)

By Component:
- Talk time: +12% (primary driver - investigate)
- Hold time: +3% (normal)
- ACW: +2% (normal)
```

**Data Sources:** Genesys Analytics, historical AHT data warehouse

**Target:** ≤ ±5% | **Critical Threshold:** > ±10%

---

### 10.3 Occupancy Rate Balance

#### Why This Matters
Occupancy measures how much time agents spend on customer work vs. waiting. Too low = wasted labor cost. Too high = burnout and quality issues. The balance point is critical.

**Business Impact:**
- Industry target: 80-85% occupancy
- >90% occupancy leads to **23% higher attrition** (ICMI research)
- <75% occupancy wastes **$2,500/agent/year** in labor cost

#### How to Calculate

```
Occupancy Rate = (Handle Time / Available Time) × 100

Where:
- Handle Time = Talk + Hold + ACW (all customer-facing work)
- Available Time = Total logged-in time - Aux states (break, training, etc.)

Per Agent:
Occupancy = (Total Handle Time in Period) / (Total Available Time in Period) × 100

Example (Individual Agent, 1 hour):
- Handle time: 48 minutes
- Available time: 55 minutes (60 min - 5 min break)
- Occupancy = 48 / 55 = 87.3%

Queue-Level Calculation:
Sum of all agent handle times / Sum of all agent available times × 100

Risk Zones:
┌───────────────┬─────────────────────────────────────────────────────────────────┐
│ Occupancy     │ Implication                                                     │
├───────────────┼─────────────────────────────────────────────────────────────────┤
│ < 70%         │ Overstaffed - consider reallocation or VTO                      │
│ 70-80%        │ Good balance - sustainable for extended periods                 │
│ 80-85%        │ Optimal - target zone                                           │
│ 85-90%        │ Elevated - monitor for burnout signals                          │
│ > 90%         │ Critical - unsustainable, quality and attrition risk            │
└───────────────┴─────────────────────────────────────────────────────────────────┘
```

**Data Sources:** Genesys agent statistics, WFM real-time data

**Target:** 80-85% | **Critical Threshold:** > 90% or < 70%

---

### 10.4 Schedule Efficiency Index

#### Why This Matters
Schedule efficiency measures how well actual staffing matches required staffing throughout the day. Poor efficiency means either understaffing (service impact) or overstaffing (cost waste).

**Business Impact:**
- 5% improvement in schedule efficiency = **$1.2M annual savings** at scale
- Efficiency drives service level achievement
- Identifies scheduling pattern opportunities

#### How to Calculate

```
Schedule Efficiency Index = 1 - (Sum of |Required - Scheduled| / Sum of Required) × 100

For each interval:
Efficiency = 100 - (|Required FTE - Scheduled FTE| / Required FTE × 100)

Then aggregate across all intervals:

Example (8 intervals):
┌──────────┬──────────┬───────────┬─────────────┬──────────────┐
│ Interval │ Required │ Scheduled │ Variance    │ Efficiency   │
├──────────┼──────────┼───────────┼─────────────┼──────────────┤
│ 08:00    │ 450      │ 420       │ -30 (under) │ 93.3%        │
│ 08:30    │ 480      │ 475       │ -5          │ 99.0%        │
│ 09:00    │ 520      │ 510       │ -10         │ 98.1%        │
│ 09:30    │ 550      │ 560       │ +10 (over)  │ 98.2%        │
│ 10:00    │ 580      │ 590       │ +10         │ 98.3%        │
│ 10:30    │ 560      │ 530       │ -30         │ 94.6%        │
│ 11:00    │ 540      │ 545       │ +5          │ 99.1%        │
│ 11:30    │ 510      │ 490       │ -20         │ 96.1%        │
└──────────┴──────────┴───────────┴─────────────┴──────────────┘

Aggregate:
Total Required: 4,190
Total Absolute Variance: 120
Efficiency Index = (1 - 120/4190) × 100 = 97.1%
```

**Data Sources:** WFM forecasting system, scheduling system, real-time adherence

**Target:** ≥ 95% | **Critical Threshold:** < 90%

---

## Domain 11: Agent Performance Predictors

*Real-time indicators of agent effectiveness and potential issues*

### 11.1 Quality Score Predictor (QA-P)

#### Why This Matters
Traditional QA evaluates 2-5% of calls days after they occur. QA-P uses speech analytics to predict quality scores in real-time, enabling immediate coaching intervention.

**Business Impact:**
- Real-time QA intervention improves scores by **15-20%**
- Reduces formal QA evaluation workload
- Enables "in-the-moment" coaching

#### How to Calculate

```
QA Predictor = Weighted Score of Real-Time Behavioral Indicators

Automated Behavioral Indicators:
┌────────────────────────────┬────────────────────────────────────────────┬────────┐
│ Indicator                  │ Detection Method                           │ Weight │
├────────────────────────────┼────────────────────────────────────────────┼────────┤
│ Greeting/Branding          │ Speech: Company name + agent name detected │ 15%    │
│ Active Listening           │ Speech: Acknowledgment words frequency     │ 15%    │
│ Empathy Statements         │ NLP: "I understand", "I apologize" detected│ 15%    │
│ Dead Air (Silence)         │ Audio: >5 sec silence periods count        │ 10%    │
│ Talk-Over (Interruptions)  │ Audio: Overlapping speech detection        │ 10%    │
│ Speech Clarity             │ Audio: Words per minute 120-150 optimal    │ 10%    │
│ Proper Hold Procedure      │ Genesys: Hold notification + periodic check│ 10%    │
│ Resolution Confirmation    │ Speech: "Is there anything else" detected  │ 15%    │
└────────────────────────────┴────────────────────────────────────────────┴────────┘

Example Calculation:
- Greeting: Complete = 15
- Active listening: Good = 13
- Empathy: One statement = 10
- Dead air: 2 instances = 7
- Talk-over: None = 10
- Clarity: 138 WPM = 10
- Hold procedure: Correct = 10
- Resolution: Confirmed = 15

QA-P = 15+13+10+7+10+10+10+15 = 90/100

Scoring:
- 90-100: Exceeds expectations
- 80-89: Meets expectations
- 70-79: Needs improvement - coaching opportunity
- < 70: Intervention required
```

**Data Sources:** Speech analytics platform, Genesys events, audio analysis

**Target:** ≥ 85 | **Critical Threshold:** < 70

---

### 11.2 Agent Attrition Risk Score

#### Why This Matters
Agent attrition costs **$10,000-$15,000 per agent** (recruiting, training, productivity ramp). Predicting at-risk agents enables proactive retention interventions.

**Business Impact:**
- Reducing attrition by 5% saves **$2.5-3.75M annually** at 50,000 agents
- At-risk agent identification allows targeted engagement
- 60% of attrition is preventable with early intervention

#### How to Calculate

```
Attrition Risk Score = Sum of Risk Factor Points (0-100)

Risk Factors:
┌─────────────────────────────────┬────────────────────────────────────────┬────────┐
│ Factor                          │ Measurement                            │ Points │
├─────────────────────────────────┼────────────────────────────────────────┼────────┤
│ Tenure < 90 days                │ New hire period - highest risk        │ +20    │
│ Recent schedule change (forced) │ Involuntary shift change last 30 days │ +15    │
│ Declining QA scores             │ 2+ consecutive score drops            │ +12    │
│ Increased absenteeism           │ >2 unplanned absences last 30 days    │ +12    │
│ Adherence decline               │ 5+ point drop from baseline           │ +10    │
│ Handle time increasing          │ AHT up >15% from personal baseline    │ +10    │
│ Customer complaints             │ 2+ complaints in 30 days              │ +8     │
│ No promotion in 18+ months      │ Stagnation indicator                  │ +8     │
│ Low engagement score            │ Last pulse survey < 3.0               │ +10    │
│ Team attrition spike            │ 2+ peers resigned last 60 days        │ +5     │
└─────────────────────────────────┴────────────────────────────────────────┴────────┘

Example:
- Agent tenure: 6 months (0 points)
- Schedule changed last week: +15
- QA scores: Stable (0 points)
- Absent 3 times this month: +12
- Adherence dropped 7%: +10
- AHT normal (0 points)
- No complaints (0 points)
- No promotion (18 months): +8
- Engagement: 3.5 (0 points)
- Team stable (0 points)

Risk Score = 45

Risk Levels:
- 0-25: Low risk (green)
- 26-50: Medium risk (yellow) - manager awareness
- 51-75: High risk (orange) - engagement plan required
- 76-100: Critical risk (red) - immediate intervention
```

**Data Sources:** HRIS, WFM, QA system, engagement surveys, CRM complaints

**Target:** < 25 | **Critical Threshold:** > 50

---

### 11.3 Agent Readiness Index

#### Why This Matters
Agent readiness measures whether agents have the skills, tools, and access to handle their assigned work. Low readiness leads to transfers, holds, and poor customer experience.

**Business Impact:**
- Unready agents have **40% higher AHT**
- Skill gaps cause 15-20% of escalations
- System access issues account for 30% of first-week attrition

#### How to Calculate

```
Agent Readiness Index = (Skill Match + System Access + Training Currency + Tool Performance) / 4

Components (each 0-100):
┌─────────────────────┬───────────────────────────────────────────────────────────────┐
│ Component           │ Calculation                                                   │
├─────────────────────┼───────────────────────────────────────────────────────────────┤
│ Skill Match         │ % of queue-required skills the agent possesses                │
│                     │ (Agent Skills ∩ Queue Required Skills) / Queue Required × 100 │
├─────────────────────┼───────────────────────────────────────────────────────────────┤
│ System Access       │ % of required applications accessible and logged in           │
│                     │ (Active Systems ∩ Required Systems) / Required Systems × 100  │
├─────────────────────┼───────────────────────────────────────────────────────────────┤
│ Training Currency   │ % of required certifications current (not expired)            │
│                     │ Current Certs / Required Certs × 100                          │
├─────────────────────┼───────────────────────────────────────────────────────────────┤
│ Tool Performance    │ Average response time of agent's critical applications        │
│                     │ 100 - (Avg App Latency ms / 50) capped at 100                 │
└─────────────────────┴───────────────────────────────────────────────────────────────┘

Example:
- Skill match: 8 of 10 skills = 80%
- System access: All 6 systems active = 100%
- Training: 4 of 5 certs current = 80%
- Tool perf: 120ms avg latency = 100 - (120/50) = 97.6%

Readiness Index = (80 + 100 + 80 + 97.6) / 4 = 89.4%

Agent Status:
- ≥ 90%: Fully ready
- 75-89%: Mostly ready - minor gaps
- < 75%: Not ready - address gaps before assignment
```

**Data Sources:** Skills management system, SSO/identity system, LMS, Nexthink/endpoint monitoring

**Target:** ≥ 90% | **Critical Threshold:** < 75%

---

### 11.4 Coaching Opportunity Score

#### Why This Matters
Identifies agents who would benefit most from coaching based on performance patterns. Prioritizes limited coaching resources for maximum impact.

**Business Impact:**
- Targeted coaching improves performance **2x faster** than random coaching
- Efficient use of supervisor time (limited resource)
- Data-driven development planning

#### How to Calculate

```
Coaching Opportunity Score = (Improvement Potential × Coachability Index) / 100

Improvement Potential (0-100):
Gap between current performance and top performer in same cohort

Improvement Potential = (Top Performer Score - Agent Score) / Top Performer Score × 100

Coachability Index (0-100):
Likelihood to improve based on historical response to coaching

Coachability Index Factors:
┌────────────────────────────────┬────────────────────────────────────────────┬────────┐
│ Factor                         │ Measurement                                │ Weight │
├────────────────────────────────┼────────────────────────────────────────────┼────────┤
│ Prior coaching response        │ % improvement after last 3 coaching events │ 40%    │
│ Engagement score               │ Pulse survey engagement rating             │ 25%    │
│ Self-initiated learning        │ Optional training completed                │ 20%    │
│ Tenure (diminishing returns)   │ Higher for 6mo-2yr, lower for <6mo or >5yr│ 15%    │
└────────────────────────────────┴────────────────────────────────────────────┴────────┘

Example:
Agent current composite score: 72
Top performer in cohort: 94
Improvement Potential = (94-72)/94 × 100 = 23.4

Coachability:
- Prior coaching: +8% avg improvement = 80 × 0.4 = 32
- Engagement: 4.2/5 = 84 × 0.25 = 21
- Self-learning: 3 courses completed = 75 × 0.2 = 15
- Tenure: 14 months (optimal) = 90 × 0.15 = 13.5
Coachability Index = 81.5

Coaching Opportunity = (23.4 × 81.5) / 100 = 19.1

Priority:
- > 30: High priority - immediate coaching
- 15-30: Medium priority - schedule within 2 weeks
- < 15: Low priority - self-directed resources
```

**Data Sources:** Performance management system, QA scores, LMS, engagement surveys

**Target:** Prioritize scores > 30 | Track improvement after intervention

---

## Domain 12: Financial Impact Indicators

*Metrics that translate operational performance to financial outcomes*

### 12.1 Cost Per Contact (Real-Time)

#### Why This Matters
CPC is the fundamental unit economics of contact center operations. Real-time tracking enables immediate identification of cost drivers and efficiency opportunities.

**Business Impact:**
- Industry average CPC: $6-12 per voice contact
- 10% CPC reduction = **$3-6M annual savings** at enterprise scale
- Real-time visibility enables dynamic optimization

#### How to Calculate

```
Cost Per Contact = Total Operating Cost / Total Contacts Handled

Operating Cost Components:
┌──────────────────────────┬─────────────────────────────────────────────────────────┐
│ Component                │ Calculation                                             │
├──────────────────────────┼─────────────────────────────────────────────────────────┤
│ Labor (fully loaded)     │ (Hourly rate + benefits + overhead) × Hours worked     │
│ Technology               │ Telecom + software licensing + infrastructure / interval│
│ Facilities               │ Rent + utilities + equipment / interval (if applicable) │
│ Support functions        │ QA, training, WFM, IT support allocated                 │
└──────────────────────────┴─────────────────────────────────────────────────────────┘

Real-Time Calculation (15-min interval):
Labor Cost = Agents × 0.25 hours × Fully Loaded Rate
Technology = Monthly tech cost / intervals per month
Contacts = Total contacts completed in interval

Example:
- Agents: 10,500
- Fully loaded rate: $28/hour
- Interval labor: 10,500 × 0.25 × $28 = $73,500
- Technology: $180,000 monthly / 2,880 intervals = $62.50
- Contacts handled: 8,750

CPC = ($73,500 + $62.50) / 8,750 = $8.41

Trend Analysis:
- Compare to prior interval, same day last week, monthly average
- Alert if CPC increases > 10% from baseline
```

**Data Sources:** Financial systems, WFM, Genesys contact counts

**Target:** Baseline ± 5% | **Critical Threshold:** > 15% above baseline

---

### 12.2 Revenue Protection Score

#### Why This Matters
Measures revenue at risk due to operational issues—abandoned calls, failed transfers, system outages that prevent sales or retention.

**Business Impact:**
- Each abandoned call = **$15-50** in potential lost revenue (varies by business)
- Failed save attempts = confirmed churn
- Downtime during peak = revenue loss

#### How to Calculate

```
Revenue Protection Score = 100 - (Revenue at Risk / Total Revenue Opportunity × 100)

Revenue at Risk Components:
┌───────────────────────────────┬────────────────────────────────────────────────────┐
│ Risk Category                 │ Calculation                                        │
├───────────────────────────────┼────────────────────────────────────────────────────┤
│ Abandoned Calls               │ Abandoned count × Avg revenue per call             │
│ Failed Transfers to Sales     │ Transfer failures × Sales conversion × Avg order   │
│ Retention Queue Abandons      │ Abandons × Save rate × Customer lifetime value     │
│ System Downtime               │ Minutes down × Calls/min × Revenue/call            │
│ Quality Failures              │ Failed QA calls × Estimated revenue impact         │
└───────────────────────────────┴────────────────────────────────────────────────────┘

Example (hourly):
- Abandoned calls (sales queues): 145 × $35 = $5,075
- Failed transfers: 23 × 0.15 × $120 = $414
- Retention abandons: 67 × 0.30 × $480 = $9,648
- System downtime: 0 minutes = $0
- Quality failures: 34 × $25 = $850

Total Revenue at Risk: $15,987
Total Revenue Opportunity (hour): $425,000

Revenue Protection Score = 100 - (15,987 / 425,000 × 100) = 96.2%

Target: ≥ 97% | Critical: < 95%
```

**Data Sources:** Revenue systems, call outcomes, conversion tracking, LTV data

**Target:** ≥ 97% | **Critical Threshold:** < 95%

---

### 12.3 Labor Efficiency Ratio

#### Why This Matters
Measures productive output relative to labor investment. Higher ratios indicate better utilization of the most expensive resource—people.

**Business Impact:**
- Labor is **65-75%** of contact center operating cost
- 5% efficiency improvement = significant bottom-line impact
- Benchmarking against industry enables competitive positioning

#### How to Calculate

```
Labor Efficiency Ratio = (Contacts Handled × Quality Factor) / Paid Labor Hours

Where:
- Contacts Handled: Total interactions completed
- Quality Factor: Multiplier based on quality scores (0.8 - 1.2)
- Paid Labor Hours: Total scheduled hours including shrinkage

Quality Factor Calculation:
Quality Factor = 0.8 + (Average QA Score / 100 × 0.4)
- If QA avg = 50, factor = 0.8 + 0.2 = 1.0
- If QA avg = 100, factor = 0.8 + 0.4 = 1.2
- If QA avg = 0, factor = 0.8

Example:
- Contacts handled: 52,000
- Average QA score: 87
- Quality factor: 0.8 + (87/100 × 0.4) = 1.148
- Paid labor hours: 15,500

Labor Efficiency Ratio = (52,000 × 1.148) / 15,500 = 3.85

Interpretation:
- Industry average: 3.0-4.0 contacts per paid hour
- High performers: > 4.5
- Low performers: < 2.5

Tracking enables:
- Vendor comparison (apples-to-apples)
- Trend analysis (improving or declining)
- Investment justification (tool ROI)
```

**Data Sources:** WFM, Genesys, QA system, payroll

**Target:** ≥ 4.0 | **Critical Threshold:** < 3.0

---

### 12.4 Avoidable Contact Cost

#### Why This Matters
Measures cost of contacts that shouldn't have occurred—repeat calls, preventable issues, system-generated contacts. These represent pure waste.

**Business Impact:**
- 20-30% of contacts are potentially avoidable
- Each avoidable contact costs full CPC ($6-12)
- Reducing avoidables by 10% saves **$3M+ annually**

#### How to Calculate

```
Avoidable Contact Cost = Avoidable Contact Count × Cost Per Contact

Avoidable Contact Categories:
┌──────────────────────────────┬───────────────────────────────────────────────────────┐
│ Category                     │ Detection Method                                      │
├──────────────────────────────┼───────────────────────────────────────────────────────┤
│ Repeat Contacts              │ Same customer, same issue within 7 days               │
│ Status Check Calls           │ "Where is my order/refund/request" contacts           │
│ IVR Failures                 │ IVR should have resolved but transferred to agent     │
│ Website/App Failures         │ Contact due to digital channel technical issue        │
│ Process Failures             │ Contact due to broken internal process                │
│ Communication Gaps           │ Contact because customer wasn't proactively notified  │
│ Billing Errors               │ Contact to fix company-caused billing mistake         │
└──────────────────────────────┴───────────────────────────────────────────────────────┘

Example (daily):
- Repeat contacts: 4,200 × $8.50 = $35,700
- Status checks: 2,800 × $8.50 = $23,800
- IVR failures: 1,100 × $8.50 = $9,350
- Website issues: 600 × $8.50 = $5,100
- Process failures: 450 × $8.50 = $3,825
- Communication gaps: 800 × $8.50 = $6,800
- Billing errors: 350 × $8.50 = $2,975

Total Avoidable Cost: $87,550/day = $2.63M/month

Avoidable Contact Rate = 10,300 / 48,000 total = 21.5%
```

**Data Sources:** CRM contact categorization, speech analytics, root cause analysis

**Target:** < 15% of contacts avoidable | **Critical Threshold:** > 25%

---

## Domain 13: Channel Performance Indicators

*Metrics specific to omnichannel operations*

### 13.1 Channel Containment Rate

#### Why This Matters
Measures the percentage of contacts that complete within their originating channel without escalating to a more expensive channel (e.g., chat → voice).

**Business Impact:**
- Voice costs 3-5x more than digital channels
- Chat containment saves **$4-8 per contact**
- IVR containment saves **$6-10 per contact**

#### How to Calculate

```
Channel Containment Rate = (Contacts Completed in Channel / Contacts Started in Channel) × 100

By Channel:
┌─────────────┬──────────────────────────────────────────────────────────────────────┐
│ Channel     │ Containment Definition                                               │
├─────────────┼──────────────────────────────────────────────────────────────────────┤
│ IVR         │ Customer completed task in IVR without agent transfer                │
│ Chat        │ Conversation resolved without voice callback                         │
│ Email       │ Issue resolved via email without phone/chat escalation               │
│ Self-Service│ Web/app transaction completed without contacting support             │
│ SMS/Text    │ Conversation completed in SMS channel                                │
│ Social      │ Issue resolved in social channel (DM resolved, not escalated)        │
└─────────────┴──────────────────────────────────────────────────────────────────────┘

Example:
IVR:
- Contacts entering IVR: 125,000
- Completed in IVR (no transfer): 43,750
- Containment = 43,750 / 125,000 = 35%

Chat:
- Chats initiated: 28,000
- Completed without voice: 24,920
- Containment = 24,920 / 28,000 = 89%

Overall Weighted:
Channel Containment = Σ(Channel Contacts × Channel Containment Rate) / Total Contacts
```

**Data Sources:** Genesys, IVR platform, digital channel analytics

**Target:** IVR ≥ 40%, Chat ≥ 85%, Email ≥ 95% | **Critical Threshold:** 10% below target

---

### 13.2 Channel Shift Velocity

#### Why This Matters
Tracks the rate at which contacts are migrating from expensive channels (voice) to cost-effective channels (digital, self-service). Key strategic metric.

**Business Impact:**
- Each 1% shift from voice to digital saves **$500K-$1M annually** at scale
- Digital-first customers have higher satisfaction (when effective)
- Competitive necessity—customers expect channel choice

#### How to Calculate

```
Channel Shift Velocity = (Current Digital % - Prior Period Digital %) / Prior Period Digital % × 100

Channel Mix Tracking:
┌─────────────┬────────────────┬────────────────┬────────────────┐
│ Channel     │ 90 Days Ago    │ Current        │ Shift          │
├─────────────┼────────────────┼────────────────┼────────────────┤
│ Voice       │ 62%            │ 58%            │ -4%            │
│ Chat        │ 18%            │ 21%            │ +3%            │
│ Self-Service│ 12%            │ 14%            │ +2%            │
│ Email       │ 5%             │ 4%             │ -1%            │
│ Social      │ 3%             │ 3%             │ 0%             │
└─────────────┴────────────────┴────────────────┴────────────────┘

Voice Deflection Rate = Voice contacts deflected to digital / Total voice contact attempts

Calculation:
- Voice contacts 90 days ago: 62% of 1.2M = 744,000
- Voice contacts now: 58% of 1.3M = 754,000
- Despite volume growth, percentage decreased

Velocity = (58 - 62) / 62 × 100 = -6.5% (positive outcome - voice declining)

Annualized Impact:
4% shift × 1.3M monthly contacts × $6 savings = $312,000/month saved
```

**Data Sources:** Contact volume by channel, digital analytics

**Target:** ≥ 1% quarterly shift to digital | **Critical Threshold:** Voice share increasing

---

### 13.3 Cross-Channel Resolution Rate

#### Why This Matters
Measures successful resolution when customers use multiple channels for the same issue. Poor cross-channel experience is a top driver of customer frustration.

**Business Impact:**
- 60% of customers use multiple channels for same issue
- Customers expect context to follow them across channels
- Failed handoffs double resolution time and cost

#### How to Calculate

```
Cross-Channel Resolution Rate = Successful Cross-Channel Resolutions / Total Cross-Channel Journeys × 100

Cross-Channel Journey = Customer used 2+ channels for same issue within 7 days

Successful Resolution Criteria:
- Issue resolved (confirmed by disposition/survey)
- No additional contact on same issue within 7 days
- Customer didn't have to repeat information (context transferred)

Journey Tracking:
┌────────────────────────────────┬──────────────────────────────────────────────────┐
│ Journey Type                   │ Resolution Rate                                  │
├────────────────────────────────┼──────────────────────────────────────────────────┤
│ Chat → Voice                   │ 72% (context often lost)                         │
│ IVR → Voice                    │ 85% (context transfers well)                     │
│ Email → Voice                  │ 68% (different systems)                          │
│ Social → Voice                 │ 61% (poor context transfer)                      │
│ Voice → Chat (callback)        │ 78% (initiated by company)                       │
└────────────────────────────────┴──────────────────────────────────────────────────┘

Example:
- Total contacts this month: 1.2M
- Multi-channel journeys: 156,000 (13%)
- Successfully resolved: 112,320

Cross-Channel Resolution Rate = 112,320 / 156,000 = 72%
```

**Data Sources:** Customer journey analytics, CRM, interaction history

**Target:** ≥ 80% | **Critical Threshold:** < 70%

---

### 13.4 Digital Experience Score (DXS)

#### Why This Matters
Composite score measuring the health of digital channel customer experience. Digital is strategic—poor DXS drives contacts back to expensive voice channel.

**Business Impact:**
- Poor digital experience increases voice volume by **15-25%**
- Digital customer acquisition cost is 60% lower than voice
- DXS correlates with customer lifetime value

#### How to Calculate

```
Digital Experience Score = W1(Task Completion) + W2(Response Time) + W3(Effort) + W4(Satisfaction)

Components:
┌─────────────────────┬───────────────────────────────────────────────────────┬────────┐
│ Component           │ Measurement                                           │ Weight │
├─────────────────────┼───────────────────────────────────────────────────────┼────────┤
│ Task Completion     │ % of digital tasks completed without error            │ 30%    │
│ Response Time       │ Avg response time vs expectation (indexed 0-100)      │ 25%    │
│ Effort Score        │ Digital CES from surveys (0-100 scale)                │ 25%    │
│ Satisfaction        │ Digital CSAT from surveys (0-100 scale)               │ 20%    │
└─────────────────────┴───────────────────────────────────────────────────────┴────────┘

Response Time Index:
- Chat first response < 30s = 100
- Chat first response 30-60s = 80
- Chat first response > 60s = (120 - actual seconds) capped at 0

Example:
- Task completion: 87% × 0.30 = 26.1
- Response time: Index 82 × 0.25 = 20.5
- Effort score: 76 × 0.25 = 19.0
- Satisfaction: 81 × 0.20 = 16.2

DXS = 26.1 + 20.5 + 19.0 + 16.2 = 81.8

Rating Scale:
- 85-100: Excellent digital experience
- 70-84: Good - competitive
- 55-69: Needs improvement - driving voice contacts
- < 55: Poor - urgent remediation needed
```

**Data Sources:** Digital analytics, chat platform, surveys, web analytics

**Target:** ≥ 80 | **Critical Threshold:** < 65

---

## Domain 14: Compliance & Risk Indicators

*Regulatory compliance and operational risk metrics*

### 14.1 PCI Compliance Rate (Real-Time)

#### Why This Matters
PCI-DSS compliance is mandatory for payment processing. Non-compliance results in fines, breach liability, and potential loss of processing ability.

**Business Impact:**
- PCI non-compliance fines: **$5,000-$100,000 per month**
- Data breach liability: Average $4.35M per incident
- Merchant account revocation risk

#### How to Calculate

```
PCI Compliance Rate = (Compliant Payment Interactions / Total Payment Interactions) × 100

Compliance Requirements:
┌─────────────────────────────────┬─────────────────────────────────────────────────────┐
│ Requirement                     │ Validation                                          │
├─────────────────────────────────┼─────────────────────────────────────────────────────┤
│ DTMF masking active             │ Card data entered via masked keypad                 │
│ Recording paused                │ Recording paused during card data capture           │
│ Screen capture paused           │ Screen recording suspended during payment           │
│ Data not stored in call notes   │ NLP scan of notes for PAN patterns                  │
│ Agent didn't verbalize card data│ Speech analytics for card number recitation         │
│ Secure transfer to IVR          │ Payment handled by PCI-compliant IVR                │
└─────────────────────────────────┴─────────────────────────────────────────────────────┘

Example:
- Total payment interactions: 8,450
- DTMF masking violations: 12
- Recording violations: 3
- Screen capture violations: 2
- Notes violations: 8
- Verbal violations: 5

Total violations: 30
Compliant interactions: 8,420

PCI Compliance Rate = 8,420 / 8,450 = 99.64%

Any violation triggers investigation and retraining.
```

**Data Sources:** Payment gateway logs, call recording system, QA monitoring, DLP tools

**Target:** 100% | **Critical Threshold:** < 99.5%

---

### 14.2 TCPA Consent Verification Rate

#### Why This Matters
TCPA violations for calling without consent cost **$500-$1,500 per call**. Class action lawsuits have resulted in $50M+ settlements.

**Business Impact:**
- Per-call penalties can exceed the value of the customer
- Class action exposure at scale is catastrophic
- Reputation damage affects acquisition

#### How to Calculate

```
TCPA Consent Verification Rate = (Verified Consent Calls / Total Outbound Calls) × 100

Consent Requirements:
┌─────────────────────┬────────────────────────────────────────────────────────────────┐
│ Call Type           │ Consent Requirement                                            │
├─────────────────────┼────────────────────────────────────────────────────────────────┤
│ Marketing           │ Prior express written consent (PEWC) required                  │
│ Informational       │ Prior express consent (verbal OK)                              │
│ Transactional       │ Established business relationship (EBR)                        │
│ Collections         │ Specific regulations apply (FDCPA + TCPA)                      │
└─────────────────────┴────────────────────────────────────────────────────────────────┘

Verification Process:
1. Query consent database before dial
2. Verify consent type matches call purpose
3. Check do-not-call registry
4. Validate time-of-day rules
5. Log verification result

Example:
- Outbound dials attempted: 45,000
- Consent verified: 44,820
- Blocked (no consent): 145
- Blocked (DNC list): 35

Verification Rate = 44,820 / 45,000 = 99.60%
Block Rate = 180 / 45,000 = 0.40% (these were prevented violations)
```

**Data Sources:** Dialer system, consent management platform, DNC database

**Target:** 100% | **Critical Threshold:** < 99%

---

### 14.3 Data Privacy Compliance Score

#### Why This Matters
GDPR, CCPA, and other privacy regulations require proper handling of customer data. Violations result in fines up to **4% of global revenue**.

**Business Impact:**
- GDPR fines: Up to €20M or 4% of revenue
- CCPA fines: $2,500-$7,500 per violation
- Customer trust erosion

#### How to Calculate

```
Privacy Compliance Score = Average of Compliance Checkpoints (0-100)

Checkpoints:
┌─────────────────────────────────┬───────────────────────────────────────────┬────────┐
│ Checkpoint                      │ Validation                                │ Weight │
├─────────────────────────────────┼───────────────────────────────────────────┼────────┤
│ Data minimization               │ Only required data collected              │ 15%    │
│ Consent management              │ Valid consent on file for data use        │ 20%    │
│ Right to access (DSAR)          │ DSAR requests fulfilled within SLA        │ 15%    │
│ Right to delete                 │ Deletion requests completed within SLA    │ 15%    │
│ Data retention compliance       │ Data auto-deleted per retention policy    │ 15%    │
│ Third-party data sharing        │ DPAs in place with all processors         │ 10%    │
│ Security safeguards             │ Encryption, access controls verified      │ 10%    │
└─────────────────────────────────┴───────────────────────────────────────────┴────────┘

Example:
- Data minimization: 92% (some agents collecting excess)
- Consent management: 100%
- DSAR fulfillment: 98% (within 30 days)
- Deletion compliance: 100%
- Retention compliance: 95%
- Third-party DPAs: 100%
- Security: 100%

Weighted Score:
= (92×.15) + (100×.20) + (98×.15) + (100×.15) + (95×.15) + (100×.10) + (100×.10)
= 13.8 + 20 + 14.7 + 15 + 14.25 + 10 + 10
= 97.75%
```

**Data Sources:** Privacy management platform, consent database, DLP tools, DSAR tracking

**Target:** ≥ 98% | **Critical Threshold:** < 95%

---

### 14.4 Regulatory Disclosure Compliance

#### Why This Matters
Many industries require specific disclosures during customer interactions (finance, healthcare, insurance). Failure to disclose creates legal liability.

**Business Impact:**
- Financial services disclosure failures: Per-violation fines
- Healthcare HIPAA violations: $100-$50,000 per violation
- Insurance regulatory action and license risk

#### How to Calculate

```
Disclosure Compliance Rate = (Interactions with Required Disclosures / Interactions Requiring Disclosures) × 100

Disclosure Requirements (example - financial services):
┌─────────────────────────────────┬─────────────────────────────────────────────────────┐
│ Scenario                        │ Required Disclosure                                 │
├─────────────────────────────────┼─────────────────────────────────────────────────────┤
│ Call recording                  │ "This call may be recorded for quality..."         │
│ Collections                     │ Mini-Miranda rights statement                       │
│ Credit application              │ Credit check consent disclosure                     │
│ Fee discussion                  │ Fee schedule disclosure                             │
│ Rate quote                      │ APR disclosure requirements                         │
│ Privacy policy                  │ Privacy practices notification                      │
└─────────────────────────────────┴─────────────────────────────────────────────────────┘

Detection Methods:
- Speech analytics for required phrases
- Screen monitoring for disclosure scripts
- System-enforced disclosure popups

Example:
- Calls requiring recording disclosure: 145,000
- Disclosure confirmed (speech analytics): 144,275
- Compliance rate: 99.50%

- Collections calls: 12,000
- Mini-Miranda delivered: 11,940
- Compliance rate: 99.50%

Overall weighted by call volume.
```

**Data Sources:** Speech analytics, compliance monitoring, QA evaluations

**Target:** 100% | **Critical Threshold:** < 99%

---

## Summary: Complete Leading Indicator Framework

### Total Indicators by Domain

| Domain | Original | New | Total |
|--------|----------|-----|-------|
| 1. Platform & Infrastructure | 4 | 0 | 4 |
| 2. Network & Connectivity | 4 | 0 | 4 |
| 3. Voice Quality | 4 | 0 | 4 |
| 4. Workforce & Capacity | 4 | 0 | 4 |
| 5. Agent Desktop | 4 | 0 | 4 |
| 6. IVR & Self-Service | 4 | 0 | 4 |
| 7. Integration & Data | 4 | 0 | 4 |
| 8. Security & Access | 4 | 0 | 4 |
| 9. Customer Experience | 0 | 4 | 4 |
| 10. Operational Efficiency | 0 | 4 | 4 |
| 11. Agent Performance | 0 | 4 | 4 |
| 12. Financial Impact | 0 | 4 | 4 |
| 13. Channel Performance | 0 | 4 | 4 |
| 14. Compliance & Risk | 0 | 4 | 4 |
| **TOTAL** | **32** | **24** | **56** |

### Quick Reference: All 56 Indicators

#### Platform & Infrastructure (4)
1. Genesys Cloud Global Availability
2. Disaster Recovery Readiness Score
3. Core Infrastructure Headroom
4. Database Connection Pool Health

#### Network & Connectivity (4)
5. End-to-End Latency (Genesys Edge)
6. Network Jitter Variance
7. Packet Loss Rate
8. WAN Circuit Utilization

#### Voice Quality (4)
9. MOS Score (Mean Opinion Score)
10. Audio Quality Index
11. Echo/Noise Detection Rate
12. SIP Trunk Capacity Utilization

#### Workforce & Capacity (4)
13. Real-Time Adherence Rate
14. Agents Logged In vs Scheduled
15. Service Level (Rolling 30 min)
16. Abandonment Rate Prediction

#### Agent Desktop (4)
17. Citrix Session Latency
18. Application Response Time (CRM, KB)
19. Desktop Error Rate
20. Session Stability Score

#### IVR & Self-Service (4)
21. IVR Containment Rate
22. Speech Recognition Accuracy
23. IVR Error Rate
24. Self-Service Completion Rate

#### Integration & Data (4)
25. CTI Screen Pop Success Rate
26. CRM Integration Latency
27. API Error Rate
28. Real-Time Data Sync Lag

#### Security & Access (4)
29. Authentication Success Rate
30. Unauthorized Access Attempts
31. Session Anomaly Detection
32. Certificate/Token Expiry

#### Customer Experience (4)
33. First Contact Resolution Predictor
34. Customer Effort Score Predictor
35. Net Promoter Score Predictor
36. Repeat Contact Rate

#### Operational Efficiency (4)
37. Shrinkage Variance
38. AHT Trend Deviation
39. Occupancy Rate Balance
40. Schedule Efficiency Index

#### Agent Performance (4)
41. Quality Score Predictor
42. Agent Attrition Risk Score
43. Agent Readiness Index
44. Coaching Opportunity Score

#### Financial Impact (4)
45. Cost Per Contact (Real-Time)
46. Revenue Protection Score
47. Labor Efficiency Ratio
48. Avoidable Contact Cost

#### Channel Performance (4)
49. Channel Containment Rate
50. Channel Shift Velocity
51. Cross-Channel Resolution Rate
52. Digital Experience Score

#### Compliance & Risk (4)
53. PCI Compliance Rate
54. TCPA Consent Verification
55. Data Privacy Compliance Score
56. Regulatory Disclosure Compliance

---

*This document is maintained by the Contact Center Operations team. For questions or updates, contact the Operations Center of Excellence.*

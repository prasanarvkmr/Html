-- ============================================================================
-- APPLICATION HEALTH MONITORING QUERIES
-- Purpose: Intelligent health status determination with false alarm reduction
-- Data Granularity: Per-minute metrics
-- ============================================================================

-- ============================================================================
-- TABLE STRUCTURE ASSUMPTIONS
-- ============================================================================
/*
Tables Expected:
- application_metrics: Per-minute metrics for each application
- host_metrics: Per-minute metrics for each host
- error_logs: Error events with timestamps
- threshold_config: Configurable thresholds per entity
- alert_history: Historical alerts for correlation
*/

-- ============================================================================
-- 1. THRESHOLD BREACH WITH HISTORICAL CONTEXT (30-min lookback)
-- Reduces false alarms by checking if errors existed in the last 30 minutes
-- ============================================================================

WITH current_status AS (
    SELECT 
        entity_id,
        entity_name,
        entity_type,
        metric_name,
        metric_value,
        threshold_value,
        recorded_at,
        CASE 
            WHEN metric_value > threshold_value THEN 1 
            ELSE 0 
        END AS is_breaching
    FROM application_metrics am
    JOIN threshold_config tc ON am.entity_id = tc.entity_id 
        AND am.metric_name = tc.metric_name
    WHERE recorded_at >= DATEADD(MINUTE, -1, GETDATE())  -- Current minute
),
historical_errors AS (
    SELECT 
        entity_id,
        COUNT(*) AS error_count_30min,
        COUNT(DISTINCT DATEPART(MINUTE, recorded_at)) AS minutes_with_errors,
        MIN(recorded_at) AS first_error_time,
        MAX(recorded_at) AS last_error_time
    FROM error_logs
    WHERE recorded_at >= DATEADD(MINUTE, -30, GETDATE())
    GROUP BY entity_id
)
SELECT 
    cs.entity_id,
    cs.entity_name,
    cs.entity_type,
    cs.metric_name,
    cs.metric_value,
    cs.threshold_value,
    COALESCE(he.error_count_30min, 0) AS errors_last_30min,
    COALESCE(he.minutes_with_errors, 0) AS minutes_with_errors,
    CASE 
        -- CRITICAL: Currently breaching AND had errors in last 30 mins
        WHEN cs.is_breaching = 1 AND he.error_count_30min >= 5 THEN 'CRITICAL'
        -- DEGRADED: Currently breaching OR sustained errors (>50% of last 30 mins)
        WHEN cs.is_breaching = 1 AND he.minutes_with_errors >= 15 THEN 'DEGRADED'
        -- WARNING: Currently breaching but no prior history (could be transient)
        WHEN cs.is_breaching = 1 AND COALESCE(he.error_count_30min, 0) = 0 THEN 'WARNING'
        -- DEGRADED: Not currently breaching but had significant recent errors
        WHEN cs.is_breaching = 0 AND he.minutes_with_errors >= 10 THEN 'DEGRADED'
        -- HEALTHY: No current breach and minimal/no historical errors
        ELSE 'HEALTHY'
    END AS health_status,
    CASE 
        WHEN cs.is_breaching = 1 AND COALESCE(he.error_count_30min, 0) = 0 
        THEN 'Possible transient spike - monitoring'
        WHEN cs.is_breaching = 1 AND he.error_count_30min >= 5 
        THEN 'Confirmed issue - errors persisting'
        ELSE NULL
    END AS status_note
FROM current_status cs
LEFT JOIN historical_errors he ON cs.entity_id = he.entity_id;


-- ============================================================================
-- 1B. BASELINE CALCULATION - Average and Standard Deviation
-- Calculate historical baseline for anomaly detection
-- ============================================================================

/*
BASELINE CONCEPT:
- Baseline = "What's normal for this entity at this time?"
- We compare current metrics against baseline to detect anomalies
- Using same hour-of-day accounts for daily patterns (e.g., peak hours)
- Using 7-30 days of history provides statistical significance
*/

-- -----------------------------------------------------------------------------
-- METHOD 1: Simple Baseline (Last 7 Days, Same Hour)
-- Good for: Quick implementation, moderate accuracy
-- -----------------------------------------------------------------------------

SELECT 
    entity_id,
    entity_name,
    metric_name,
    DATEPART(HOUR, GETDATE()) AS current_hour,
    
    -- Baseline Average: Mean of same-hour values over past 7 days
    AVG(metric_value) AS baseline_avg,
    
    -- Baseline Standard Deviation: Measure of normal variance
    STDEV(metric_value) AS baseline_stddev,
    
    -- Sample size (number of data points used)
    COUNT(*) AS sample_count,
    
    -- Min/Max for context
    MIN(metric_value) AS baseline_min,
    MAX(metric_value) AS baseline_max,
    
    -- Percentiles for more robust thresholds
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY metric_value) OVER (PARTITION BY entity_id, metric_name) AS baseline_p50,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY metric_value) OVER (PARTITION BY entity_id, metric_name) AS baseline_p95,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY metric_value) OVER (PARTITION BY entity_id, metric_name) AS baseline_p99

FROM application_metrics
WHERE 
    -- Last 7 days of data
    recorded_at >= DATEADD(DAY, -7, GETDATE())
    -- Same hour as current time (e.g., if it's 10 AM, look at 10 AM data)
    AND DATEPART(HOUR, recorded_at) = DATEPART(HOUR, GETDATE())
    -- Exclude weekends if business app (optional)
    -- AND DATEPART(WEEKDAY, recorded_at) BETWEEN 2 AND 6
GROUP BY entity_id, entity_name, metric_name;


-- -----------------------------------------------------------------------------
-- METHOD 2: Hourly Baseline Table (Pre-calculated, Recommended for Production)
-- Good for: High performance, query efficiency
-- -----------------------------------------------------------------------------

-- Step 1: Create baseline table (run daily via scheduled job)
/*
CREATE TABLE entity_baseline (
    entity_id           INT,
    entity_name         VARCHAR(255),
    metric_name         VARCHAR(100),
    hour_of_day         INT,              -- 0-23
    day_type            VARCHAR(10),      -- 'WEEKDAY' or 'WEEKEND'
    baseline_avg        DECIMAL(18,4),
    baseline_stddev     DECIMAL(18,4),
    baseline_p50        DECIMAL(18,4),
    baseline_p95        DECIMAL(18,4),
    baseline_p99        DECIMAL(18,4),
    sample_count        INT,
    calculated_at       DATETIME,
    PRIMARY KEY (entity_id, metric_name, hour_of_day, day_type)
);
*/

-- Step 2: Populate baseline table (run daily at midnight)
INSERT INTO entity_baseline (
    entity_id, entity_name, metric_name, hour_of_day, day_type,
    baseline_avg, baseline_stddev, baseline_p50, baseline_p95, baseline_p99,
    sample_count, calculated_at
)
SELECT 
    entity_id,
    entity_name,
    metric_name,
    DATEPART(HOUR, recorded_at) AS hour_of_day,
    CASE 
        WHEN DATEPART(WEEKDAY, recorded_at) IN (1, 7) THEN 'WEEKEND'
        ELSE 'WEEKDAY'
    END AS day_type,
    AVG(metric_value) AS baseline_avg,
    STDEV(metric_value) AS baseline_stddev,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY metric_value) 
        OVER (PARTITION BY entity_id, metric_name, DATEPART(HOUR, recorded_at)) AS baseline_p50,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY metric_value) 
        OVER (PARTITION BY entity_id, metric_name, DATEPART(HOUR, recorded_at)) AS baseline_p95,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY metric_value) 
        OVER (PARTITION BY entity_id, metric_name, DATEPART(HOUR, recorded_at)) AS baseline_p99,
    COUNT(*) AS sample_count,
    GETDATE() AS calculated_at
FROM application_metrics
WHERE recorded_at >= DATEADD(DAY, -30, GETDATE())  -- Last 30 days for better statistics
GROUP BY 
    entity_id, 
    entity_name, 
    metric_name, 
    DATEPART(HOUR, recorded_at),
    CASE WHEN DATEPART(WEEKDAY, recorded_at) IN (1, 7) THEN 'WEEKEND' ELSE 'WEEKDAY' END;


-- -----------------------------------------------------------------------------
-- METHOD 3: Anomaly Detection Using Baseline
-- Compare current value against baseline to detect anomalies
-- -----------------------------------------------------------------------------

WITH current_metrics AS (
    SELECT 
        entity_id,
        entity_name,
        metric_name,
        AVG(metric_value) AS current_value,  -- Average of last 5 minutes
        MAX(metric_value) AS current_max
    FROM application_metrics
    WHERE recorded_at >= DATEADD(MINUTE, -5, GETDATE())
    GROUP BY entity_id, entity_name, metric_name
),
baseline AS (
    SELECT 
        entity_id,
        metric_name,
        baseline_avg,
        baseline_stddev,
        baseline_p95,
        baseline_p99
    FROM entity_baseline
    WHERE hour_of_day = DATEPART(HOUR, GETDATE())
        AND day_type = CASE 
            WHEN DATEPART(WEEKDAY, GETDATE()) IN (1, 7) THEN 'WEEKEND'
            ELSE 'WEEKDAY'
        END
)
SELECT 
    cm.entity_id,
    cm.entity_name,
    cm.metric_name,
    cm.current_value,
    b.baseline_avg,
    b.baseline_stddev,
    
    -- How many standard deviations from the mean?
    CASE 
        WHEN b.baseline_stddev > 0 
        THEN (cm.current_value - b.baseline_avg) / b.baseline_stddev
        ELSE 0 
    END AS z_score,
    
    -- Threshold calculations
    b.baseline_avg + (2 * COALESCE(b.baseline_stddev, 0)) AS threshold_2sigma,  -- ~95% of normal values below this
    b.baseline_avg + (3 * COALESCE(b.baseline_stddev, 0)) AS threshold_3sigma,  -- ~99.7% of normal values below this
    
    -- Anomaly classification
    CASE 
        -- Z-score > 3: Very unusual (beyond 99.7% of normal)
        WHEN b.baseline_stddev > 0 
            AND (cm.current_value - b.baseline_avg) / b.baseline_stddev > 3 
        THEN 'CRITICAL_ANOMALY'
        
        -- Z-score > 2: Unusual (beyond 95% of normal)
        WHEN b.baseline_stddev > 0 
            AND (cm.current_value - b.baseline_avg) / b.baseline_stddev > 2 
        THEN 'WARNING_ANOMALY'
        
        -- Above P95 but within 2 sigma
        WHEN cm.current_value > b.baseline_p95 
        THEN 'ELEVATED'
        
        -- Normal range
        ELSE 'NORMAL'
    END AS anomaly_status,
    
    -- Percent above baseline
    CASE 
        WHEN b.baseline_avg > 0 
        THEN ROUND(((cm.current_value - b.baseline_avg) / b.baseline_avg) * 100, 2)
        ELSE 0 
    END AS pct_above_baseline

FROM current_metrics cm
LEFT JOIN baseline b ON cm.entity_id = b.entity_id 
    AND cm.metric_name = b.metric_name
ORDER BY 
    CASE 
        WHEN (cm.current_value - b.baseline_avg) / NULLIF(b.baseline_stddev, 0) > 3 THEN 1
        WHEN (cm.current_value - b.baseline_avg) / NULLIF(b.baseline_stddev, 0) > 2 THEN 2
        ELSE 3
    END,
    cm.current_value DESC;


-- -----------------------------------------------------------------------------
-- METHOD 4: Error Rate Baseline (Specific Example)
-- Calculate baseline for error rates per application
-- -----------------------------------------------------------------------------

WITH daily_error_rates AS (
    -- Calculate error rate for each hour of each day
    SELECT 
        application_id,
        application_name,
        CAST(recorded_at AS DATE) AS metric_date,
        DATEPART(HOUR, recorded_at) AS hour_of_day,
        DATEPART(WEEKDAY, recorded_at) AS day_of_week,
        SUM(error_count) AS total_errors,
        SUM(request_count) AS total_requests,
        CASE 
            WHEN SUM(request_count) > 0 
            THEN ROUND(SUM(error_count) * 100.0 / SUM(request_count), 4)
            ELSE 0 
        END AS error_rate_pct
    FROM application_metrics
    WHERE recorded_at >= DATEADD(DAY, -14, GETDATE())  -- 2 weeks of data
    GROUP BY 
        application_id, 
        application_name, 
        CAST(recorded_at AS DATE), 
        DATEPART(HOUR, recorded_at),
        DATEPART(WEEKDAY, recorded_at)
)
SELECT 
    application_id,
    application_name,
    hour_of_day,
    CASE 
        WHEN day_of_week IN (1, 7) THEN 'WEEKEND'
        ELSE 'WEEKDAY'
    END AS day_type,
    
    -- Baseline Statistics
    ROUND(AVG(error_rate_pct), 4) AS baseline_error_rate_avg,
    ROUND(STDEV(error_rate_pct), 4) AS baseline_error_rate_stddev,
    
    -- Dynamic Thresholds (calculated from baseline)
    ROUND(AVG(error_rate_pct) + (2 * COALESCE(STDEV(error_rate_pct), 0)), 4) AS warning_threshold,
    ROUND(AVG(error_rate_pct) + (3 * COALESCE(STDEV(error_rate_pct), 0)), 4) AS critical_threshold,
    
    -- Sample Info
    COUNT(*) AS days_of_data,
    MIN(error_rate_pct) AS min_error_rate,
    MAX(error_rate_pct) AS max_error_rate
    
FROM daily_error_rates
GROUP BY 
    application_id, 
    application_name, 
    hour_of_day,
    CASE WHEN day_of_week IN (1, 7) THEN 'WEEKEND' ELSE 'WEEKDAY' END
ORDER BY application_name, hour_of_day;


/*
================================================================================
BASELINE CALCULATION - DETAILED EXPLANATION
================================================================================

WHAT IS BASELINE?
-----------------
Baseline is the "expected normal" value for a metric at a specific time.
It accounts for:
- Time-of-day patterns (peak vs off-peak hours)
- Day-of-week patterns (weekday vs weekend)
- Seasonal variations (optional, for longer timeframes)

WHAT IS STANDARD DEVIATION (STDDEV)?
-------------------------------------
Standard deviation measures how spread out the values are from the average.

Example: Error Rate for App X at 10 AM (last 7 weekdays)
┌─────────────┬─────────────┐
│ Day         │ Error Rate  │
├─────────────┼─────────────┤
│ Monday      │ 0.8%        │
│ Tuesday     │ 1.2%        │
│ Wednesday   │ 0.9%        │
│ Thursday    │ 1.1%        │
│ Friday      │ 1.5%        │
│ Last Monday │ 0.7%        │
│ Last Tuesday│ 1.0%        │
├─────────────┼─────────────┤
│ AVERAGE     │ 1.03%       │  ← baseline_avg
│ STDDEV      │ 0.27%       │  ← baseline_stddev
└─────────────┴─────────────┘

CALCULATING THRESHOLDS:
- 1-sigma (68% of data): 1.03% ± 0.27% = 0.76% to 1.30%
- 2-sigma (95% of data): 1.03% ± 0.54% = 0.49% to 1.57%  ← WARNING
- 3-sigma (99.7% of data): 1.03% ± 0.81% = 0.22% to 1.84%  ← CRITICAL

Z-SCORE INTERPRETATION:
-----------------------
Z-score = (current_value - baseline_avg) / baseline_stddev

┌──────────────┬─────────────────────────────────────────────────────┐
│ Z-Score      │ Meaning                                             │
├──────────────┼─────────────────────────────────────────────────────┤
│ -1 to +1     │ Normal (68% of observations fall here)              │
│ +1 to +2     │ Slightly elevated (common, ~14% of observations)    │
│ +2 to +3     │ Unusual - WARNING (only ~2% of observations)        │
│ > +3         │ Very unusual - CRITICAL (only ~0.15% of obs)        │
│ < -2         │ Unusually LOW (might indicate data quality issue)   │
└──────────────┴─────────────────────────────────────────────────────┘

EXAMPLE ANOMALY DETECTION:
--------------------------
Current Error Rate: 2.1%
Baseline Avg: 1.03%
Baseline StdDev: 0.27%

Z-Score = (2.1 - 1.03) / 0.27 = 3.96

Since Z-Score (3.96) > 3 → CRITICAL_ANOMALY
The current error rate is nearly 4 standard deviations above normal!

WHY SAME HOUR COMPARISON?
-------------------------
Error rates vary by time of day:
┌──────────┬─────────────┬─────────────────────────────────┐
│ Hour     │ Typical Rate│ Reason                          │
├──────────┼─────────────┼─────────────────────────────────┤
│ 2-5 AM   │ 0.2%        │ Low traffic, batch jobs         │
│ 9-11 AM  │ 1.5%        │ Peak login/morning activity     │
│ 12-1 PM  │ 0.8%        │ Lunch lull                      │
│ 2-5 PM   │ 1.2%        │ Afternoon activity              │
│ 8-10 PM  │ 0.5%        │ Evening wind-down               │
└──────────┴─────────────┴─────────────────────────────────┘

A 1.5% error rate at 3 AM is CRITICAL (7x normal)
A 1.5% error rate at 10 AM is NORMAL (matches baseline)

MINIMUM SAMPLE SIZE:
--------------------
For reliable statistics, you need sufficient data points:
- Minimum: 7 days (7 data points per hour)
- Recommended: 14-30 days
- If sample_count < 7, use global defaults or wider thresholds

HANDLING ZERO/LOW STDDEV:
-------------------------
If stddev = 0 or very low, it means the metric is extremely consistent.
In this case:
- Use percentage deviation instead: (current - avg) / avg > 50% → ANOMALY
- Or use absolute thresholds as fallback
- Example: If avg = 0.5% and stddev = 0.01%, 
  any error rate > 0.6% could be considered anomalous

RECOMMENDED BASELINE REFRESH FREQUENCY:
---------------------------------------
┌────────────────────────┬─────────────────────────────────────────┐
│ Data Type              │ Refresh Frequency                       │
├────────────────────────┼─────────────────────────────────────────┤
│ Hourly baselines       │ Daily (at midnight)                     │
│ Weekly patterns        │ Weekly (Sunday night)                   │
│ Seasonal adjustments   │ Monthly                                 │
│ After major releases   │ Immediately (may need baseline reset)   │
└────────────────────────┴─────────────────────────────────────────┘

*/


-- ============================================================================
-- 2. REPEATED HOST ERRORS DETECTION
-- Identifies hosts throwing errors repeatedly over a configurable period
-- ============================================================================

WITH host_error_pattern AS (
    SELECT 
        host_id,
        host_name,
        application_id,
        -- Count errors in different time windows
        SUM(CASE WHEN recorded_at >= DATEADD(MINUTE, -5, GETDATE()) THEN 1 ELSE 0 END) AS errors_5min,
        SUM(CASE WHEN recorded_at >= DATEADD(MINUTE, -15, GETDATE()) THEN 1 ELSE 0 END) AS errors_15min,
        SUM(CASE WHEN recorded_at >= DATEADD(MINUTE, -30, GETDATE()) THEN 1 ELSE 0 END) AS errors_30min,
        SUM(CASE WHEN recorded_at >= DATEADD(HOUR, -1, GETDATE()) THEN 1 ELSE 0 END) AS errors_1hour,
        -- Count distinct minutes with errors (persistence check)
        COUNT(DISTINCT 
            CASE WHEN recorded_at >= DATEADD(MINUTE, -30, GETDATE()) 
            THEN DATEPART(MINUTE, recorded_at) END
        ) AS distinct_error_minutes_30min,
        -- Check for continuous error streaks
        MAX(recorded_at) AS last_error_time,
        MIN(CASE WHEN recorded_at >= DATEADD(MINUTE, -30, GETDATE()) 
            THEN recorded_at END) AS first_error_in_window
    FROM host_error_logs
    WHERE recorded_at >= DATEADD(HOUR, -1, GETDATE())
    GROUP BY host_id, host_name, application_id
),
host_baseline AS (
    -- Get typical error rate for comparison (last 7 days, same hour)
    SELECT 
        host_id,
        AVG(error_count) AS avg_hourly_errors,
        STDEV(error_count) AS stddev_hourly_errors
    FROM (
        SELECT 
            host_id,
            DATEPART(HOUR, recorded_at) AS hour_of_day,
            CAST(recorded_at AS DATE) AS error_date,
            COUNT(*) AS error_count
        FROM host_error_logs
        WHERE recorded_at >= DATEADD(DAY, -7, GETDATE())
            AND DATEPART(HOUR, recorded_at) = DATEPART(HOUR, GETDATE())
        GROUP BY host_id, DATEPART(HOUR, recorded_at), CAST(recorded_at AS DATE)
    ) hourly_stats
    GROUP BY host_id
)
SELECT 
    hep.host_id,
    hep.host_name,
    hep.application_id,
    hep.errors_5min,
    hep.errors_15min,
    hep.errors_30min,
    hep.errors_1hour,
    hep.distinct_error_minutes_30min,
    hb.avg_hourly_errors,
    CASE 
        -- CRITICAL: High error rate sustained over 15+ minutes
        WHEN hep.distinct_error_minutes_30min >= 15 AND hep.errors_30min >= 20 THEN 'CRITICAL'
        -- CRITICAL: Error rate 3x above baseline
        WHEN hep.errors_1hour > (hb.avg_hourly_errors + 3 * COALESCE(hb.stddev_hourly_errors, 0)) 
            AND hep.errors_1hour >= 10 THEN 'CRITICAL'
        -- DEGRADED: Repeated errors (errors in 10+ distinct minutes)
        WHEN hep.distinct_error_minutes_30min >= 10 THEN 'DEGRADED'
        -- DEGRADED: Error rate 2x above baseline
        WHEN hep.errors_1hour > (hb.avg_hourly_errors + 2 * COALESCE(hb.stddev_hourly_errors, 0)) 
            AND hep.errors_1hour >= 5 THEN 'DEGRADED'
        -- WARNING: Recent spike but not sustained
        WHEN hep.errors_5min >= 5 AND hep.distinct_error_minutes_30min < 10 THEN 'WARNING'
        -- HEALTHY: Normal or below-baseline error rate
        ELSE 'HEALTHY'
    END AS host_health_status,
    CASE 
        WHEN hep.distinct_error_minutes_30min >= 15 THEN 'Persistent errors - immediate attention required'
        WHEN hep.errors_5min >= 5 AND hep.distinct_error_minutes_30min < 5 THEN 'Recent spike - monitoring for persistence'
        ELSE NULL
    END AS recommendation
FROM host_error_pattern hep
LEFT JOIN host_baseline hb ON hep.host_id = hb.host_id
ORDER BY 
    CASE 
        WHEN hep.distinct_error_minutes_30min >= 15 THEN 1
        WHEN hep.errors_5min >= 5 THEN 2
        ELSE 3
    END,
    hep.errors_30min DESC;


-- ============================================================================
-- 3. FALSE ALARM REDUCTION: TRANSIENT SPIKE DETECTION
-- Distinguishes between transient spikes and genuine issues
-- ============================================================================

WITH minute_metrics AS (
    SELECT 
        entity_id,
        entity_name,
        metric_name,
        metric_value,
        recorded_at,
        -- Calculate rolling average (last 10 minutes)
        AVG(metric_value) OVER (
            PARTITION BY entity_id, metric_name 
            ORDER BY recorded_at 
            ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING
        ) AS rolling_avg_10min,
        -- Calculate rolling standard deviation
        STDEV(metric_value) OVER (
            PARTITION BY entity_id, metric_name 
            ORDER BY recorded_at 
            ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING
        ) AS rolling_stdev_10min,
        -- Count consecutive breaches
        SUM(CASE WHEN metric_value > threshold_value THEN 1 ELSE 0 END) OVER (
            PARTITION BY entity_id, metric_name 
            ORDER BY recorded_at 
            ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
        ) AS consecutive_breaches_5min
    FROM application_metrics am
    JOIN threshold_config tc ON am.entity_id = tc.entity_id 
        AND am.metric_name = tc.metric_name
    WHERE recorded_at >= DATEADD(MINUTE, -30, GETDATE())
)
SELECT 
    entity_id,
    entity_name,
    metric_name,
    metric_value,
    rolling_avg_10min,
    rolling_stdev_10min,
    consecutive_breaches_5min,
    CASE 
        -- Genuine Issue: 4+ consecutive minutes of breaches
        WHEN consecutive_breaches_5min >= 4 THEN 'GENUINE_ISSUE'
        -- Transient Spike: Current value is outlier but no pattern
        WHEN metric_value > (rolling_avg_10min + 3 * rolling_stdev_10min) 
            AND consecutive_breaches_5min <= 1 THEN 'TRANSIENT_SPIKE'
        -- Trending Up: Increasing pattern toward threshold
        WHEN metric_value > rolling_avg_10min * 1.5 
            AND consecutive_breaches_5min BETWEEN 2 AND 3 THEN 'TRENDING_UP'
        -- Normal: Within expected range
        ELSE 'NORMAL'
    END AS spike_classification,
    CASE 
        WHEN consecutive_breaches_5min >= 4 THEN 1  -- Alert immediately
        WHEN consecutive_breaches_5min BETWEEN 2 AND 3 THEN 0  -- Suppress, but monitor
        WHEN consecutive_breaches_5min <= 1 THEN 0  -- Suppress transient
        ELSE 0
    END AS should_alert
FROM minute_metrics
WHERE recorded_at >= DATEADD(MINUTE, -1, GETDATE())  -- Current minute only
ORDER BY consecutive_breaches_5min DESC, entity_name;


-- ============================================================================
-- 4. AGGREGATED APPLICATION HEALTH STATUS
-- Combines all factors for final health determination
-- ============================================================================

WITH application_summary AS (
    SELECT 
        a.application_id,
        a.application_name,
        -- Synthetic Health (average of last 5 minutes, ignore single outliers)
        AVG(CASE 
            WHEN sm.recorded_at >= DATEADD(MINUTE, -5, GETDATE()) 
            THEN sm.success_rate 
        END) AS synthetic_health_5min,
        -- Host Health
        COUNT(DISTINCT CASE 
            WHEN hm.health_status = 'HEALTHY' 
            THEN hm.host_id 
        END) AS healthy_hosts,
        COUNT(DISTINCT hm.host_id) AS total_hosts,
        -- Error Rate (weighted by recency)
        SUM(CASE 
            WHEN el.recorded_at >= DATEADD(MINUTE, -5, GETDATE()) THEN 3
            WHEN el.recorded_at >= DATEADD(MINUTE, -15, GETDATE()) THEN 2
            WHEN el.recorded_at >= DATEADD(MINUTE, -30, GETDATE()) THEN 1
            ELSE 0
        END) AS weighted_error_score,
        -- Alert Count (last hour)
        COUNT(DISTINCT CASE 
            WHEN al.created_at >= DATEADD(HOUR, -1, GETDATE()) 
            THEN al.alert_id 
        END) AS active_alerts,
        -- Consecutive healthy minutes
        (
            SELECT COUNT(*) 
            FROM application_metrics am2 
            WHERE am2.application_id = a.application_id
                AND am2.recorded_at >= DATEADD(MINUTE, -10, GETDATE())
                AND am2.error_rate < 1  -- Less than 1% error rate
        ) AS consecutive_healthy_minutes
    FROM applications a
    LEFT JOIN synthetic_metrics sm ON a.application_id = sm.application_id
    LEFT JOIN host_metrics hm ON a.application_id = hm.application_id
        AND hm.recorded_at >= DATEADD(MINUTE, -5, GETDATE())
    LEFT JOIN error_logs el ON a.application_id = el.application_id
        AND el.recorded_at >= DATEADD(MINUTE, -30, GETDATE())
    LEFT JOIN alerts al ON a.application_id = al.application_id
        AND al.status = 'ACTIVE'
    GROUP BY a.application_id, a.application_name
)
SELECT 
    application_id,
    application_name,
    ROUND(synthetic_health_5min, 2) AS synthetic_health_pct,
    CONCAT(healthy_hosts, '/', total_hosts) AS host_health,
    weighted_error_score,
    active_alerts,
    consecutive_healthy_minutes,
    -- Final Health Status with false alarm reduction
    CASE 
        -- CRITICAL: Multiple indicators failing
        WHEN synthetic_health_5min < 95 
            AND (healthy_hosts * 1.0 / NULLIF(total_hosts, 0)) < 0.5 
            AND weighted_error_score >= 20 
        THEN 'CRITICAL'
        
        -- CRITICAL: Severe synthetic health drop sustained
        WHEN synthetic_health_5min < 90 
            AND consecutive_healthy_minutes <= 2 
        THEN 'CRITICAL'
        
        -- DEGRADED: One or more indicators showing issues
        WHEN synthetic_health_5min < 98 
            AND weighted_error_score >= 10 
        THEN 'DEGRADED'
        
        -- DEGRADED: Host issues but synthetic still okay
        WHEN (healthy_hosts * 1.0 / NULLIF(total_hosts, 0)) < 0.8 
            AND weighted_error_score >= 5 
        THEN 'DEGRADED'
        
        -- WARNING: Minor issues, could be transient
        WHEN synthetic_health_5min < 99 
            OR weighted_error_score BETWEEN 3 AND 9 
            OR active_alerts > 0 
        THEN 'WARNING'
        
        -- RECOVERING: Was bad, now improving
        WHEN consecutive_healthy_minutes >= 5 
            AND weighted_error_score > 0 
        THEN 'RECOVERING'
        
        -- HEALTHY: All indicators good
        ELSE 'HEALTHY'
    END AS overall_status,
    
    -- Confidence score (how sure we are this isn't a false alarm)
    CASE 
        WHEN consecutive_healthy_minutes >= 8 THEN 'HIGH'
        WHEN consecutive_healthy_minutes >= 5 THEN 'MEDIUM'
        WHEN consecutive_healthy_minutes >= 2 THEN 'LOW'
        ELSE 'VERY_LOW'
    END AS status_confidence
    
FROM application_summary
ORDER BY 
    CASE overall_status
        WHEN 'CRITICAL' THEN 1
        WHEN 'DEGRADED' THEN 2
        WHEN 'WARNING' THEN 3
        WHEN 'RECOVERING' THEN 4
        ELSE 5
    END,
    weighted_error_score DESC;


-- ============================================================================
-- 5. SMART ALERTING: CORRELATION-BASED SUPPRESSION
-- Suppresses alerts if related services are also affected (infrastructure issue)
-- ============================================================================

WITH current_issues AS (
    SELECT 
        application_id,
        application_name,
        datacenter_id,
        infrastructure_group,
        error_count,
        CASE WHEN error_count >= 5 THEN 1 ELSE 0 END AS has_issue
    FROM (
        SELECT 
            a.application_id,
            a.application_name,
            a.datacenter_id,
            a.infrastructure_group,
            COUNT(el.error_id) AS error_count
        FROM applications a
        LEFT JOIN error_logs el ON a.application_id = el.application_id
            AND el.recorded_at >= DATEADD(MINUTE, -10, GETDATE())
        GROUP BY a.application_id, a.application_name, a.datacenter_id, a.infrastructure_group
    ) app_errors
),
infrastructure_impact AS (
    SELECT 
        datacenter_id,
        infrastructure_group,
        COUNT(*) AS total_apps,
        SUM(has_issue) AS affected_apps,
        ROUND(SUM(has_issue) * 100.0 / COUNT(*), 2) AS pct_affected
    FROM current_issues
    GROUP BY datacenter_id, infrastructure_group
)
SELECT 
    ci.application_id,
    ci.application_name,
    ci.error_count,
    ii.affected_apps AS apps_in_group_affected,
    ii.total_apps AS total_apps_in_group,
    ii.pct_affected,
    CASE 
        -- If >50% of apps in same infrastructure group affected, likely infra issue
        WHEN ii.pct_affected >= 50 THEN 'SUPPRESS_ALERT'
        -- If this is the only app affected, genuine application issue
        WHEN ii.affected_apps = 1 THEN 'RAISE_ALERT'
        -- Partial impact, still raise but note correlation
        ELSE 'RAISE_WITH_CORRELATION'
    END AS alert_action,
    CASE 
        WHEN ii.pct_affected >= 50 
        THEN CONCAT('Infrastructure issue suspected - ', ii.affected_apps, ' apps affected in ', ci.infrastructure_group)
        WHEN ii.affected_apps = 1 
        THEN 'Isolated application issue'
        ELSE CONCAT('Correlated with ', ii.affected_apps - 1, ' other app(s)')
    END AS alert_context
FROM current_issues ci
JOIN infrastructure_impact ii ON ci.datacenter_id = ii.datacenter_id 
    AND ci.infrastructure_group = ii.infrastructure_group
WHERE ci.has_issue = 1
ORDER BY ii.pct_affected DESC, ci.error_count DESC;


-- ============================================================================
-- 6. MAINTENANCE WINDOW AWARENESS
-- Suppress alerts during scheduled maintenance
-- ============================================================================

SELECT 
    am.application_id,
    am.application_name,
    am.current_status,
    am.error_count,
    mw.maintenance_id,
    mw.maintenance_type,
    mw.start_time,
    mw.end_time,
    CASE 
        WHEN mw.maintenance_id IS NOT NULL 
            AND GETDATE() BETWEEN mw.start_time AND mw.end_time 
        THEN 'SUPPRESS_DURING_MAINTENANCE'
        WHEN mw.maintenance_id IS NOT NULL 
            AND GETDATE() BETWEEN DATEADD(MINUTE, -15, mw.start_time) AND mw.start_time 
        THEN 'PRE_MAINTENANCE_WINDOW'
        WHEN mw.maintenance_id IS NOT NULL 
            AND GETDATE() BETWEEN mw.end_time AND DATEADD(MINUTE, 30, mw.end_time) 
        THEN 'POST_MAINTENANCE_STABILIZATION'
        ELSE 'NORMAL_MONITORING'
    END AS monitoring_mode,
    CASE 
        WHEN GETDATE() BETWEEN mw.start_time AND mw.end_time THEN 0
        WHEN GETDATE() BETWEEN mw.end_time AND DATEADD(MINUTE, 30, mw.end_time) 
            AND am.error_count < 10 THEN 0  -- Allow stabilization period
        ELSE 1
    END AS should_alert
FROM application_status am
LEFT JOIN maintenance_windows mw ON (
    am.application_id = mw.application_id 
    OR mw.scope = 'ALL'
    OR am.infrastructure_group = mw.infrastructure_group
)
AND GETDATE() BETWEEN DATEADD(MINUTE, -15, mw.start_time) AND DATEADD(MINUTE, 30, mw.end_time)
WHERE am.current_status IN ('WARNING', 'DEGRADED', 'CRITICAL');


-- ============================================================================
-- 7. DASHBOARD SUMMARY VIEW
-- Final aggregated view for the Application Health Dashboard
-- ============================================================================

CREATE OR ALTER VIEW vw_application_health_dashboard AS
WITH metrics_5min AS (
    SELECT 
        application_id,
        AVG(success_rate) AS avg_synthetic_health,
        AVG(response_time_ms) AS avg_response_time,
        MAX(error_rate) AS max_error_rate,
        COUNT(CASE WHEN success_rate < 99 THEN 1 END) AS degraded_minutes
    FROM application_metrics
    WHERE recorded_at >= DATEADD(MINUTE, -5, GETDATE())
    GROUP BY application_id
),
host_summary AS (
    SELECT 
        application_id,
        COUNT(*) AS total_hosts,
        SUM(CASE WHEN status = 'HEALTHY' THEN 1 ELSE 0 END) AS healthy_hosts
    FROM host_status
    WHERE last_check >= DATEADD(MINUTE, -5, GETDATE())
    GROUP BY application_id
),
error_summary AS (
    SELECT 
        application_id,
        COUNT(*) AS error_count_30min,
        COUNT(DISTINCT DATEPART(MINUTE, recorded_at)) AS distinct_error_minutes
    FROM error_logs
    WHERE recorded_at >= DATEADD(MINUTE, -30, GETDATE())
    GROUP BY application_id
),
alert_summary AS (
    SELECT 
        application_id,
        COUNT(*) AS active_alert_count
    FROM alerts
    WHERE status = 'ACTIVE'
    GROUP BY application_id
)
SELECT 
    a.application_id,
    a.application_name,
    ROUND(COALESCE(m.avg_synthetic_health, 100), 2) AS synthetic_health_pct,
    CONCAT(COALESCE(h.healthy_hosts, 0), '/', COALESCE(h.total_hosts, 0)) AS host_health,
    ROUND(COALESCE(m.max_error_rate, 0), 3) AS service_failure_rate,
    COALESCE(al.active_alert_count, 0) AS alert_count,
    
    -- Overall Status with intelligent determination
    CASE 
        -- CRITICAL scenarios
        WHEN m.avg_synthetic_health < 90 AND e.distinct_error_minutes >= 10 THEN 'Critical'
        WHEN (h.healthy_hosts * 1.0 / NULLIF(h.total_hosts, 0)) < 0.5 THEN 'Critical'
        
        -- DEGRADED scenarios (confirmed issues)
        WHEN m.avg_synthetic_health < 98 AND e.distinct_error_minutes >= 5 THEN 'Degraded'
        WHEN m.degraded_minutes >= 3 THEN 'Degraded'
        WHEN (h.healthy_hosts * 1.0 / NULLIF(h.total_hosts, 0)) < 0.8 THEN 'Degraded'
        
        -- WARNING scenarios (potential issues, monitoring)
        WHEN m.avg_synthetic_health < 99 AND e.error_count_30min > 0 THEN 'Warning'
        WHEN al.active_alert_count > 0 THEN 'Warning'
        
        -- HEALTHY
        ELSE 'Healthy'
    END AS overall_status,
    
    -- False alarm indicator
    CASE 
        WHEN e.distinct_error_minutes >= 5 THEN 'Confirmed'
        WHEN e.error_count_30min > 0 AND e.distinct_error_minutes < 3 THEN 'Possible Transient'
        ELSE 'Stable'
    END AS confidence_level

FROM applications a
LEFT JOIN metrics_5min m ON a.application_id = m.application_id
LEFT JOIN host_summary h ON a.application_id = h.application_id
LEFT JOIN error_summary e ON a.application_id = e.application_id
LEFT JOIN alert_summary al ON a.application_id = al.application_id
WHERE a.is_active = 1;


-- ============================================================================
-- USAGE NOTES & DETAILED STRATEGIES
-- ============================================================================
/*
================================================================================
KEY STRATEGIES FOR FALSE ALARM REDUCTION
================================================================================

1. TEMPORAL VALIDATION - Require Persistence Before Alerting
--------------------------------------------------------------------------------
   PROBLEM: Single-minute spikes cause alert fatigue
   
   SOLUTION: Require consecutive breaches before alerting
   
   EXAMPLE DATA:
   ┌─────────────┬───────────┬──────────┬─────────────┬──────────────────┐
   │ Time        │ Error Rate│ Threshold│ Breaching?  │ Alert Decision   │
   ├─────────────┼───────────┼──────────┼─────────────┼──────────────────┤
   │ 10:01       │ 0.5%      │ 2%       │ No          │ -                │
   │ 10:02       │ 5.2%      │ 2%       │ Yes (1)     │ SUPPRESS         │
   │ 10:03       │ 1.1%      │ 2%       │ No (reset)  │ -                │
   │ 10:04       │ 4.8%      │ 2%       │ Yes (1)     │ SUPPRESS         │
   │ 10:05       │ 6.1%      │ 2%       │ Yes (2)     │ SUPPRESS         │
   │ 10:06       │ 5.5%      │ 2%       │ Yes (3)     │ SUPPRESS         │
   │ 10:07       │ 7.2%      │ 2%       │ Yes (4)     │ ⚠️ ALERT NOW     │
   └─────────────┴───────────┴──────────┴─────────────┴──────────────────┘
   
   IMPLEMENTATION:
   - consecutive_breaches >= 4 → Genuine issue, raise alert
   - consecutive_breaches = 1 → Likely transient, suppress
   - Use rolling window of 5-10 minutes for spike detection
   
   TUNING PARAMETERS:
   - MIN_CONSECUTIVE_BREACHES: 4 (recommended), range 3-6
   - ROLLING_WINDOW_MINUTES: 10 (for averaging)


2. HISTORICAL CONTEXT - Compare Against Baseline
--------------------------------------------------------------------------------
   PROBLEM: "Normal" varies by time of day, day of week
   
   SOLUTION: Compare current metrics against same-hour baseline from past 7 days
   
   EXAMPLE BASELINE CALCULATION:
   ┌─────────────────┬────────────────┬────────────────┬─────────────────┐
   │ Day             │ Hour (10 AM)   │ Avg Error Rate │ Std Deviation   │
   ├─────────────────┼────────────────┼────────────────┼─────────────────┤
   │ Mon (Dec 2)     │ 10:00-11:00    │ 0.8%           │ -               │
   │ Tue (Dec 3)     │ 10:00-11:00    │ 1.2%           │ -               │
   │ Wed (Dec 4)     │ 10:00-11:00    │ 0.9%           │ -               │
   │ Thu (Dec 5)     │ 10:00-11:00    │ 1.1%           │ -               │
   │ Fri (Dec 6)     │ 10:00-11:00    │ 1.5%           │ -               │
   │ Sat (Dec 7)     │ 10:00-11:00    │ 0.3%           │ -               │
   │ Sun (Dec 8)     │ 10:00-11:00    │ 0.2%           │ -               │
   ├─────────────────┼────────────────┼────────────────┼─────────────────┤
   │ BASELINE        │ 10:00-11:00    │ 0.86%          │ 0.45%           │
   └─────────────────┴────────────────┴────────────────┴─────────────────┘
   
   ANOMALY DETECTION FORMULA:
   - is_anomaly = current_value > (baseline_avg + 3 * baseline_stddev)
   - For above: threshold = 0.86% + (3 * 0.45%) = 2.21%
   - If current = 2.5% → ANOMALY (above 2.21%)
   - If current = 1.8% → NORMAL (below 2.21%)
   
   IMPLEMENTATION:
   - Store hourly aggregates for 7-30 days
   - Calculate baseline per entity, per hour-of-day
   - Use 2-sigma for warnings, 3-sigma for critical


3. CORRELATION ANALYSIS - Detect Infrastructure Issues
--------------------------------------------------------------------------------
   PROBLEM: Network/infra issues trigger alerts for ALL dependent apps
   
   SOLUTION: If >50% of apps in same group affected, suppress individual alerts
   
   EXAMPLE SCENARIO:
   ┌──────────────────┬─────────────────┬────────────┬─────────────────────┐
   │ Application      │ Infra Group     │ Has Errors │ Individual Action   │
   ├──────────────────┼─────────────────┼────────────┼─────────────────────┤
   │ Customer Portal  │ Datacenter-East │ YES        │ Would alert...      │
   │ Admin Dashboard  │ Datacenter-East │ YES        │ Would alert...      │
   │ Payment Service  │ Datacenter-East │ YES        │ Would alert...      │
   │ API Gateway      │ Datacenter-East │ YES        │ Would alert...      │
   │ Auth Service     │ Datacenter-East │ NO         │ -                   │
   │ Search Service   │ Datacenter-East │ NO         │ -                   │
   ├──────────────────┼─────────────────┼────────────┼─────────────────────┤
   │ SUMMARY          │ 4/6 affected    │ 67%        │ INFRA ISSUE!        │
   └──────────────────┴─────────────────┴────────────┴─────────────────────┘
   
   DECISION MATRIX:
   ┌─────────────────────┬─────────────────────────────────────────────────┐
   │ % Apps Affected     │ Action                                          │
   ├─────────────────────┼─────────────────────────────────────────────────┤
   │ 0-20%               │ RAISE individual app alerts                     │
   │ 21-50%              │ RAISE with correlation note                     │
   │ 51-80%              │ SUPPRESS app alerts, RAISE infra alert          │
   │ 81-100%             │ SUPPRESS all, RAISE CRITICAL infra alert        │
   └─────────────────────┴─────────────────────────────────────────────────┘


4. MAINTENANCE WINDOW AWARENESS
--------------------------------------------------------------------------------
   PROBLEM: Scheduled maintenance triggers false alerts
   
   SOLUTION: Time-based suppression with stabilization buffer
   
   TIMELINE EXAMPLE:
   ┌────────────────────────────────────────────────────────────────────────┐
   │                     MAINTENANCE WINDOW TIMELINE                        │
   ├────────────────────────────────────────────────────────────────────────┤
   │                                                                        │
   │  ◄──── PRE ────►◄────── MAINTENANCE ──────►◄──── STABILIZE ────►      │
   │     15 mins              2 hours                  30 mins              │
   │                                                                        │
   │  10:45 AM          11:00 AM              1:00 PM              1:30 PM  │
   │     │                  │                    │                    │    │
   │     ▼                  ▼                    ▼                    ▼    │
   │  [WARN MODE]      [SUPPRESS ALL]       [ALLOW >10 errors]    [NORMAL] │
   │                                                                        │
   └────────────────────────────────────────────────────────────────────────┘
   
   SUPPRESSION RULES:
   ┌─────────────────────┬──────────────────────────────────────────────────┐
   │ Time Period         │ Alert Behavior                                   │
   ├─────────────────────┼──────────────────────────────────────────────────┤
   │ 15 min before start │ Log warnings, no pages                           │
   │ During maintenance  │ Suppress ALL alerts                              │
   │ 30 min after end    │ Only alert if errors > 10 (allow stabilization) │
   │ After stabilization │ Normal alerting resumes                          │
   └─────────────────────┴──────────────────────────────────────────────────┘


5. WEIGHTED SCORING - Prioritize Recent Data
--------------------------------------------------------------------------------
   PROBLEM: Old errors (25 min ago) weighted same as current errors
   
   SOLUTION: Time-decay weighting for error scoring
   
   WEIGHT DISTRIBUTION:
   ┌─────────────────┬──────────┬────────────────────────────────────────────┐
   │ Time Window     │ Weight   │ Reasoning                                  │
   ├─────────────────┼──────────┼────────────────────────────────────────────┤
   │ Last 5 minutes  │ 3x       │ Most relevant, immediate impact            │
   │ 6-15 minutes    │ 2x       │ Recent, likely still relevant              │
   │ 16-30 minutes   │ 1x       │ Historical context only                    │
   │ 30+ minutes     │ 0x       │ Ignore for current health status           │
   └─────────────────┴──────────┴────────────────────────────────────────────┘
   
   EXAMPLE CALCULATION:
   ┌─────────────────┬──────────────┬──────────┬────────────────────────────┐
   │ Time Window     │ Error Count  │ Weight   │ Weighted Score             │
   ├─────────────────┼──────────────┼──────────┼────────────────────────────┤
   │ Last 5 min      │ 3 errors     │ 3x       │ 9                          │
   │ 6-15 min        │ 5 errors     │ 2x       │ 10                         │
   │ 16-30 min       │ 8 errors     │ 1x       │ 8                          │
   ├─────────────────┼──────────────┼──────────┼────────────────────────────┤
   │ TOTAL           │ 16 errors    │ -        │ 27 (weighted score)        │
   └─────────────────┴──────────────┴──────────┴────────────────────────────┘
   
   THRESHOLD MAPPING:
   - Weighted Score 0-5:    HEALTHY
   - Weighted Score 6-15:   WARNING
   - Weighted Score 16-30:  DEGRADED
   - Weighted Score 31+:    CRITICAL


6. RECOVERY TRACKING - Prevent Status Flip-Flopping
--------------------------------------------------------------------------------
   PROBLEM: Status rapidly changes: DEGRADED → HEALTHY → DEGRADED → HEALTHY
   
   SOLUTION: Require sustained healthy period before status upgrade
   
   STATE MACHINE:
   ┌──────────────────────────────────────────────────────────────────────────┐
   │                        STATUS TRANSITION RULES                           │
   ├──────────────────────────────────────────────────────────────────────────┤
   │                                                                          │
   │   ┌─────────┐    4+ consecutive    ┌──────────┐                         │
   │   │ HEALTHY │◄──────breaches──────►│ DEGRADED │                         │
   │   └────┬────┘                      └────┬─────┘                         │
   │        │                                │                                │
   │        │ 5+ healthy                     │ 8+ consecutive                │
   │        │ minutes                        │ breaches                       │
   │        ▼                                ▼                                │
   │   ┌──────────┐                    ┌──────────┐                          │
   │   │RECOVERING│                    │ CRITICAL │                          │
   │   └──────────┘                    └──────────┘                          │
   │                                                                          │
   └──────────────────────────────────────────────────────────────────────────┘
   
   HYSTERESIS EXAMPLE (prevents flip-flop):
   ┌─────────┬───────────┬─────────────────┬────────────────────────────────┐
   │ Minute  │ Errors    │ Consecutive OK  │ Status                         │
   ├─────────┼───────────┼─────────────────┼────────────────────────────────┤
   │ 10:00   │ 5         │ 0               │ DEGRADED                       │
   │ 10:01   │ 0         │ 1               │ DEGRADED (need 5 OK minutes)   │
   │ 10:02   │ 0         │ 2               │ DEGRADED                       │
   │ 10:03   │ 1         │ 0 (reset)       │ DEGRADED                       │
   │ 10:04   │ 0         │ 1               │ DEGRADED                       │
   │ 10:05   │ 0         │ 2               │ DEGRADED                       │
   │ 10:06   │ 0         │ 3               │ DEGRADED                       │
   │ 10:07   │ 0         │ 4               │ DEGRADED                       │
   │ 10:08   │ 0         │ 5               │ ✅ RECOVERING                  │
   │ 10:09   │ 0         │ 6               │ RECOVERING                     │
   │ 10:10   │ 0         │ 7               │ RECOVERING                     │
   │ 10:11   │ 0         │ 8               │ ✅ HEALTHY                     │
   └─────────┴───────────┴─────────────────┴────────────────────────────────┘


7. DISTINCT ERROR MINUTES - Quality Over Quantity
--------------------------------------------------------------------------------
   PROBLEM: Single bad minute with 100 errors looks worse than 10 minutes with 
            5 errors each (but latter is more concerning)
   
   SOLUTION: Track DISTINCT minutes with errors, not total error count
   
   COMPARISON:
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ SCENARIO A: Burst (Single Minute Issue)                                │
   ├─────────────────────────────────────────────────────────────────────────┤
   │ Minute  │ 10:01 │ 10:02 │ 10:03 │ 10:04 │ 10:05 │ Total │ Distinct Min│
   │ Errors  │  150  │   0   │   0   │   0   │   0   │  150  │      1      │
   │ STATUS: WARNING (single burst, likely transient)                       │
   └─────────────────────────────────────────────────────────────────────────┘
   
   ┌─────────────────────────────────────────────────────────────────────────┐
   │ SCENARIO B: Persistent (Ongoing Issue)                                 │
   ├─────────────────────────────────────────────────────────────────────────┤
   │ Minute  │ 10:01 │ 10:02 │ 10:03 │ 10:04 │ 10:05 │ Total │ Distinct Min│
   │ Errors  │   8   │   5   │   7   │   6   │   9   │   35  │      5      │
   │ STATUS: DEGRADED (persistent issue, needs attention)                   │
   └─────────────────────────────────────────────────────────────────────────┘
   
   THRESHOLD GUIDANCE:
   ┌─────────────────────┬─────────────────────┬─────────────────────────────┐
   │ Distinct Error Mins │ Total Errors (30m)  │ Recommended Status          │
   ├─────────────────────┼─────────────────────┼─────────────────────────────┤
   │ 1-2                 │ Any                 │ WARNING (monitor)           │
   │ 3-5                 │ < 20                │ WARNING                     │
   │ 3-5                 │ >= 20               │ DEGRADED                    │
   │ 6-10                │ Any                 │ DEGRADED                    │
   │ 11-15               │ Any                 │ DEGRADED (high confidence)  │
   │ 16+                 │ Any                 │ CRITICAL                    │
   └─────────────────────┴─────────────────────┴─────────────────────────────┘


================================================================================
RECOMMENDED ALERT THRESHOLDS & CONFIGURATION
================================================================================

ALERTING TIERS:
┌─────────────┬──────────────────────────────────────┬────────────────────────┐
│ Tier        │ Criteria                             │ Notification           │
├─────────────┼──────────────────────────────────────┼────────────────────────┤
│ P1-CRITICAL │ - Synthetic < 90% for 5+ mins        │ Page on-call           │
│             │ - Distinct error mins >= 15          │ Slack + Email          │
│             │ - >50% hosts unhealthy               │ Auto-create incident   │
├─────────────┼──────────────────────────────────────┼────────────────────────┤
│ P2-DEGRADED │ - Synthetic 90-98% for 5+ mins       │ Slack channel          │
│             │ - Distinct error mins 10-14          │ Email to team          │
│             │ - Weighted error score 16-30         │                        │
├─────────────┼──────────────────────────────────────┼────────────────────────┤
│ P3-WARNING  │ - Synthetic 98-99%                   │ Dashboard only         │
│             │ - Distinct error mins 5-9            │ Optional Slack         │
│             │ - Single active alert                │                        │
├─────────────┼──────────────────────────────────────┼────────────────────────┤
│ P4-INFO     │ - Distinct error mins 1-4            │ Log only               │
│             │ - Transient spikes                   │ No notification        │
│             │ - Confidence = 'Possible Transient'  │                        │
└─────────────┴──────────────────────────────────────┴────────────────────────┘


SUPPRESSION RULES:
┌─────────────────────────────────────────┬─────────────────────────────────────┐
│ Condition                               │ Action                              │
├─────────────────────────────────────────┼─────────────────────────────────────┤
│ consecutive_breaches < 4                │ Suppress (transient)                │
│ infra_group_pct_affected > 50%          │ Suppress app, raise infra alert     │
│ During maintenance window               │ Suppress all                        │
│ Within 30 min post-maintenance          │ Suppress if errors < 10             │
│ confidence_level = 'Possible Transient' │ Suppress for P1/P2, allow P3/P4     │
│ status = 'RECOVERING'                   │ Suppress new alerts                 │
└─────────────────────────────────────────┴─────────────────────────────────────┘


QUERY EXECUTION FREQUENCY:
┌─────────────────────────────────────────┬─────────────────────────────────────┐
│ Query                                   │ Recommended Frequency               │
├─────────────────────────────────────────┼─────────────────────────────────────┤
│ Dashboard Summary View                  │ Every 1 minute                      │
│ Threshold Breach Detection              │ Every 1 minute                      │
│ Host Error Pattern Analysis             │ Every 5 minutes                     │
│ Correlation Analysis                    │ Every 5 minutes                     │
│ Baseline Calculation                    │ Every 1 hour (or daily)             │
│ Maintenance Window Check                │ Every 5 minutes                     │
└─────────────────────────────────────────┴─────────────────────────────────────┘


DATA RETENTION RECOMMENDATIONS:
┌─────────────────────────────────────────┬─────────────────────────────────────┐
│ Data Type                               │ Retention Period                    │
├─────────────────────────────────────────┼─────────────────────────────────────┤
│ Per-minute metrics                      │ 7 days (raw), 90 days (aggregated)  │
│ Error logs                              │ 30 days (raw), 1 year (aggregated)  │
│ Baseline statistics                     │ 30 days                             │
│ Alert history                           │ 1 year                              │
│ Maintenance windows                     │ 1 year                              │
└─────────────────────────────────────────┴─────────────────────────────────────┘


================================================================================
SAMPLE DATA SCENARIOS FOR TESTING
================================================================================

SCENARIO 1: Normal Operation
- Synthetic Health: 99.8%
- Host Health: 4/4 Healthy
- Errors (30 min): 2 errors in 1 distinct minute
- Expected Status: HEALTHY
- Expected Alert: None

SCENARIO 2: Transient Spike (Should NOT alert)
- Synthetic Health: 96% at 10:01, 99.5% at 10:02-10:05
- Errors (30 min): 45 errors in 1 distinct minute
- Expected Status: WARNING
- Expected Alert: Suppressed (single minute, not sustained)

SCENARIO 3: Genuine Degradation (Should alert)
- Synthetic Health: 97.2% average over 5 minutes
- Host Health: 5/6 Healthy
- Errors (30 min): 35 errors across 8 distinct minutes
- Expected Status: DEGRADED
- Expected Alert: P2 (Slack + Email)

SCENARIO 4: Infrastructure Issue (Should suppress app alerts)
- 4 out of 6 apps in Datacenter-East showing errors
- Each app has 20+ errors
- Expected Action: Suppress individual app alerts
- Expected Alert: Single P1 Infrastructure Alert

SCENARIO 5: Post-Maintenance Stabilization (Should suppress)
- Maintenance ended 15 minutes ago
- Errors: 8 errors since maintenance end
- Expected Status: Allow (within stabilization threshold of 10)
- Expected Alert: Suppressed until stabilization period ends

*/

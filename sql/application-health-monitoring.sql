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
-- USAGE NOTES
-- ============================================================================
/*
KEY STRATEGIES FOR FALSE ALARM REDUCTION:

1. TEMPORAL VALIDATION
   - Don't alert on single-minute spikes
   - Require 3-5 consecutive minutes of threshold breach
   - Use rolling averages instead of point-in-time values

2. HISTORICAL CONTEXT
   - Compare against baseline (same hour, last 7 days)
   - Use standard deviation to identify true anomalies
   - Track distinct error minutes, not just error counts

3. CORRELATION ANALYSIS
   - If multiple apps in same infrastructure group affected, likely infra issue
   - Suppress individual app alerts, raise infrastructure alert instead

4. MAINTENANCE AWARENESS
   - Suppress alerts during maintenance windows
   - Allow 30-minute stabilization period post-maintenance

5. WEIGHTED SCORING
   - Recent errors (5 min) weighted higher than older errors (30 min)
   - Combine multiple signals (synthetic, host, errors) for confidence

6. RECOVERY TRACKING
   - Track consecutive healthy minutes
   - Show "Recovering" status when improving
   - Avoid flip-flopping between states

RECOMMENDED ALERT THRESHOLDS:
- Raise alert only when consecutive_breaches >= 4 (4+ minutes)
- Suppress if same infrastructure_group has >50% apps affected
- Require confidence_level = 'Confirmed' for paging alerts
*/

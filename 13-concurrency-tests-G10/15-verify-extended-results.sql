/* =====================================================================
   File: 15-verify-extended-results.sql
   Deliverable: 13-concurrency-tests-G10

   Purpose:
       Automated PASS/FAIL verification for the extended concurrency
       tests (Tests 2, 3A, 3B and 4), followed by the final production
       invariant check.

       Run AFTER completing:
           Test 2:  07 + 08
           Test 3A: 09 + 10
           Test 3B: 11 + 12
           Test 4:  13 + 14

       (05-verify-results.sql separately verifies and cleans up
        Test 1 on space CONC-G10.)
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------
   1. TEST 2 — automatic vs staff approval (CONC-AUTO-G10)

   Expected:
       - exactly 1 approved booking on the space;
       - it is the staff-approved booking (U001, decision_method staff);
       - the losing automatic submission was rolled back, so no U002
         booking exists at all.
   --------------------------------------------------------------------- */

SELECT N'=== TEST 2: automatic vs staff approval ===' AS section;
GO

SELECT
    N'TEST 2' AS test,
    COUNT(*) AS total_bookings,
    SUM(CASE WHEN booking_status = N'approved' THEN 1 ELSE 0 END) AS approved_count,
    CASE
        WHEN SUM(CASE WHEN booking_status = N'approved' THEN 1 ELSE 0 END) = 1
            THEN N'PASS - exactly one approved booking on CONC-AUTO-G10.'
        ELSE N'FAIL - expected exactly one approved booking on CONC-AUTO-G10.'
    END AS test_result
FROM dbo.booking_requests
WHERE space_code = 'CONC-AUTO-G10';
GO

SELECT
    N'TEST 2' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM dbo.booking_requests AS br
            INNER JOIN dbo.approvals AS a
                ON a.booking_id = br.booking_id
            WHERE br.space_code = 'CONC-AUTO-G10'
              AND br.requester_id = 'U001'
              AND br.booking_status = N'approved'
              AND a.decision = N'approved'
              AND a.decision_method = N'staff'
        )
            THEN N'PASS - the surviving approval is the STAFF decision.'
        ELSE N'FAIL - the staff-approved booking was not found.'
    END AS test_result;
GO

SELECT
    N'TEST 2' AS test,
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM dbo.booking_requests
            WHERE space_code = 'CONC-AUTO-G10'
              AND requester_id = 'U002'
        )
            THEN N'PASS - the losing automatic submission was fully rolled back.'
        ELSE N'FAIL - the losing automatic submission left a booking behind.'
    END AS test_result;
GO

/* ---------------------------------------------------------------------
   2. TEST 3A — approval wins, escalation identifies affected booking

   Expected:
       - maintenance M1 (2035-03-01 09:00) is out-of-service;
       - booking MAINT-3A (2035-03-01 10:00-12:00) is approved;
       - the escalation advisory -> out-of-service is recorded in
         maintenance_impact_history;
       - the approved booking belongs to the affected set of M1.
   --------------------------------------------------------------------- */

SELECT N'=== TEST 3A: approval first, then escalation ===' AS section;
GO

SELECT
    N'TEST 3A' AS test,
    CASE
        WHEN mr.impact_level = N'out-of-service'
            THEN N'PASS - M1 was escalated to out-of-service.'
        ELSE N'FAIL - M1 is not out-of-service.'
    END AS maintenance_check,
    CASE
        WHEN br.booking_status = N'approved'
            THEN N'PASS - the racing booking is approved.'
        ELSE N'FAIL - the racing booking is not approved.'
    END AS booking_check
FROM dbo.maintenance_records AS mr
CROSS JOIN dbo.booking_requests AS br
WHERE mr.space_code = 'CONC-MAINT-G10'
  AND mr.start_time = '2035-03-01T09:00:00'
  AND br.space_code = 'CONC-MAINT-G10'
  AND br.requested_start_time = '2035-03-01T10:00:00';
GO

SELECT
    N'TEST 3A' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM dbo.maintenance_impact_history AS mih
            INNER JOIN dbo.maintenance_records AS mr
                ON mr.maintenance_id = mih.maintenance_id
            WHERE mr.space_code = 'CONC-MAINT-G10'
              AND mr.start_time = '2035-03-01T09:00:00'
              AND mih.previous_impact_level = N'advisory'
              AND mih.new_impact_level = N'out-of-service'
        )
            THEN N'PASS - the escalation is recorded in maintenance_impact_history.'
        ELSE N'FAIL - no escalation history row was found for M1.'
    END AS test_result;
GO

/* Affected-set membership, re-derived with the production overlap rule. */
SELECT
    N'TEST 3A' AS test,
    CASE
        WHEN COUNT(*) = 1
            THEN N'PASS - the approved booking is identified as affected by the escalation.'
        ELSE N'FAIL - the approved booking is not in the affected set.'
    END AS test_result
FROM dbo.booking_requests AS br
INNER JOIN dbo.maintenance_records AS mr
    ON mr.space_code = br.space_code
WHERE br.space_code = 'CONC-MAINT-G10'
  AND br.requested_start_time = '2035-03-01T10:00:00'
  AND br.booking_status IN (N'approved', N'checked in')
  AND mr.start_time = '2035-03-01T09:00:00'
  AND mr.impact_level = N'out-of-service'
  AND br.requested_start_time <
      COALESCE(mr.completion_time, CONVERT(DATETIME2(0), '9999-12-31 23:59:59'))
  AND br.requested_end_time > mr.start_time;
GO

/* ---------------------------------------------------------------------
   3. TEST 3B — escalation wins, approval blocked

   Expected:
       - maintenance M2 (2035-03-02 09:00) is out-of-service;
       - booking MAINT-3B (2035-03-02 10:00-12:00) is still pending;
       - the booking has ZERO decision rows.
   --------------------------------------------------------------------- */

SELECT N'=== TEST 3B: escalation first, approval rejected ===' AS section;
GO

SELECT
    N'TEST 3B' AS test,
    CASE
        WHEN mr.impact_level = N'out-of-service'
            THEN N'PASS - M2 was escalated to out-of-service.'
        ELSE N'FAIL - M2 is not out-of-service.'
    END AS maintenance_check,
    CASE
        WHEN br.booking_status = N'pending'
            THEN N'PASS - the racing booking is still pending.'
        ELSE N'FAIL - the racing booking should have stayed pending.'
    END AS booking_check
FROM dbo.maintenance_records AS mr
CROSS JOIN dbo.booking_requests AS br
WHERE mr.space_code = 'CONC-MAINT-G10'
  AND mr.start_time = '2035-03-02T09:00:00'
  AND br.space_code = 'CONC-MAINT-G10'
  AND br.requested_start_time = '2035-03-02T10:00:00';
GO

SELECT
    N'TEST 3B' AS test,
    CASE
        WHEN COUNT(*) = 0
            THEN N'PASS - the blocked booking has no decision row.'
        ELSE N'FAIL - the blocked booking unexpectedly has a decision row.'
    END AS test_result
FROM dbo.approvals AS a
INNER JOIN dbo.booking_requests AS br
    ON br.booking_id = a.booking_id
WHERE br.space_code = 'CONC-MAINT-G10'
  AND br.requested_start_time = '2035-03-02T10:00:00';
GO

/* ---------------------------------------------------------------------
   4. TEST 4 — stale decision / ROWVERSION

   Expected:
       - booking RV (2035-04-01 13:00-15:00) is approved;
       - exactly ONE decision row exists (the stale rejection failed).
   --------------------------------------------------------------------- */

SELECT N'=== TEST 4: stale decision / ROWVERSION ===' AS section;
GO

SELECT
    N'TEST 4' AS test,
    br.booking_id,
    br.booking_status,
    COUNT(a.booking_id) AS decision_count,
    CASE
        WHEN br.booking_status = N'approved'
         AND COUNT(a.booking_id) = 1
            THEN N'PASS - only the first decision survived; exactly one approval row exists.'
        ELSE N'FAIL - expected an approved booking with exactly one decision row.'
    END AS test_result
FROM dbo.booking_requests AS br
LEFT JOIN dbo.approvals AS a
    ON a.booking_id = br.booking_id
WHERE br.space_code = 'CONC-RV-G10'
  AND br.requested_start_time = '2035-04-01T13:00:00'
GROUP BY br.booking_id, br.booking_status;
GO

/* ---------------------------------------------------------------------
   5. FINAL INVARIANT

   No pair of approved/checked-in bookings for the same space may
   overlap anywhere in the database.

   Expected: 0 rows.
   --------------------------------------------------------------------- */

SELECT N'=== FINAL INVARIANT: expected 0 rows below ===' AS section;
GO

EXEC dbo.usp_verify_no_overlapping_approved_bookings;
GO

PRINT 'Extended verification finished.';
PRINT 'If Test 1 (unsafe/safe pair on CONC-G10) was also run, execute 05-verify-results.sql for its proof and cleanup.';
GO

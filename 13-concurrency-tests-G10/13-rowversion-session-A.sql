/* =====================================================================
   File: 13-rowversion-session-A.sql
   Scenario: TEST 4 — two staff modify the same booking - Session A

   Deterministic schedule:

       A reads version token X
       A waits 10 seconds            <-- run Session B (14) here
               B reads the SAME token X immediately
               B waits 15 seconds
       A approves with token X       -> succeeds, version X -> Y
               B rejects with stale token X -> must fail

   Run this first. While the 10-second WAITFOR is active, run
   14-rowversion-session-B.sql so that BOTH sessions capture the same
   initial version token before either one writes.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

DECLARE @BookingId INT;
DECLARE @VersionToken BINARY(8);

SELECT
    @BookingId = booking_id,
    @VersionToken = CONVERT(BINARY(8), version_token)
FROM dbo.booking_requests
WHERE space_code = 'CONC-RV-G10'
  AND requester_id = 'U001'
  AND requested_start_time = '2035-04-01T13:00:00'
  AND requested_end_time = '2035-04-01T15:00:00'
  AND booking_status = N'pending';

IF @BookingId IS NULL
    THROW 52371, 'RV pending booking was not found. Run 00-test-setup.sql first.', 1;

SELECT
    N'TEST 4 Session A read initial version token' AS event_name,
    @BookingId AS booking_id,
    @VersionToken AS version_token_X,
    SYSDATETIME() AS event_time;

PRINT 'TEST 4 Session A: token X captured. Waiting 10 seconds. RUN SESSION B (14) NOW.';
PRINT 'Session B must read the SAME token X during this wait.';

WAITFOR DELAY '00:00:10';

/* Approve using the token read BEFORE the wait. Nobody has modified the
   booking yet, so this succeeds and bumps the ROWVERSION X -> Y. */
EXEC dbo.usp_approve_booking
    @booking_id = @BookingId,
    @staff_id = 'FS001',
    @expected_version_token = @VersionToken,
    @decision_note = N'TEST 4 stale-decision - first staff decision wins.',
    @lock_timeout_ms = 10000;

PRINT CONCAT('TEST 4 Session A approved at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

/* Show that the optimistic concurrency token really changed. */
SELECT
    booking_id,
    booking_status,
    @VersionToken AS old_version_token_X,
    CONVERT(BINARY(8), version_token) AS current_version_token_Y,
    CASE
        WHEN CONVERT(BINARY(8), version_token) <> @VersionToken
            THEN N'PASS - ROWVERSION changed after the first decision (X <> Y).'
        ELSE N'FAIL - ROWVERSION did not change.'
    END AS version_check
FROM dbo.booking_requests
WHERE booking_id = @BookingId;
GO

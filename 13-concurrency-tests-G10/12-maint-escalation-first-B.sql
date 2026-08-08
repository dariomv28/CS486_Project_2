/* =====================================================================
   File: 12-maint-escalation-first-B.sql
   Scenario: TEST 3B — maintenance escalation wins before approval
             Session B (staff approval)

   Run while 11-maint-escalation-first-A.sql is waiting.

   Session B calls the production procedure dbo.usp_approve_booking
   for booking MAINT-3B (2035-03-02 10:00-12:00).

   Expected behavior:
       - the procedure tries CampusSpaceBooking:CONC-MAINT-G10;
       - it BLOCKS because escalation Session A holds the lock;
       - Session A escalates M2 advisory -> out-of-service and commits;
       - Session B acquires the lock and RECHECKS maintenance;
       - the recheck finds active out-of-service maintenance
         overlapping the booking;
       - error 52229 is returned;
       - MAINT-3B remains pending.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

DECLARE @BookingId INT;
DECLARE @VersionToken BINARY(8);
DECLARE @StartedAt DATETIME2(3) = SYSDATETIME();

SELECT
    @BookingId = booking_id,
    @VersionToken = CONVERT(BINARY(8), version_token)
FROM dbo.booking_requests
WHERE space_code = 'CONC-MAINT-G10'
  AND requester_id = 'U002'
  AND requested_start_time = '2035-03-02T10:00:00'
  AND requested_end_time = '2035-03-02T12:00:00';

IF @BookingId IS NULL
    THROW 52370, 'MAINT-3B booking was not found. Run 00-test-setup.sql first.', 1;

PRINT CONCAT('TEST 3B Session B calling usp_approve_booking at ', CONVERT(VARCHAR(30), @StartedAt, 126));
PRINT 'Expected: this statement waits for the Session A application lock,';
PRINT 'then fails with error 52229 (out-of-service maintenance).';

BEGIN TRY
    EXEC dbo.usp_approve_booking
        @booking_id = @BookingId,
        @staff_id = 'FS002',
        @expected_version_token = @VersionToken,
        @decision_note = N'TEST 3B maintenance-vs-approval - Session B should be rejected after recheck.',
        @lock_timeout_ms = 30000;

    /* Reaching this point means the maintenance recheck did not work. */
    SELECT
        N'FAIL - MAINT-3B was unexpectedly approved despite out-of-service maintenance.' AS test_result,
        @BookingId AS booking_id,
        DATEDIFF(MILLISECOND, @StartedAt, SYSDATETIME()) AS elapsed_ms;
END TRY
BEGIN CATCH
    SELECT
        CASE
            WHEN ERROR_NUMBER() = 52229
                THEN N'PASS - Session B waited, rechecked maintenance, and was rejected with 52229.'
            ELSE N'FAIL - Session B failed, but not with expected maintenance error 52229.'
        END AS test_result,
        ERROR_NUMBER() AS error_number,
        ERROR_MESSAGE() AS error_message,
        @BookingId AS booking_id,
        @StartedAt AS started_at,
        SYSDATETIME() AS finished_at,
        DATEDIFF(MILLISECOND, @StartedAt, SYSDATETIME()) AS elapsed_ms;
END CATCH;
GO

/* Final state: the booking must still be pending with no decision. */
SELECT
    br.booking_id,
    br.booking_status,
    br.requested_start_time,
    br.requested_end_time,
    a.decision AS decision,
    CASE WHEN a.booking_id IS NULL THEN 0 ELSE 1 END AS has_decision
FROM dbo.booking_requests AS br
LEFT JOIN dbo.approvals AS a
    ON a.booking_id = br.booking_id
WHERE br.space_code = 'CONC-MAINT-G10'
  AND br.requested_start_time = '2035-03-02T10:00:00';
GO

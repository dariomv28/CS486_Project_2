/* =====================================================================
   File: 08-auto-vs-staff-session-B.sql
   Scenario: TEST 2 — automatic approval vs staff approval - Session B

   Run while 07-auto-vs-staff-session-A.sql is waiting.

   Session B plays the AUTOMATIC side of the race. It calls the real
   production API dbo.usp_submit_booking with:

       space                  = CONC-AUTO-G10
       time                   = 2035-02-15 10:00-12:00 (overlaps A)
       usage_policy_satisfied = 1

   Because the meeting-room policy enables instant approval, the
   submission attempts automatic approval INSIDE the same transaction.

   Expected behavior:
       - usp_submit_booking tries CampusSpaceBooking:CONC-AUTO-G10;
       - it BLOCKS because staff Session A holds the lock;
       - after Session A commits, Session B acquires the lock;
       - the shared approval core rechecks conflicts;
       - it finds the booking Session A just approved;
       - error 52230 is thrown;
       - the WHOLE submission transaction rolls back, so the automatic
         booking does not even exist afterwards.

   This proves staff approval and automatic approval serialize on the
   same application-lock resource.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

IF NOT EXISTS (
    SELECT 1
    FROM dbo.booking_requests
    WHERE space_code = 'CONC-AUTO-G10'
      AND requester_id = 'U001'
      AND requested_start_time = '2035-02-15T09:00:00'
)
    THROW 52362, 'AUTO-STAFF-A booking was not found. Run 00-test-setup.sql first.', 1;
GO

DECLARE @Acknowledgements dbo.maintenance_id_list;
DECLARE @BookingId INT;
DECLARE @BookingStatus NVARCHAR(30);
DECLARE @VersionToken BINARY(8);
DECLARE @StartedAt DATETIME2(3) = SYSDATETIME();

PRINT CONCAT('TEST 2 Session B calling usp_submit_booking at ', CONVERT(VARCHAR(30), @StartedAt, 126));
PRINT 'Expected: this statement waits for the Session A application lock.';

BEGIN TRY
    EXEC dbo.usp_submit_booking
        @requester_id = 'U002',
        @space_code = 'CONC-AUTO-G10',
        @requested_start_time = '2035-02-15T10:00:00',
        @requested_end_time = '2035-02-15T12:00:00',
        @purpose_of_use = N'meeting',
        @expected_participants = 10,
        @usage_policy_satisfied = 1,
        @acknowledged_advisories = @Acknowledgements,
        @booking_id = @BookingId OUTPUT,
        @booking_status = @BookingStatus OUTPUT,
        @version_token = @VersionToken OUTPUT,
        @lock_timeout_ms = 30000;

    /* Reaching this point means the automatic approval did not detect
       the conflict with the booking Session A approved. */
    SELECT
        N'FAIL - the overlapping automatic booking was unexpectedly accepted.' AS test_result,
        @BookingId AS booking_id,
        @BookingStatus AS booking_status,
        DATEDIFF(MILLISECOND, @StartedAt, SYSDATETIME()) AS elapsed_ms;
END TRY
BEGIN CATCH
    SELECT
        CASE
            WHEN ERROR_NUMBER() = 52230
                THEN N'PASS - Session B waited on the lock, rechecked, and the automatic approval was rejected for conflict.'
            ELSE N'FAIL - Session B failed, but not with expected conflict error 52230.'
        END AS test_result,
        ERROR_NUMBER() AS error_number,
        ERROR_MESSAGE() AS error_message,
        @StartedAt AS started_at,
        SYSDATETIME() AS finished_at,
        DATEDIFF(MILLISECOND, @StartedAt, SYSDATETIME()) AS elapsed_ms;
END CATCH;
GO

/* The submission transaction must have rolled back completely:
   no U002 booking may exist for the overlapping slot. */
SELECT
    CASE
        WHEN COUNT(*) = 0
            THEN N'PASS - the rejected automatic booking was fully rolled back (0 rows).'
        ELSE N'FAIL - the rejected automatic booking still exists.'
    END AS rollback_check
FROM dbo.booking_requests
WHERE space_code = 'CONC-AUTO-G10'
  AND requester_id = 'U002'
  AND requested_start_time = '2035-02-15T10:00:00';
GO

/* Final state of the test space. Expected: exactly one approved
   booking, the staff-approved AUTO-STAFF-A. */
SELECT
    br.booking_id,
    br.requester_id,
    br.requested_start_time,
    br.requested_end_time,
    br.booking_status,
    a.decision_method,
    a.staff_id
FROM dbo.booking_requests AS br
LEFT JOIN dbo.approvals AS a
    ON a.booking_id = br.booking_id
WHERE br.space_code = 'CONC-AUTO-G10'
ORDER BY br.requested_start_time;
GO

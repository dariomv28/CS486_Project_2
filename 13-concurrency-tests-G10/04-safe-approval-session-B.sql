/* =====================================================================
   File: 04-safe-approval-session-B.sql
   Scenario: WITH G10 concurrency control - Session B

   Run while 03-safe-approval-session-A.sql is waiting.

   Expected behavior:
       - this call blocks waiting for CampusSpaceBooking:CONC-G10;
       - after Session A commits, this session acquires the lock;
       - the production procedure rechecks conflicts;
       - error 52230 is returned;
       - SAFE B remains pending.
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
WHERE space_code = 'CONC-G10'
  AND requester_id = 'U002'
  AND requested_start_time = '2035-01-16T10:00:00'
  AND requested_end_time = '2035-01-16T12:00:00';

IF @BookingId IS NULL
    THROW 52350, 'SAFE B booking was not found. Run 00-test-setup.sql first.', 1;

PRINT CONCAT('SAFE Session B calling usp_approve_booking at ', CONVERT(VARCHAR(30), @StartedAt, 126));
PRINT 'Expected: this statement waits for Session A application lock.';

BEGIN TRY
    EXEC dbo.usp_approve_booking
        @booking_id = @BookingId,
        @staff_id = 'FS002',
        @expected_version_token = @VersionToken,
        @decision_note = N'SAFE concurrency test - Session B should be rejected after recheck.',
        @lock_timeout_ms = 30000;

    /* Reaching this point means the expected conflict was not detected. */
    SELECT
        N'FAIL - SAFE B was unexpectedly approved.' AS test_result,
        @BookingId AS booking_id,
        DATEDIFF(MILLISECOND, @StartedAt, SYSDATETIME()) AS elapsed_ms;
END TRY
BEGIN CATCH
    SELECT
        CASE
            WHEN ERROR_NUMBER() = 52230
                THEN N'PASS - Session B waited, rechecked, and was rejected for conflict.'
            ELSE N'FAIL - Session B failed, but not with expected conflict error 52230.'
        END AS test_result,
        ERROR_NUMBER() AS error_number,
        ERROR_MESSAGE() AS error_message,
        @BookingId AS booking_id,
        @StartedAt AS started_at,
        SYSDATETIME() AS finished_at,
        DATEDIFF(MILLISECOND, @StartedAt, SYSDATETIME()) AS elapsed_ms;
END CATCH;

SELECT
    booking_id,
    booking_status,
    requested_start_time,
    requested_end_time,
    CONVERT(BINARY(8), version_token) AS version_token
FROM dbo.booking_requests
WHERE booking_id = @BookingId;
GO

/* =====================================================================
   File: 03-safe-approval-session-A.sql
   Scenario: WITH G10 concurrency control - Session A

   Run this first. Session A obtains the exact per-space application
   lock used by 12-concurrency-implementation-G10.sql, waits for 10
   seconds, then approves SAFE A inside the same transaction.

   While WAITFOR is active, run 04-safe-approval-session-B.sql.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

DECLARE @BookingId INT;
DECLARE @VersionToken BINARY(8);
DECLARE @LockResult INT;
DECLARE @LockResource NVARCHAR(255) = N'CampusSpaceBooking:CONC-G10';

SELECT
    @BookingId = booking_id,
    @VersionToken = CONVERT(BINARY(8), version_token)
FROM dbo.booking_requests
WHERE space_code = 'CONC-G10'
  AND requester_id = 'U001'
  AND requested_start_time = '2035-01-16T09:00:00'
  AND requested_end_time = '2035-01-16T11:00:00';

IF @BookingId IS NULL
    THROW 52340, 'SAFE A booking was not found. Run 00-test-setup.sql first.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = N'Exclusive',
        @LockOwner = N'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 52341, 'SAFE Session A could not obtain the application lock.', 1;

    SELECT
        N'SAFE Session A acquired application lock' AS event_name,
        @LockResource AS lock_resource,
        @LockResult AS lock_result,
        SYSDATETIME() AS event_time;

    PRINT 'SAFE Session A: lock acquired. Waiting 10 seconds. RUN SESSION B NOW.';

    WAITFOR DELAY '00:00:10';

    /*
       Reuse the production core while the same transaction-owned lock
       is still held. The core revalidates conflicts after the lock.
    */
    EXEC dbo.usp_approve_booking_core
        @booking_id = @BookingId,
        @decision_method = N'staff',
        @staff_id = 'FS001',
        @decision_note = N'SAFE concurrency test - Session A.',
        @usage_policy_satisfied = 0,
        @expected_version_token = @VersionToken,
        @lock_timeout_ms = 10000;

    COMMIT TRANSACTION;

    PRINT CONCAT('SAFE Session A committed at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

    SELECT
        booking_id,
        booking_status,
        requested_start_time,
        requested_end_time,
        CONVERT(BINARY(8), version_token) AS version_token
    FROM dbo.booking_requests
    WHERE booking_id = @BookingId;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

/* =====================================================================
   File: 07-auto-vs-staff-session-A.sql
   Scenario: TEST 2 — automatic approval vs staff approval - Session A

   Session A plays the STAFF side of the race.

   Run this first. Session A obtains the per-space application lock

       CampusSpaceBooking:CONC-AUTO-G10

   (the exact resource used by 12-concurrency-implementation-G10.sql),
   waits for 10 seconds, then approves the pre-created pending booking
   AUTO-STAFF-A through the production approval core.

   While WAITFOR is active, run 08-auto-vs-staff-session-B.sql.
   Session B submits an overlapping booking that attempts AUTOMATIC
   approval through dbo.usp_submit_booking.
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
DECLARE @LockResource NVARCHAR(255) = N'CampusSpaceBooking:CONC-AUTO-G10';

SELECT
    @BookingId = booking_id,
    @VersionToken = CONVERT(BINARY(8), version_token)
FROM dbo.booking_requests
WHERE space_code = 'CONC-AUTO-G10'
  AND requester_id = 'U001'
  AND requested_start_time = '2035-02-15T09:00:00'
  AND requested_end_time = '2035-02-15T11:00:00'
  AND booking_status = N'pending';

IF @BookingId IS NULL
    THROW 52360, 'AUTO-STAFF-A pending booking was not found. Run 00-test-setup.sql first.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = N'Exclusive',
        @LockOwner = N'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 52361, 'TEST 2 Session A could not obtain the application lock.', 1;

    SELECT
        N'TEST 2 Session A acquired application lock' AS event_name,
        @LockResource AS lock_resource,
        @LockResult AS lock_result,
        SYSDATETIME() AS event_time;

    PRINT 'TEST 2 Session A: lock acquired. Waiting 10 seconds. RUN SESSION B (08) NOW.';

    WAITFOR DELAY '00:00:10';

    /*
       Reuse the production core while the same transaction-owned lock
       is still held. The core revalidates conflicts after the lock.
    */
    EXEC dbo.usp_approve_booking_core
        @booking_id = @BookingId,
        @decision_method = N'staff',
        @staff_id = 'FS001',
        @decision_note = N'TEST 2 automatic-vs-staff - staff Session A.',
        @usage_policy_satisfied = 0,
        @expected_version_token = @VersionToken,
        @lock_timeout_ms = 10000;

    COMMIT TRANSACTION;

    PRINT CONCAT('TEST 2 Session A committed at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

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

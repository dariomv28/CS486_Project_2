/* =====================================================================
   File: 09-maint-approval-first-A.sql
   TEST 3A — Session A: approval wins first

   Run this first.
   While it is waiting 10 seconds, run 10-maint-approval-first-B.sql.
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
DECLARE @LockResource NVARCHAR(255) = N'CampusSpaceBooking:CONC-MAINT-G10';

SELECT
    @BookingId = br.booking_id,
    @VersionToken = CONVERT(BINARY(8), br.version_token)
FROM dbo.booking_requests AS br
WHERE br.space_code = 'CONC-MAINT-G10'
  AND br.requester_id = 'U001'
  AND br.requested_start_time = '2035-03-01T10:00:00'
  AND br.requested_end_time = '2035-03-01T12:00:00'
  AND br.booking_status = N'pending';

IF @BookingId IS NULL
    THROW 52363, 'MAINT-3A pending booking was not found. Run 00-test-setup.sql first.', 1;

IF NOT EXISTS (
    SELECT 1
    FROM dbo.maintenance_records AS mr
    WHERE mr.space_code = 'CONC-MAINT-G10'
      AND mr.start_time = '2035-03-01T09:00:00'
      AND mr.impact_level = N'advisory'
      AND mr.maintenance_status IN (N'reported', N'assigned', N'in progress')
)
    THROW 52364, 'Advisory maintenance M1 was not found. Run 00-test-setup.sql first.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = N'Exclusive',
        @LockOwner = N'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 52365, 'TEST 3A Session A could not obtain the application lock.', 1;

    PRINT 'TEST 3A Session A: lock acquired. Waiting 10 seconds. RUN SESSION B (10) NOW.';

    WAITFOR DELAY '00:00:10';

    EXEC dbo.usp_approve_booking_core
        @booking_id = @BookingId,
        @decision_method = N'staff',
        @staff_id = 'FS001',
        @decision_note = N'TEST 3A maintenance-vs-approval - staff Session A.',
        @usage_policy_satisfied = 0,
        @expected_version_token = @VersionToken,
        @lock_timeout_ms = 10000;

    COMMIT TRANSACTION;

    /* ONLY RESULT SET:
       Full evidence that this booking was approved for this space/time. */
    SELECT
        br.booking_id,
        br.requester_id,
        br.space_code,
        br.requested_start_time,
        br.requested_end_time,
        br.purpose_of_use,
        br.expected_participants,
        br.booking_status,
        a.decision,
        a.decision_method,
        a.staff_id,
        a.decision_time
    FROM dbo.booking_requests AS br
    LEFT JOIN dbo.approvals AS a
        ON a.booking_id = br.booking_id
    WHERE br.booking_id = @BookingId;

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
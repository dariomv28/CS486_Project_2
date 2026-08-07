/* =====================================================================
   File: 02-race-condition-session-B.sql
   Scenario: WITHOUT concurrency control - Session B

   Run this while 01-race-condition-session-A.sql is waiting.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

DECLARE @BookingId INT;

SELECT @BookingId = booking_id
FROM dbo.booking_requests
WHERE space_code = 'CONC-G10'
  AND requester_id = 'U002'
  AND requested_start_time = '2035-01-15T10:00:00'
  AND requested_end_time = '2035-01-15T12:00:00';

IF @BookingId IS NULL
    THROW 52330, 'UNSAFE B booking was not found. Run 00-test-setup.sql first.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    PRINT CONCAT('UNSAFE Session B started at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

    /* Same flawed one-time check as Session A. */
    IF EXISTS (
        SELECT 1
        FROM dbo.booking_requests AS existing
        WHERE existing.space_code = 'CONC-G10'
          AND existing.booking_id <> @BookingId
          AND existing.booking_status IN (N'approved', N'checked in')
          AND CAST('2035-01-15T10:00:00' AS DATETIME2(0)) < existing.requested_end_time
          AND CAST('2035-01-15T12:00:00' AS DATETIME2(0)) > existing.requested_start_time
    )
    BEGIN
        THROW 52331, 'UNSAFE B unexpectedly found an existing conflict.', 1;
    END;

    PRINT 'UNSAFE Session B: conflict check = NO CONFLICT.';

    /* No application lock and no recheck before writing. */
    INSERT INTO dbo.approvals (
        booking_id,
        staff_id,
        decision,
        decision_method,
        decision_time,
        decision_note,
        rejection_reason
    )
    VALUES (
        @BookingId,
        'FS002',
        N'approved',
        N'staff',
        SYSDATETIME(),
        N'UNSAFE concurrency test - Session B approved without a serialization lock.',
        NULL
    );

    COMMIT TRANSACTION;

    PRINT CONCAT('UNSAFE Session B committed at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

    SELECT
        booking_id,
        booking_status,
        requested_start_time,
        requested_end_time
    FROM dbo.booking_requests
    WHERE booking_id = @BookingId;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

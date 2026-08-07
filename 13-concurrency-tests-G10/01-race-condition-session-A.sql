/* =====================================================================
   File: 01-race-condition-session-A.sql
   Scenario: WITHOUT concurrency control - Session A

   Run this first. While it is inside WAITFOR, run
   02-race-condition-session-B.sql in a second SSMS window.

   IMPORTANT TEST-HARNESS NOTE:
       The Phase 2 migration keeps an ordinary overlap-validation trigger.
       It is temporarily disabled here so this negative test isolates the
       flawed application pattern:

           CHECK ONCE -> WAIT -> WRITE WITHOUT RECHECK

       The trigger is re-enabled at the end (and also defensively by
       05-verify-results.sql).
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
  AND requester_id = 'U001'
  AND requested_start_time = '2035-01-15T09:00:00'
  AND requested_end_time = '2035-01-15T11:00:00';

IF @BookingId IS NULL
    THROW 52320, 'UNSAFE A booking was not found. Run 00-test-setup.sql first.', 1;

/* Test harness only. Do not do this in production. */
DISABLE TRIGGER dbo.trg_booking_requests_validate
ON dbo.booking_requests;

BEGIN TRY
    BEGIN TRANSACTION;

    PRINT CONCAT('UNSAFE Session A started at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

    /* -------------------------------------------------------------
       Step 1: Check conflict ONCE.
       Both UNSAFE requests are still pending at this point.
       ------------------------------------------------------------- */
    IF EXISTS (
        SELECT 1
        FROM dbo.booking_requests AS existing
        WHERE existing.space_code = 'CONC-G10'
          AND existing.booking_id <> @BookingId
          AND existing.booking_status IN (N'approved', N'checked in')
          AND CAST('2035-01-15T09:00:00' AS DATETIME2(0)) < existing.requested_end_time
          AND CAST('2035-01-15T11:00:00' AS DATETIME2(0)) > existing.requested_start_time
    )
    BEGIN
        THROW 52321, 'UNSAFE A unexpectedly found an existing conflict.', 1;
    END;

    PRINT 'UNSAFE Session A: conflict check = NO CONFLICT.';
    PRINT 'UNSAFE Session A: waiting 10 seconds. RUN SESSION B NOW.';

    /* -------------------------------------------------------------
       Step 2: Create the race window.
       ------------------------------------------------------------- */
    WAITFOR DELAY '00:00:10';

    /* -------------------------------------------------------------
       Step 3: UNSAFE WRITE.
       There is intentionally NO conflict recheck here.
       ------------------------------------------------------------- */
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
        'FS001',
        N'approved',
        N'staff',
        SYSDATETIME(),
        N'UNSAFE concurrency test - Session A approved from a stale conflict check.',
        NULL
    );

    COMMIT TRANSACTION;

    ENABLE TRIGGER dbo.trg_booking_requests_validate
    ON dbo.booking_requests;

    PRINT CONCAT('UNSAFE Session A committed at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

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

    /* Never leave the validation trigger disabled after a failed test. */
    ENABLE TRIGGER dbo.trg_booking_requests_validate
    ON dbo.booking_requests;

    THROW;
END CATCH;
GO

/* =====================================================================
   File: 14-rowversion-session-B.sql
   Scenario: TEST 4 — two staff modify the same booking - Session B

   Run while 13-rowversion-session-A.sql is inside its 10-second wait.

   Session B reads the SAME initial version token X as Session A, then
   deliberately waits 15 seconds so that Session A's approval commits
   first. Session B then tries to REJECT the booking using the stale
   token X.

   Expected behavior (matches the Test 4 plan in
   11-concurrency-design-G10.md: the second transaction is rejected
   because booking status OR ROWVERSION has changed):

       error 52254  'Only a pending booking can be rejected.'
           - the status check fires first in usp_reject_booking, or
       error 52255  'The booking was changed by another transaction.'
           - the ROWVERSION check fires if the status were still pending.

   Either error proves the stale decision cannot overwrite the first
   committed decision. Exactly ONE approval row may exist at the end.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

DECLARE @BookingId INT;
DECLARE @StaleVersionToken BINARY(8);
DECLARE @BookingStatusAtRead NVARCHAR(30);
DECLARE @StartedAt DATETIME2(3) = SYSDATETIME();

SELECT
    @BookingId = booking_id,
    @StaleVersionToken = CONVERT(BINARY(8), version_token),
    @BookingStatusAtRead = booking_status
FROM dbo.booking_requests
WHERE space_code = 'CONC-RV-G10'
  AND requester_id = 'U001'
  AND requested_start_time = '2035-04-01T13:00:00'
  AND requested_end_time = '2035-04-01T15:00:00';

IF @BookingId IS NULL
    THROW 52372, 'RV booking was not found. Run 00-test-setup.sql first.', 1;

IF @BookingStatusAtRead <> N'pending'
    THROW 52373, 'RV booking is no longer pending. Session B was started too late; rerun 00-test-setup.sql.', 1;

SELECT
    N'TEST 4 Session B read the same initial version token' AS event_name,
    @BookingId AS booking_id,
    @StaleVersionToken AS version_token_X,
    @BookingStatusAtRead AS booking_status_at_read,
    SYSDATETIME() AS event_time;

PRINT 'TEST 4 Session B: token X captured while booking is still pending.';
PRINT 'Waiting 15 seconds so Session A commits its decision first...';

WAITFOR DELAY '00:00:15';

PRINT CONCAT('TEST 4 Session B attempting stale rejection at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

BEGIN TRY
    EXEC dbo.usp_reject_booking
        @booking_id = @BookingId,
        @staff_id = 'FS002',
        @expected_version_token = @StaleVersionToken,
        @rejection_reason = N'TEST 4 stale-decision - this rejection must fail.',
        @decision_note = N'Second staff decision based on a stale read.';

    /* Reaching this point means the stale decision overwrote the
       committed one. */
    SELECT
        N'FAIL - the stale rejection was unexpectedly accepted.' AS test_result,
        @BookingId AS booking_id,
        DATEDIFF(MILLISECOND, @StartedAt, SYSDATETIME()) AS elapsed_ms;
END TRY
BEGIN CATCH
    SELECT
        CASE
            WHEN ERROR_NUMBER() IN (52254, 52255)
                THEN N'PASS - the second (stale) decision was rejected: '
                     + CASE ERROR_NUMBER()
                           WHEN 52254 THEN N'booking status had already changed (52254).'
                           ELSE N'ROWVERSION had already changed (52255).'
                       END
            ELSE N'FAIL - Session B failed, but not with expected error 52254 or 52255.'
        END AS test_result,
        ERROR_NUMBER() AS error_number,
        ERROR_MESSAGE() AS error_message,
        @BookingId AS booking_id,
        DATEDIFF(MILLISECOND, @StartedAt, SYSDATETIME()) AS elapsed_ms;
END CATCH;
GO

/* Final evidence: the token really moved on from X, and exactly one
   decision exists for the booking. */
DECLARE @BookingId INT;

SELECT @BookingId = booking_id
FROM dbo.booking_requests
WHERE space_code = 'CONC-RV-G10'
  AND requested_start_time = '2035-04-01T13:00:00';

SELECT
    br.booking_id,
    br.booking_status,
    CONVERT(BINARY(8), br.version_token) AS current_version_token_Y,
    (SELECT COUNT(*) FROM dbo.approvals AS a
      WHERE a.booking_id = br.booking_id) AS decision_count,
    CASE
        WHEN (SELECT COUNT(*) FROM dbo.approvals AS a
               WHERE a.booking_id = br.booking_id) = 1
            THEN N'PASS - exactly one final decision exists for the booking.'
        ELSE N'FAIL - expected exactly one decision row.'
    END AS decision_count_check
FROM dbo.booking_requests AS br
WHERE br.booking_id = @BookingId;
GO

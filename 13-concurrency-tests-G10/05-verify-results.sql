/* =====================================================================
   File: 05-verify-results.sql
   Deliverable: 13-concurrency-tests-G10

   Purpose:
       1. Prove the intentionally unsafe scenario produced 2 overlapping
          approved bookings.
       2. Prove the G10 concurrency-control solution leaves exactly 1
          approved booking in the protected pair.
       3. Remove the intentionally invalid unsafe approvals so the final
          test database again satisfies the production invariant.
       4. Prove the final test-space state has only 1 approved booking.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Defensive restore in case the unsafe Session A window was closed
   before it could re-enable the trigger. */
IF OBJECT_ID(N'dbo.trg_booking_requests_validate', N'TR') IS NOT NULL
BEGIN
    ENABLE TRIGGER dbo.trg_booking_requests_validate
    ON dbo.booking_requests;
END;
GO

/* ---------------------------------------------------------------------
   1. Detailed state before cleanup
   --------------------------------------------------------------------- */
SELECT
    CASE
        WHEN requested_start_time = '2035-01-15T09:00:00' THEN N'UNSAFE A'
        WHEN requested_start_time = '2035-01-15T10:00:00' THEN N'UNSAFE B'
        WHEN requested_start_time = '2035-01-16T09:00:00' THEN N'SAFE A'
        WHEN requested_start_time = '2035-01-16T10:00:00' THEN N'SAFE B'
    END AS test_booking,
    booking_id,
    requester_id,
    requested_start_time,
    requested_end_time,
    booking_status
FROM dbo.booking_requests
WHERE space_code = 'CONC-G10'
ORDER BY requested_start_time;
GO

/* ---------------------------------------------------------------------
   2. Negative test proof: WITHOUT concurrency control

   Expected approved_count = 2.
   --------------------------------------------------------------------- */
SELECT
    N'UNSAFE pair' AS scenario,
    COUNT(*) AS total_bookings,
    SUM(CASE WHEN booking_status = N'approved' THEN 1 ELSE 0 END) AS approved_count,
    CASE
        WHEN SUM(CASE WHEN booking_status = N'approved' THEN 1 ELSE 0 END) = 2
            THEN N'PASS - race condition reproduced: both overlapping bookings were approved.'
        ELSE N'FAIL - expected both UNSAFE bookings to be approved.'
    END AS test_result
FROM dbo.booking_requests
WHERE space_code = 'CONC-G10'
  AND requested_start_time >= '2035-01-15T00:00:00'
  AND requested_start_time <  '2035-01-16T00:00:00';
GO

/* Explicitly prove that the two UNSAFE approved rows overlap. */
SELECT
    b1.booking_id AS booking_id_1,
    b2.booking_id AS booking_id_2,
    b1.space_code,
    b1.requested_start_time AS booking_1_start,
    b1.requested_end_time AS booking_1_end,
    b2.requested_start_time AS booking_2_start,
    b2.requested_end_time AS booking_2_end,
    N'PASS - forbidden approved overlap exists in the UNSAFE scenario.' AS test_result
FROM dbo.booking_requests AS b1
INNER JOIN dbo.booking_requests AS b2
    ON b2.space_code = b1.space_code
   AND b2.booking_id > b1.booking_id
   AND b1.requested_start_time < b2.requested_end_time
   AND b1.requested_end_time > b2.requested_start_time
WHERE b1.space_code = 'CONC-G10'
  AND b1.requested_start_time >= '2035-01-15T00:00:00'
  AND b1.requested_start_time <  '2035-01-16T00:00:00'
  AND b1.booking_status IN (N'approved', N'checked in')
  AND b2.booking_status IN (N'approved', N'checked in');
GO

/* ---------------------------------------------------------------------
   3. Positive test proof: WITH concurrency control

   Expected:
       SAFE A = approved
       SAFE B = pending
       approved_count = 1
   --------------------------------------------------------------------- */
SELECT
    N'SAFE pair' AS scenario,
    COUNT(*) AS total_bookings,
    SUM(CASE WHEN booking_status = N'approved' THEN 1 ELSE 0 END) AS approved_count,
    SUM(CASE WHEN booking_status = N'pending'  THEN 1 ELSE 0 END) AS pending_count,
    CASE
        WHEN SUM(CASE WHEN booking_status = N'approved' THEN 1 ELSE 0 END) = 1
         AND SUM(CASE WHEN booking_status = N'pending'  THEN 1 ELSE 0 END) = 1
            THEN N'PASS - concurrency control allowed exactly one approval.'
        ELSE N'FAIL - expected exactly one SAFE booking approved and one pending.'
    END AS test_result
FROM dbo.booking_requests
WHERE space_code = 'CONC-G10'
  AND requested_start_time >= '2035-01-16T00:00:00'
  AND requested_start_time <  '2035-01-17T00:00:00';
GO

/* This should return ZERO rows: there cannot be an overlapping pair if
   only one SAFE request reached approved status. */
SELECT
    b1.booking_id AS booking_id_1,
    b2.booking_id AS booking_id_2,
    b1.space_code
FROM dbo.booking_requests AS b1
INNER JOIN dbo.booking_requests AS b2
    ON b2.space_code = b1.space_code
   AND b2.booking_id > b1.booking_id
   AND b1.requested_start_time < b2.requested_end_time
   AND b1.requested_end_time > b2.requested_start_time
WHERE b1.space_code = 'CONC-G10'
  AND b1.requested_start_time >= '2035-01-16T00:00:00'
  AND b1.requested_start_time <  '2035-01-17T00:00:00'
  AND b1.booking_status IN (N'approved', N'checked in')
  AND b2.booking_status IN (N'approved', N'checked in');
GO

/* ---------------------------------------------------------------------
   4. Cleanup only the intentionally invalid UNSAFE approvals.

   The result sets above preserve the evidence of the anomaly. After the
   evidence is displayed, restore those two requests to pending so the
   database is not deliberately left in an invalid state.
   --------------------------------------------------------------------- */
BEGIN TRY
    BEGIN TRANSACTION;

    DELETE a
    FROM dbo.approvals AS a
    INNER JOIN dbo.booking_requests AS br
        ON br.booking_id = a.booking_id
    WHERE br.space_code = 'CONC-G10'
      AND br.requested_start_time >= '2035-01-15T00:00:00'
      AND br.requested_start_time <  '2035-01-16T00:00:00';

    UPDATE dbo.booking_requests
    SET booking_status = N'pending'
    WHERE space_code = 'CONC-G10'
      AND requested_start_time >= '2035-01-15T00:00:00'
      AND requested_start_time <  '2035-01-16T00:00:00';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

/* ---------------------------------------------------------------------
   5. FINAL proof required by the deliverable:
      only one test booking remains approved.
   --------------------------------------------------------------------- */
SELECT
    COUNT(*) AS total_test_bookings,
    SUM(CASE WHEN booking_status = N'approved' THEN 1 ELSE 0 END) AS approved_count,
    CASE
        WHEN SUM(CASE WHEN booking_status = N'approved' THEN 1 ELSE 0 END) = 1
            THEN N'PASS - FINAL STATE: only one CONC-G10 booking is approved.'
        ELSE N'FAIL - FINAL STATE should contain exactly one approved CONC-G10 booking.'
    END AS final_test_result
FROM dbo.booking_requests
WHERE space_code = 'CONC-G10';
GO

SELECT
    booking_id,
    requester_id,
    requested_start_time,
    requested_end_time,
    booking_status
FROM dbo.booking_requests
WHERE space_code = 'CONC-G10'
ORDER BY requested_start_time;
GO

/* Production invariant check from deliverable 12.
   Expected: 0 rows, assuming no unrelated invalid data exists. */
EXEC dbo.usp_verify_no_overlapping_approved_bookings;
GO

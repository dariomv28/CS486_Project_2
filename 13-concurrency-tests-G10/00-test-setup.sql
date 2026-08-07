/* =====================================================================
   File: 00-test-setup.sql
   Deliverable: 13-concurrency-tests-G10
   DBMS: Microsoft SQL Server

   Purpose:
       Prepare deterministic data for the unsafe and safe concurrency
       demonstrations.

   Prerequisites:
       05-db-definition-G10.sql
       06-sample-data-G10.sql
       10-schema-migration-G10.sql
       12-concurrency-implementation-G10.sql
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------
   1. Preconditions
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NULL
    THROW 52300, 'dbo.booking_requests was not found.', 1;

IF OBJECT_ID(N'dbo.approvals', N'U') IS NULL
    THROW 52301, 'dbo.approvals was not found.', 1;

IF OBJECT_ID(N'dbo.space_type_policies', N'U') IS NULL
    THROW 52302, 'Run 10-schema-migration-G10.sql before this test.', 1;

IF OBJECT_ID(N'dbo.usp_approve_booking', N'P') IS NULL
    THROW 52303, 'Run 12-concurrency-implementation-G10.sql before this test.', 1;

IF OBJECT_ID(N'dbo.usp_approve_booking_core', N'P') IS NULL
    THROW 52304, 'dbo.usp_approve_booking_core was not found.', 1;

IF COL_LENGTH(N'dbo.booking_requests', N'version_token') IS NULL
    THROW 52305, 'booking_requests.version_token was not found.', 1;

IF COL_LENGTH(N'dbo.approvals', N'decision_method') IS NULL
    THROW 52306, 'approvals.decision_method was not found.', 1;

IF NOT EXISTS (
    SELECT 1
    FROM dbo.users
    WHERE user_id = 'U001'
      AND account_status = N'active'
)
    THROW 52307, 'Required active test user U001 was not found.', 1;

IF NOT EXISTS (
    SELECT 1
    FROM dbo.users
    WHERE user_id = 'U002'
      AND account_status = N'active'
)
    THROW 52308, 'Required active test user U002 was not found.', 1;

IF NOT EXISTS (
    SELECT 1
    FROM dbo.users
    WHERE user_id = 'FS001'
      AND role IN (N'facility staff', N'facility manager')
      AND account_status = N'active'
)
    THROW 52309, 'Required active facility staff FS001 was not found.', 1;

IF NOT EXISTS (
    SELECT 1
    FROM dbo.users
    WHERE user_id = 'FS002'
      AND role IN (N'facility staff', N'facility manager')
      AND account_status = N'active'
)
    THROW 52310, 'Required active facility staff FS002 was not found.', 1;
GO

/* ---------------------------------------------------------------------
   2. Always restore the validation trigger before resetting data.
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.trg_booking_requests_validate', N'TR') IS NOT NULL
BEGIN
    ENABLE TRIGGER dbo.trg_booking_requests_validate
    ON dbo.booking_requests;
END;
GO

/* ---------------------------------------------------------------------
   3. Dedicated test space.

   meeting room already exists in space_type_policies after migration
   because Phase 1 sample data contains D101.
   --------------------------------------------------------------------- */
IF NOT EXISTS (
    SELECT 1
    FROM dbo.space_type_policies
    WHERE space_type = N'meeting room'
)
BEGIN
    THROW 52311,
          'Space type policy for meeting room was not found.',
          1;
END;
GO

/* Remove prior test bookings. Related approval and acknowledgement rows
   are removed through the booking foreign-key cascades. */
DELETE FROM dbo.booking_requests
WHERE space_code = 'CONC-G10';
GO

IF NOT EXISTS (
    SELECT 1
    FROM dbo.spaces
    WHERE space_code = 'CONC-G10'
)
BEGIN
    INSERT INTO dbo.spaces (
        space_code,
        space_name,
        space_type,
        building,
        floor,
        room_number,
        capacity,
        current_status,
        usage_policy
    )
    VALUES (
        'CONC-G10',
        N'G10 Concurrency Test Room',
        N'meeting room',
        N'Concurrency Test Building',
        '1',
        'G10',
        50,
        N'available',
        N'Dedicated only to the G10 concurrency test scripts.'
    );
END
ELSE
BEGIN
    UPDATE dbo.spaces
    SET current_status = N'available',
        capacity = 50,
        usage_policy = N'Dedicated only to the G10 concurrency test scripts.'
    WHERE space_code = 'CONC-G10';
END;
GO

/* The dedicated test space must not have active out-of-service
   maintenance, otherwise the approval implementation is expected to
   reject the booking for maintenance rather than concurrency. */
IF EXISTS (
    SELECT 1
    FROM dbo.maintenance_records
    WHERE space_code = 'CONC-G10'
      AND impact_level = N'out-of-service'
      AND maintenance_status IN (N'reported', N'assigned', N'in progress')
)
BEGIN
    THROW 52312,
          'CONC-G10 has active out-of-service maintenance. Remove it before the test.',
          1;
END;
GO

/* ---------------------------------------------------------------------
   4. Insert four pending bookings.

   UNSAFE pair: 2035-01-15, overlaps 10:00-11:00
   SAFE pair:   2035-01-16, overlaps 10:00-11:00
   --------------------------------------------------------------------- */
INSERT INTO dbo.booking_requests (
    requester_id,
    space_code,
    requested_start_time,
    requested_end_time,
    purpose_of_use,
    expected_participants,
    booking_status,
    created_at
)
VALUES
(
    'U001', 'CONC-G10',
    '2035-01-15T09:00:00', '2035-01-15T11:00:00',
    N'meeting', 10, N'pending', SYSDATETIME()
),
(
    'U002', 'CONC-G10',
    '2035-01-15T10:00:00', '2035-01-15T12:00:00',
    N'meeting', 10, N'pending', SYSDATETIME()
),
(
    'U001', 'CONC-G10',
    '2035-01-16T09:00:00', '2035-01-16T11:00:00',
    N'meeting', 10, N'pending', SYSDATETIME()
),
(
    'U002', 'CONC-G10',
    '2035-01-16T10:00:00', '2035-01-16T12:00:00',
    N'meeting', 10, N'pending', SYSDATETIME()
);
GO

/* ---------------------------------------------------------------------
   5. Show deterministic IDs and ROWVERSION values.
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
    space_code,
    requested_start_time,
    requested_end_time,
    booking_status,
    CONVERT(BINARY(8), version_token) AS version_token
FROM dbo.booking_requests
WHERE space_code = 'CONC-G10'
ORDER BY requested_start_time;
GO

PRINT 'Setup complete.';
PRINT 'Next: run 01-race-condition-session-A.sql in Session A.';
GO

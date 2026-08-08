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

/* =====================================================================
   6. TEST 2 DATA — automatic approval vs staff approval

   Space:
       CONC-AUTO-G10 (meeting room => instant_approval_enabled = 1)

   Pre-created pending booking (approved later by staff Session A):
       AUTO-STAFF-A: U001, 2035-02-15 09:00-11:00

   Session B (08-auto-vs-staff-session-B.sql) will submit a NEW
   overlapping request 10:00-12:00 through dbo.usp_submit_booking with
   @usage_policy_satisfied = 1, so it attempts automatic approval.
   ===================================================================== */

DELETE FROM dbo.booking_requests
WHERE space_code = 'CONC-AUTO-G10';
GO

IF NOT EXISTS (
    SELECT 1
    FROM dbo.spaces
    WHERE space_code = 'CONC-AUTO-G10'
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
        'CONC-AUTO-G10',
        N'G10 Automatic-vs-Staff Test Room',
        N'meeting room',
        N'Concurrency Test Building',
        '1',
        'G10A',
        30,
        N'available',
        N'Dedicated only to the G10 automatic-vs-staff concurrency test.'
    );
END
ELSE
BEGIN
    UPDATE dbo.spaces
    SET space_type = N'meeting room',
        capacity = 30,
        current_status = N'available'
    WHERE space_code = 'CONC-AUTO-G10';
END;
GO

IF EXISTS (
    SELECT 1
    FROM dbo.maintenance_records
    WHERE space_code = 'CONC-AUTO-G10'
      AND impact_level = N'out-of-service'
      AND maintenance_status IN (N'reported', N'assigned', N'in progress')
)
BEGIN
    THROW 52313,
          'CONC-AUTO-G10 has active out-of-service maintenance. Remove it before the test.',
          1;
END;
GO

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
    'U001', 'CONC-AUTO-G10',
    '2035-02-15T09:00:00', '2035-02-15T11:00:00',
    N'meeting', 10, N'pending', SYSDATETIME()
);
GO

/* =====================================================================
   7. TEST 3 DATA — maintenance escalation vs booking approval

   Space:
       CONC-MAINT-G10

   Two independent day-scoped scenarios on the same space:

       Test 3A (approval wins first):
           booking MAINT-3A: U001, 2035-03-01 10:00-12:00 (pending)
           maintenance M1:   advisory, 2035-03-01 09:00-17:00

       Test 3B (escalation wins first):
           booking MAINT-3B: U002, 2035-03-02 10:00-12:00 (pending)
           maintenance M2:   advisory, 2035-03-02 09:00-17:00

   Both maintenance windows are bounded to their own day, so escalating
   M1 to out-of-service in Test 3A cannot interfere with Test 3B.

   The advisory records are ACTIVE (status = in progress) and OVERLAP
   the bookings, but advisory maintenance does not block approval.
   The concurrency tests race the escalation advisory -> out-of-service
   against booking approval.
   ===================================================================== */

DELETE FROM dbo.booking_requests
WHERE space_code = 'CONC-MAINT-G10';
GO

/* Maintenance cleanup. maintenance_impact_history and
   maintenance_assignments reference maintenance_records without
   ON DELETE CASCADE, so remove children first. */
DELETE mih
FROM dbo.maintenance_impact_history AS mih
INNER JOIN dbo.maintenance_records AS mr
    ON mr.maintenance_id = mih.maintenance_id
WHERE mr.space_code = 'CONC-MAINT-G10';
GO

IF OBJECT_ID(N'dbo.maintenance_assignments', N'U') IS NOT NULL
BEGIN
    DELETE ma
    FROM dbo.maintenance_assignments AS ma
    INNER JOIN dbo.maintenance_records AS mr
        ON mr.maintenance_id = ma.maintenance_id
    WHERE mr.space_code = 'CONC-MAINT-G10';
END;
GO

DELETE FROM dbo.maintenance_records
WHERE space_code = 'CONC-MAINT-G10';
GO

IF NOT EXISTS (
    SELECT 1
    FROM dbo.spaces
    WHERE space_code = 'CONC-MAINT-G10'
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
        'CONC-MAINT-G10',
        N'G10 Maintenance-vs-Approval Test Room',
        N'meeting room',
        N'Concurrency Test Building',
        '1',
        'G10M',
        30,
        N'available',
        N'Dedicated only to the G10 maintenance-vs-approval concurrency test.'
    );
END
ELSE
BEGIN
    UPDATE dbo.spaces
    SET space_type = N'meeting room',
        capacity = 30,
        current_status = N'available'
    WHERE space_code = 'CONC-MAINT-G10';
END;
GO

/* Pending bookings. Direct insert keeps the setup deterministic; the
   validation trigger allows pending bookings that overlap only
   advisory maintenance. */
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
    'U001', 'CONC-MAINT-G10',
    '2035-03-01T10:00:00', '2035-03-01T12:00:00',
    N'meeting', 10, N'pending', SYSDATETIME()
),
(
    'U002', 'CONC-MAINT-G10',
    '2035-03-02T10:00:00', '2035-03-02T12:00:00',
    N'meeting', 10, N'pending', SYSDATETIME()
);
GO

/* Advisory maintenance records M1 and M2.

   Direct insert is acceptable here: the maintenance trigger records
   the INITIAL impact level using reporter_id and does not require
   SESSION_CONTEXT for inserts (only for impact-level UPDATES). */
INSERT INTO dbo.maintenance_records (
    space_code,
    facility_id,
    reporter_id,
    problem_type,
    problem_description,
    impact_level,
    start_time,
    completion_time,
    maintenance_status,
    result_note
)
VALUES
(
    'CONC-MAINT-G10', NULL, 'FS001',
    N'air-conditioning failure',
    N'G10 Test 3A advisory maintenance (approval wins first).',
    N'advisory',
    '2035-03-01T09:00:00', '2035-03-01T17:00:00',
    N'in progress', NULL
),
(
    'CONC-MAINT-G10', NULL, 'FS001',
    N'air-conditioning failure',
    N'G10 Test 3B advisory maintenance (escalation wins first).',
    N'advisory',
    '2035-03-02T09:00:00', '2035-03-02T17:00:00',
    N'in progress', NULL
);
GO

/* =====================================================================
   8. TEST 4 DATA — two staff, stale decision (ROWVERSION)

   Space:
       CONC-RV-G10

   Booking:
       RV: U001, 2035-04-01 13:00-15:00 (pending)

   Both sessions read the same version_token before either one writes.
   ===================================================================== */

DELETE FROM dbo.booking_requests
WHERE space_code = 'CONC-RV-G10';
GO

IF NOT EXISTS (
    SELECT 1
    FROM dbo.spaces
    WHERE space_code = 'CONC-RV-G10'
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
        'CONC-RV-G10',
        N'G10 ROWVERSION Test Room',
        N'meeting room',
        N'Concurrency Test Building',
        '1',
        'G10R',
        30,
        N'available',
        N'Dedicated only to the G10 stale-decision concurrency test.'
    );
END
ELSE
BEGIN
    UPDATE dbo.spaces
    SET space_type = N'meeting room',
        capacity = 30,
        current_status = N'available'
    WHERE space_code = 'CONC-RV-G10';
END;
GO

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
    'U001', 'CONC-RV-G10',
    '2035-04-01T13:00:00', '2035-04-01T15:00:00',
    N'meeting', 10, N'pending', SYSDATETIME()
);
GO

/* =====================================================================
   9. Summary of extended test data.
   ===================================================================== */

SELECT
    CASE br.space_code
        WHEN 'CONC-AUTO-G10'  THEN N'TEST 2 — AUTO-STAFF-A (staff target)'
        WHEN 'CONC-MAINT-G10' THEN
            CASE
                WHEN br.requested_start_time = '2035-03-01T10:00:00'
                    THEN N'TEST 3A — MAINT booking (approval first)'
                ELSE N'TEST 3B — MAINT booking (escalation first)'
            END
        WHEN 'CONC-RV-G10'    THEN N'TEST 4 — RV booking'
    END AS test_booking,
    br.booking_id,
    br.requester_id,
    br.space_code,
    br.requested_start_time,
    br.requested_end_time,
    br.booking_status,
    CONVERT(BINARY(8), br.version_token) AS version_token
FROM dbo.booking_requests AS br
WHERE br.space_code IN ('CONC-AUTO-G10', 'CONC-MAINT-G10', 'CONC-RV-G10')
ORDER BY br.space_code, br.requested_start_time;
GO

SELECT
    CASE
        WHEN mr.start_time = '2035-03-01T09:00:00' THEN N'TEST 3A — M1'
        ELSE N'TEST 3B — M2'
    END AS test_maintenance,
    mr.maintenance_id,
    mr.space_code,
    mr.impact_level,
    mr.maintenance_status,
    mr.start_time,
    mr.completion_time
FROM dbo.maintenance_records AS mr
WHERE mr.space_code = 'CONC-MAINT-G10'
ORDER BY mr.start_time;
GO

PRINT 'Setup complete.';
PRINT 'Test 1 (unsafe):  Session A -> 01, Session B -> 02.';
PRINT 'Test 1 (safe):    Session A -> 03, Session B -> 04.';
PRINT 'Sanity:           06-automatic-approval-test.sql.';
PRINT 'Test 2:           Session A -> 07, Session B -> 08.';
PRINT 'Test 3A:          Session A -> 09, Session B -> 10.';
PRINT 'Test 3B:          Session A -> 11, Session B -> 12.';
PRINT 'Test 4:           Session A -> 13, Session B -> 14.';
PRINT 'Verification:     05-verify-results.sql then 15-verify-extended-results.sql.';
GO

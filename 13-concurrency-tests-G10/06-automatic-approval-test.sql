/* =====================================================================
   File: 06-automatic-approval-test.sql
   Deliverable: 13-concurrency-tests-G10
   DBMS: Microsoft SQL Server

   Purpose:
       Demonstrate that a booking for an instant-approval-enabled space
       type is automatically approved at submission time.

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
   1. Verify prerequisites.
   --------------------------------------------------------------------- */

IF NOT EXISTS (
    SELECT 1
    FROM dbo.space_type_policies
    WHERE space_type = N'meeting room'
      AND instant_approval_enabled = 1
)
BEGIN
    THROW 52350,
          'Instant approval is not enabled for meeting room.',
          1;
END;

IF OBJECT_ID(N'dbo.usp_submit_booking', N'P') IS NULL
BEGIN
    THROW 52351,
          'Run 12-concurrency-implementation-G10.sql before this test.',
          1;
END;

IF NOT EXISTS (
    SELECT 1
    FROM dbo.users
    WHERE user_id = 'U001'
      AND account_status = N'active'
)
BEGIN
    THROW 52352,
          'Required active test user U001 was not found.',
          1;
END;
GO

/* ---------------------------------------------------------------------
   2. Create a dedicated automatic-approval test room.
   --------------------------------------------------------------------- */

DELETE FROM dbo.booking_requests
WHERE space_code = 'AUTO-G10';
GO

IF NOT EXISTS (
    SELECT 1
    FROM dbo.spaces
    WHERE space_code = 'AUTO-G10'
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
        'AUTO-G10',
        N'G10 Automatic Approval Test Room',
        N'meeting room',
        N'Test Building',
        '1',
        'AUTO',
        30,
        N'available',
        N'Standard meeting-room usage policy.'
    );
END
ELSE
BEGIN
    UPDATE dbo.spaces
    SET
        space_type = N'meeting room',
        capacity = 30,
        current_status = N'available'
    WHERE space_code = 'AUTO-G10';
END;
GO

/* ---------------------------------------------------------------------
   3. Submit booking.

   The acknowledgement list is empty because the dedicated test room
   has no advisory maintenance.
   --------------------------------------------------------------------- */

DECLARE @acknowledgements dbo.maintenance_id_list;
DECLARE @booking_id INT;
DECLARE @booking_status NVARCHAR(30);
DECLARE @version_token BINARY(8);

EXEC dbo.usp_submit_booking
    @requester_id = 'U001',
    @space_code = 'AUTO-G10',
    @requested_start_time = '2035-02-01T09:00:00',
    @requested_end_time = '2035-02-01T11:00:00',
    @purpose_of_use = N'meeting',
    @expected_participants = 10,
    @usage_policy_satisfied = 1,
    @acknowledged_advisories = @acknowledgements,
    @booking_id = @booking_id OUTPUT,
    @booking_status = @booking_status OUTPUT,
    @version_token = @version_token OUTPUT;

/* ---------------------------------------------------------------------
   4. Verify automatic approval result.
   --------------------------------------------------------------------- */

IF @booking_status <> N'approved'
   OR NOT EXISTS (
       SELECT 1
       FROM dbo.approvals AS a
       WHERE a.booking_id = @booking_id
         AND a.decision = N'approved'
         AND a.decision_method = N'automatic'
         AND a.staff_id IS NULL
   )
BEGIN
    THROW 52353,
          'The booking was not automatically approved as expected.',
          1;
END;

SELECT
    br.booking_id,
    br.booking_status,
    a.decision,
    a.decision_method,
    a.staff_id,
    a.decision_time
FROM dbo.booking_requests AS br
INNER JOIN dbo.approvals AS a
    ON a.booking_id = br.booking_id
WHERE br.booking_id = @booking_id;
GO

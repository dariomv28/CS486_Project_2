/* =====================================================================
   File: 12-concurrency-implementation-G10.sql
   Course: CS486 - Introduction to Database System
   Group: G10
   DBMS: Microsoft SQL Server

   Purpose:
       Implement the Phase 2 concurrency-control solution.

   Main strategy:
       1. Use explicit SQL Server transactions.
       2. Use transaction-owned sp_getapplock resources per space_code.
       3. Revalidate booking conflicts after obtaining the lock.
       4. Revalidate out-of-service maintenance after obtaining the lock.
       5. Use ROWVERSION to detect stale updates to the same booking.
       6. Use one approval core for both automatic and staff approval.
       7. Coordinate maintenance escalation with booking approval.
       8. Coordinate space closure with booking approval.
       9. Require advisory acknowledgement at booking submission time.
      10. Prevent application users from bypassing stored procedures.

   Lock resource:
       CampusSpaceBooking:<space_code>

   Important:
       Execute 10-schema-migration-G10.sql before this script.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO


/* =====================================================================
   1. PRE-IMPLEMENTATION VALIDATION
   ===================================================================== */

IF OBJECT_ID(N'dbo.users', N'U') IS NULL
    THROW 52200, 'Table dbo.users was not found.', 1;

IF OBJECT_ID(N'dbo.spaces', N'U') IS NULL
    THROW 52201, 'Table dbo.spaces was not found.', 1;

IF OBJECT_ID(N'dbo.space_type_policies', N'U') IS NULL
    THROW 52202, 'Table dbo.space_type_policies was not found.', 1;

IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NULL
    THROW 52203, 'Table dbo.booking_requests was not found.', 1;

IF OBJECT_ID(N'dbo.approvals', N'U') IS NULL
    THROW 52204, 'Table dbo.approvals was not found.', 1;

IF OBJECT_ID(N'dbo.maintenance_records', N'U') IS NULL
    THROW 52205, 'Table dbo.maintenance_records was not found.', 1;

IF OBJECT_ID(
       N'dbo.booking_advisory_acknowledgements',
       N'U'
   ) IS NULL
BEGIN
    THROW 52206,
          'Table dbo.booking_advisory_acknowledgements was not found.',
          1;
END;

IF COL_LENGTH(
       N'dbo.booking_requests',
       N'version_token'
   ) IS NULL
BEGIN
    THROW 52207,
          'Column dbo.booking_requests.version_token was not found.',
          1;
END;

IF COL_LENGTH(
       N'dbo.approvals',
       N'decision_method'
   ) IS NULL
BEGIN
    THROW 52208,
          'Column dbo.approvals.decision_method was not found.',
          1;
END;

IF COL_LENGTH(
       N'dbo.maintenance_records',
       N'impact_level'
   ) IS NULL
BEGIN
    THROW 52209,
          'Column dbo.maintenance_records.impact_level was not found.',
          1;
END;
GO


/* =====================================================================
   2. TABLE TYPE FOR ACKNOWLEDGED ADVISORY IDs
   ===================================================================== */

IF TYPE_ID(N'dbo.maintenance_id_list') IS NULL
BEGIN
    EXEC (
        N'
        CREATE TYPE dbo.maintenance_id_list AS TABLE
        (
            maintenance_id INT NOT NULL,
            PRIMARY KEY (maintenance_id)
        );
        '
    );
END;
GO


/* =====================================================================
   3. INTERNAL APPROVAL CORE

   Must run inside an existing transaction.

   Both automatic approval and staff approval use this procedure.

   Advisory acknowledgement is NOT rechecked here.

   Reason:
       Phase 2 requires active advisories to be acknowledged at booking
       submission time. A new advisory appearing after submission should
       not make an already-valid pending booking permanently impossible
       to approve.

   Out-of-service maintenance IS rechecked here because it makes the room
   unavailable.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_approve_booking_core
    @booking_id                 INT,
    @decision_method            NVARCHAR(20),
    @staff_id                   VARCHAR(20) = NULL,
    @decision_note              NVARCHAR(MAX) = NULL,
    @usage_policy_satisfied     BIT = 0,
    @expected_version_token     BINARY(8) = NULL,
    @lock_timeout_ms            INT = 10000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT = 0
    BEGIN
        THROW 52210,
              'usp_approve_booking_core requires an active transaction.',
              1;
    END;


    IF @decision_method NOT IN (
        N'automatic',
        N'staff'
    )
    BEGIN
        THROW 52211,
              'Invalid approval decision method.',
              1;
    END;


    IF @lock_timeout_ms < 0
    BEGIN
        THROW 52212,
              'Application-lock timeout cannot be negative.',
              1;
    END;


    /*
        Fix 1:
        Staff approval must always provide a ROWVERSION.
        Automatic approval may omit it because the booking has just been
        created inside the same transaction.
    */
    IF @decision_method = N'staff'
       AND @expected_version_token IS NULL
    BEGIN
        THROW 52213,
              'Expected version token is required for staff approval.',
              1;
    END;


    DECLARE @initial_space_code VARCHAR(20);
    DECLARE @space_code VARCHAR(20);
    DECLARE @requester_id VARCHAR(20);

    DECLARE @requested_start_time DATETIME2(0);
    DECLARE @requested_end_time DATETIME2(0);

    DECLARE @expected_participants INT;
    DECLARE @booking_status NVARCHAR(30);

    DECLARE @current_version_token BINARY(8);

    DECLARE @space_status NVARCHAR(30);
    DECLARE @space_capacity INT;

    DECLARE @instant_approval_enabled BIT;

    DECLARE @lock_resource NVARCHAR(255);
    DECLARE @lock_result INT;


    /*
        Initial non-authoritative read.

        Only used to determine which logical application-lock resource
        must be acquired.
    */
    SELECT
        @initial_space_code = br.space_code
    FROM dbo.booking_requests AS br
    WHERE br.booking_id = @booking_id;


    IF @initial_space_code IS NULL
    BEGIN
        THROW 52214,
              'Booking request was not found.',
              1;
    END;


    SET @lock_resource =
        CONCAT(
            N'CampusSpaceBooking:',
            @initial_space_code
        );


    /*
        Exclusive application lock for this space.

        All operations affecting booking availability for the same space
        must use this exact resource.
    */
    EXEC @lock_result = sys.sp_getapplock
        @Resource = @lock_resource,
        @LockMode = N'Exclusive',
        @LockOwner = N'Transaction',
        @LockTimeout = @lock_timeout_ms;


    IF @lock_result < 0
    BEGIN
        THROW 52215,
              'Could not obtain the application lock for the space.',
              1;
    END;


    /*
        Authoritative read after obtaining the application lock.

        UPDLOCK:
            prevents concurrent decision changes on this booking.

        HOLDLOCK:
            retains the lock until transaction completion.
    */
    SELECT
        @space_code =
            br.space_code,

        @requester_id =
            br.requester_id,

        @requested_start_time =
            br.requested_start_time,

        @requested_end_time =
            br.requested_end_time,

        @expected_participants =
            br.expected_participants,

        @booking_status =
            br.booking_status,

        @current_version_token =
            CONVERT(
                BINARY(8),
                br.version_token
            ),

        @space_status =
            s.current_status,

        @space_capacity =
            s.capacity,

        @instant_approval_enabled =
            stp.instant_approval_enabled

    FROM dbo.booking_requests AS br
        WITH (UPDLOCK, HOLDLOCK)

    INNER JOIN dbo.spaces AS s
        ON s.space_code =
           br.space_code

    INNER JOIN dbo.space_type_policies AS stp
        ON stp.space_type =
           s.space_type

    WHERE br.booking_id =
          @booking_id;


    IF @space_code IS NULL
    BEGIN
        THROW 52216,
              'Booking disappeared during approval.',
              1;
    END;


    /*
        If somebody changed the booking's space between the initial read
        and lock acquisition, we currently hold the wrong logical lock.
    */
    IF @space_code <> @initial_space_code
    BEGIN
        THROW 52217,
              'Booking space changed concurrently. Retry the operation.',
              1;
    END;


    IF @booking_status <> N'pending'
    BEGIN
        THROW 52218,
              'Only a pending booking can be approved.',
              1;
    END;


    /*
        ROWVERSION stale-write check.

        For staff approval, @expected_version_token cannot be NULL because
        this was validated above.
    */
    IF @decision_method = N'staff'
       AND @expected_version_token <>
           @current_version_token
    BEGIN
        THROW 52219,
              'The booking was changed by another transaction.',
              1;
    END;


    /*
        Defensive check:
        one approval row per booking.
    */
    IF EXISTS (
        SELECT 1
        FROM dbo.approvals AS a
            WITH (UPDLOCK, HOLDLOCK)
        WHERE a.booking_id =
              @booking_id
    )
    BEGIN
        THROW 52220,
              'The booking already has an approval decision.',
              1;
    END;


    /*
        Requester must still have an active account.
    */
    IF NOT EXISTS (
        SELECT 1
        FROM dbo.users AS u
        WHERE u.user_id =
              @requester_id
          AND u.account_status =
              N'active'
    )
    BEGIN
        THROW 52221,
              'The booking requester is not active.',
              1;
    END;


    /*
        Space availability check.

        "under maintenance" is not checked directly because Phase 2
        availability depends on maintenance impact and interval.
    */
    IF @space_status IN (
        N'temporarily closed',
        N'retired'
    )
    BEGIN
        THROW 52222,
              'The selected space is closed or retired.',
              1;
    END;


    IF @expected_participants >
       @space_capacity
    BEGIN
        THROW 52223,
              'Expected participants exceed the space capacity.',
              1;
    END;


    /* -------------------------------------------------------------
       Validate approval actor.
       ------------------------------------------------------------- */

    IF @decision_method =
       N'staff'
    BEGIN
        IF @staff_id IS NULL
        BEGIN
            THROW 52224,
                  'Staff approval requires a staff ID.',
                  1;
        END;


        IF NOT EXISTS (
            SELECT 1
            FROM dbo.users AS u
            WHERE u.user_id =
                  @staff_id
              AND u.account_status =
                  N'active'
              AND u.role IN (
                  N'facility staff',
                  N'facility manager'
              )
        )
        BEGIN
            THROW 52225,
                  'Only active facility staff or managers may approve bookings.',
                  1;
        END;
    END;
    ELSE
    BEGIN

        IF @staff_id IS NOT NULL
        BEGIN
            THROW 52226,
                  'Automatic approval cannot have a staff actor.',
                  1;
        END;


        IF @instant_approval_enabled <> 1
        BEGIN
            THROW 52227,
                  'Instant approval is disabled for this space type.',
                  1;
        END;


        /*
            usage_policy is descriptive text in the current schema.
            Therefore it is evaluated by a trusted application/policy
            component.
        */
        IF @usage_policy_satisfied <> 1
        BEGIN
            THROW 52228,
                  'The booking does not satisfy the instant-approval policy.',
                  1;
        END;
    END;


    /* -------------------------------------------------------------
       Out-of-service maintenance check.
       ------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1
        FROM dbo.maintenance_records AS mr
        WHERE mr.space_code =
              @space_code

          AND mr.impact_level =
              N'out-of-service'

          AND mr.maintenance_status IN (
              N'reported',
              N'assigned',
              N'in progress'
          )

          AND @requested_start_time <
              COALESCE(
                  mr.completion_time,
                  CONVERT(
                      DATETIME2(0),
                      '9999-12-31 23:59:59'
                  )
              )

          AND @requested_end_time >
              mr.start_time
    )
    BEGIN
        THROW 52229,
              'The booking overlaps out-of-service maintenance.',
              1;
    END;


    /*
        IMPORTANT FIX 2:

        Do NOT recheck advisory acknowledgement here.

        Advisory acknowledgement belongs to booking submission time.

        If a new advisory appears after a booking has already been
        submitted, the pending booking remains eligible for later staff
        approval.

        However, if that maintenance becomes out-of-service, the check
        above will block the approval.
    */


    /* -------------------------------------------------------------
       Booking conflict check.
       ------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1
        FROM dbo.booking_requests AS existing
        WHERE existing.space_code =
              @space_code

          AND existing.booking_id <>
              @booking_id

          AND existing.booking_status IN (
              N'approved',
              N'checked in'
          )

          AND @requested_start_time <
              existing.requested_end_time

          AND @requested_end_time >
              existing.requested_start_time
    )
    BEGIN
        THROW 52230,
              'The booking conflicts with another approved booking.',
              1;
    END;


    /*
        Insert approval.

        The Phase 2 approval trigger synchronizes booking_status.
    */
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
        @booking_id,
        @staff_id,
        N'approved',
        @decision_method,
        SYSDATETIME(),
        @decision_note,
        NULL
    );


    /*
        Defensive verification that trigger synchronization succeeded.
    */
    IF NOT EXISTS (
        SELECT 1
        FROM dbo.booking_requests AS br
        WHERE br.booking_id =
              @booking_id
          AND br.booking_status =
              N'approved'
    )
    BEGIN
        THROW 52231,
              'Approval was stored but booking status was not synchronized.',
              1;
    END;
END;
GO


/* =====================================================================
   4. STAFF APPROVAL PROCEDURE
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_approve_booking
    @booking_id                 INT,
    @staff_id                   VARCHAR(20),
    @expected_version_token     BINARY(8),
    @decision_note              NVARCHAR(MAX) = NULL,
    @lock_timeout_ms            INT = 10000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    IF @@TRANCOUNT <> 0
    BEGIN
        THROW 52240,
              'usp_approve_booking must be called without an existing transaction.',
              1;
    END;


    /*
        FIX 1:
        Caller cannot bypass optimistic concurrency by passing NULL.
    */
    IF @expected_version_token IS NULL
    BEGIN
        THROW 52241,
              'Expected version token is required for staff approval.',
              1;
    END;


    BEGIN TRY

        BEGIN TRANSACTION;


        EXEC dbo.usp_approve_booking_core

            @booking_id =
                @booking_id,

            @decision_method =
                N'staff',

            @staff_id =
                @staff_id,

            @decision_note =
                @decision_note,

            @usage_policy_satisfied =
                0,

            @expected_version_token =
                @expected_version_token,

            @lock_timeout_ms =
                @lock_timeout_ms;


        COMMIT TRANSACTION;


        SELECT
            br.booking_id,
            br.space_code,
            br.requested_start_time,
            br.requested_end_time,
            br.booking_status,

            CONVERT(
                BINARY(8),
                br.version_token
            ) AS version_token,

            a.staff_id,
            a.decision,
            a.decision_method,
            a.decision_time,
            a.decision_note

        FROM dbo.booking_requests AS br

        INNER JOIN dbo.approvals AS a
            ON a.booking_id =
               br.booking_id

        WHERE br.booking_id =
              @booking_id;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;
END;
GO


/* =====================================================================
   5. STAFF REJECTION PROCEDURE

   Rejection does not create room-time conflicts.

   ROWVERSION + UPDLOCK protect the same booking row.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_reject_booking
    @booking_id                 INT,
    @staff_id                   VARCHAR(20),
    @expected_version_token     BINARY(8),
    @rejection_reason           NVARCHAR(MAX),
    @decision_note              NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    IF @@TRANCOUNT <> 0
    BEGIN
        THROW 52250,
              'usp_reject_booking must be called without an existing transaction.',
              1;
    END;


    /*
        FIX 1:
        Prevent NULL from bypassing ROWVERSION checking.
    */
    IF @expected_version_token IS NULL
    BEGIN
        THROW 52251,
              'Expected version token is required for staff rejection.',
              1;
    END;


    IF NULLIF(
           LTRIM(RTRIM(@rejection_reason)),
           N''
       ) IS NULL
    BEGIN
        THROW 52252,
              'A rejection reason is required.',
              1;
    END;


    BEGIN TRY

        BEGIN TRANSACTION;


        DECLARE @booking_status NVARCHAR(30);
        DECLARE @current_version_token BINARY(8);


        SELECT
            @booking_status =
                br.booking_status,

            @current_version_token =
                CONVERT(
                    BINARY(8),
                    br.version_token
                )

        FROM dbo.booking_requests AS br
            WITH (UPDLOCK, HOLDLOCK)

        WHERE br.booking_id =
              @booking_id;


        IF @booking_status IS NULL
        BEGIN
            THROW 52253,
                  'Booking request was not found.',
                  1;
        END;


        IF @booking_status <>
           N'pending'
        BEGIN
            THROW 52254,
                  'Only a pending booking can be rejected.',
                  1;
        END;


        IF @expected_version_token <>
           @current_version_token
        BEGIN
            THROW 52255,
                  'The booking was changed by another transaction.',
                  1;
        END;


        IF NOT EXISTS (
            SELECT 1
            FROM dbo.users AS u
            WHERE u.user_id =
                  @staff_id
              AND u.account_status =
                  N'active'
              AND u.role IN (
                  N'facility staff',
                  N'facility manager'
              )
        )
        BEGIN
            THROW 52256,
                  'Only active facility staff or managers may reject bookings.',
                  1;
        END;


        IF EXISTS (
            SELECT 1
            FROM dbo.approvals AS a
                WITH (UPDLOCK, HOLDLOCK)
            WHERE a.booking_id =
                  @booking_id
        )
        BEGIN
            THROW 52257,
                  'The booking already has an approval decision.',
                  1;
        END;


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
            @booking_id,
            @staff_id,
            N'rejected',
            N'staff',
            SYSDATETIME(),
            @decision_note,
            @rejection_reason
        );


        COMMIT TRANSACTION;


        SELECT
            br.booking_id,
            br.space_code,
            br.booking_status,

            CONVERT(
                BINARY(8),
                br.version_token
            ) AS version_token,

            a.staff_id,
            a.decision,
            a.decision_method,
            a.decision_time,
            a.decision_note,
            a.rejection_reason

        FROM dbo.booking_requests AS br

        INNER JOIN dbo.approvals AS a
            ON a.booking_id =
               br.booking_id

        WHERE br.booking_id =
              @booking_id;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;
END;
GO


/* =====================================================================
   6. BOOKING SUBMISSION PROCEDURE

   Advisory rule:
       Every advisory that is active and overlaps the requested booking
       period at submission time must be acknowledged.

   This is where acknowledgements are checked and stored.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_submit_booking
    @requester_id               VARCHAR(20),
    @space_code                 VARCHAR(20),
    @requested_start_time       DATETIME2(0),
    @requested_end_time         DATETIME2(0),
    @purpose_of_use             NVARCHAR(255),
    @expected_participants      INT,
    @usage_policy_satisfied     BIT,
    @acknowledged_advisories    dbo.maintenance_id_list READONLY,
    @booking_id                 INT OUTPUT,
    @booking_status             NVARCHAR(30) OUTPUT,
    @version_token              BINARY(8) OUTPUT,
    @lock_timeout_ms            INT = 10000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    IF @@TRANCOUNT <> 0
    BEGIN
        THROW 52260,
              'usp_submit_booking must be called without an existing transaction.',
              1;
    END;


    IF @requested_end_time <=
       @requested_start_time
    BEGIN
        THROW 52261,
              'Booking end time must be later than start time.',
              1;
    END;


    IF @expected_participants <= 0
    BEGIN
        THROW 52262,
              'Expected participants must be greater than zero.',
              1;
    END;


    IF NULLIF(
           LTRIM(RTRIM(@purpose_of_use)),
           N''
       ) IS NULL
    BEGIN
        THROW 52263,
              'Purpose of use is required.',
              1;
    END;


    IF @lock_timeout_ms < 0
    BEGIN
        THROW 52264,
              'Application-lock timeout cannot be negative.',
              1;
    END;


    SET @booking_id = NULL;
    SET @booking_status = NULL;
    SET @version_token = NULL;


    BEGIN TRY

        BEGIN TRANSACTION;


        DECLARE @canonical_space_code VARCHAR(20);
        DECLARE @space_status NVARCHAR(30);
        DECLARE @space_capacity INT;
        DECLARE @instant_approval_enabled BIT;

        DECLARE @lock_resource NVARCHAR(255);
        DECLARE @lock_result INT;


        /*
            Obtain canonical stored space code before constructing
            application lock name.
        */
        SELECT
            @canonical_space_code =
                s.space_code

        FROM dbo.spaces AS s

        WHERE s.space_code =
              @space_code;


        IF @canonical_space_code IS NULL
        BEGIN
            THROW 52265,
                  'The selected space was not found.',
                  1;
        END;


        SET @lock_resource =
            CONCAT(
                N'CampusSpaceBooking:',
                @canonical_space_code
            );


        /*
            Same space lock used by:
                - submission
                - automatic approval
                - staff approval
                - maintenance escalation
                - maintenance creation
                - space closure
        */
        EXEC @lock_result = sys.sp_getapplock
            @Resource = @lock_resource,
            @LockMode = N'Exclusive',
            @LockOwner = N'Transaction',
            @LockTimeout = @lock_timeout_ms;


        IF @lock_result < 0
        BEGIN
            THROW 52266,
                  'Could not obtain the application lock for the space.',
                  1;
        END;


        /* -------------------------------------------------------------
           Revalidate requester.
           ------------------------------------------------------------- */

        IF NOT EXISTS (
            SELECT 1
            FROM dbo.users AS u
            WHERE u.user_id =
                  @requester_id
              AND u.account_status =
                  N'active'
        )
        BEGIN
            THROW 52267,
                  'Only an active user can submit a booking.',
                  1;
        END;


        /* -------------------------------------------------------------
           Revalidate space.
           ------------------------------------------------------------- */

        SELECT
            @space_status =
                s.current_status,

            @space_capacity =
                s.capacity,

            @instant_approval_enabled =
                stp.instant_approval_enabled

        FROM dbo.spaces AS s

        INNER JOIN dbo.space_type_policies AS stp
            ON stp.space_type =
               s.space_type

        WHERE s.space_code =
              @canonical_space_code;


        IF @space_status IS NULL
        BEGIN
            THROW 52268,
                  'The selected space is invalid.',
                  1;
        END;


        IF @space_status IN (
            N'temporarily closed',
            N'retired'
        )
        BEGIN
            THROW 52269,
                  'A closed or retired space cannot be booked.',
                  1;
        END;


        IF @expected_participants >
           @space_capacity
        BEGIN
            THROW 52270,
                  'Expected participants exceed the space capacity.',
                  1;
        END;


        /* -------------------------------------------------------------
           Out-of-service maintenance.
           ------------------------------------------------------------- */

        IF EXISTS (
            SELECT 1
            FROM dbo.maintenance_records AS mr

            WHERE mr.space_code =
                  @canonical_space_code

              AND mr.impact_level =
                  N'out-of-service'

              AND mr.maintenance_status IN (
                  N'reported',
                  N'assigned',
                  N'in progress'
              )

              AND @requested_start_time <
                  COALESCE(
                      mr.completion_time,
                      CONVERT(
                          DATETIME2(0),
                          '9999-12-31 23:59:59'
                      )
                  )

              AND @requested_end_time >
                  mr.start_time
        )
        BEGIN
            THROW 52271,
                  'The booking overlaps out-of-service maintenance.',
                  1;
        END;


        /* -------------------------------------------------------------
           Find advisories that must be acknowledged.
           ------------------------------------------------------------- */

        DECLARE @required_advisories TABLE
        (
            maintenance_id INT NOT NULL
                PRIMARY KEY
        );


        INSERT INTO @required_advisories (
            maintenance_id
        )
        SELECT
            mr.maintenance_id

        FROM dbo.maintenance_records AS mr

        WHERE mr.space_code =
              @canonical_space_code

          AND mr.impact_level =
              N'advisory'

          AND mr.maintenance_status IN (
              N'reported',
              N'assigned',
              N'in progress'
          )

          AND @requested_start_time <
              COALESCE(
                  mr.completion_time,
                  CONVERT(
                      DATETIME2(0),
                      '9999-12-31 23:59:59'
                  )
              )

          AND @requested_end_time >
              mr.start_time;


        /*
            Every required advisory must appear in the acknowledgement
            list provided by the requester.
        */
        IF EXISTS (
            SELECT 1
            FROM @required_advisories AS required

            WHERE NOT EXISTS (
                SELECT 1
                FROM @acknowledged_advisories AS acknowledged

                WHERE acknowledged.maintenance_id =
                      required.maintenance_id
            )
        )
        BEGIN
            THROW 52272,
                  'Not all active advisories were acknowledged.',
                  1;
        END;


        /*
            Reject unrelated or forged acknowledgement IDs.
        */
        IF EXISTS (
            SELECT 1
            FROM @acknowledged_advisories AS acknowledged

            WHERE NOT EXISTS (
                SELECT 1
                FROM @required_advisories AS required

                WHERE required.maintenance_id =
                      acknowledged.maintenance_id
            )
        )
        BEGIN
            THROW 52273,
                  'One or more acknowledgement IDs are not relevant to this booking.',
                  1;
        END;


        /* -------------------------------------------------------------
           Create booking.
           ------------------------------------------------------------- */

        DECLARE @created_booking TABLE
        (
            booking_id INT NOT NULL,
            version_token BINARY(8) NOT NULL
        );


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

        OUTPUT
            inserted.booking_id,
            CONVERT(
                BINARY(8),
                inserted.version_token
            )

        INTO @created_booking (
            booking_id,
            version_token
        )

        VALUES (
            @requester_id,
            @canonical_space_code,
            @requested_start_time,
            @requested_end_time,
            @purpose_of_use,
            @expected_participants,
            N'pending',
            SYSDATETIME()
        );


        SELECT
            @booking_id =
                cb.booking_id,

            @version_token =
                cb.version_token

        FROM @created_booking AS cb;


        /* -------------------------------------------------------------
           Store acknowledgements.
           ------------------------------------------------------------- */

        INSERT INTO dbo.booking_advisory_acknowledgements (
            booking_id,
            maintenance_id,
            acknowledged_at
        )
        SELECT
            @booking_id,
            required.maintenance_id,
            SYSDATETIME()

        FROM @required_advisories AS required;


        /* -------------------------------------------------------------
           Automatic approval.
           ------------------------------------------------------------- */

        IF @instant_approval_enabled = 1
           AND @usage_policy_satisfied = 1
        BEGIN

            EXEC dbo.usp_approve_booking_core

                @booking_id =
                    @booking_id,

                @decision_method =
                    N'automatic',

                @staff_id =
                    NULL,

                @decision_note =
                    N'Automatically approved at submission time.',

                @usage_policy_satisfied =
                    1,

                @expected_version_token =
                    NULL,

                @lock_timeout_ms =
                    @lock_timeout_ms;

        END;


        SELECT
            @booking_status =
                br.booking_status,

            @version_token =
                CONVERT(
                    BINARY(8),
                    br.version_token
                )

        FROM dbo.booking_requests AS br

        WHERE br.booking_id =
              @booking_id;


        COMMIT TRANSACTION;


        SELECT
            br.booking_id,
            br.requester_id,
            br.space_code,
            br.requested_start_time,
            br.requested_end_time,
            br.purpose_of_use,
            br.expected_participants,
            br.booking_status,
            br.created_at,

            CONVERT(
                BINARY(8),
                br.version_token
            ) AS version_token,

            a.decision,
            a.decision_method,
            a.decision_time

        FROM dbo.booking_requests AS br

        LEFT JOIN dbo.approvals AS a
            ON a.booking_id =
               br.booking_id

        WHERE br.booking_id =
              @booking_id;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        SET @booking_id = NULL;
        SET @booking_status = NULL;
        SET @version_token = NULL;

        THROW;

    END CATCH;
END;
GO


/* =====================================================================
   7. MAINTENANCE IMPACT CHANGE

   Uses the SAME per-space application lock as booking approval.

   If escalation wins:
       later booking approval sees out-of-service maintenance and fails.

   If approval wins:
       escalation succeeds and returns affected bookings.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_change_maintenance_impact
    @maintenance_id                 INT,
    @new_impact_level               NVARCHAR(20),
    @changed_by                     VARCHAR(20),
    @change_reason                  NVARCHAR(MAX) = NULL,
    @expected_current_impact_level  NVARCHAR(20) = NULL,
    @lock_timeout_ms                INT = 10000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    IF @@TRANCOUNT <> 0
    BEGIN
        THROW 52280,
              'usp_change_maintenance_impact must be called without an existing transaction.',
              1;
    END;


    IF @new_impact_level NOT IN (
        N'advisory',
        N'out-of-service'
    )
    BEGIN
        THROW 52281,
              'Invalid maintenance impact level.',
              1;
    END;


    IF @lock_timeout_ms < 0
    BEGIN
        THROW 52282,
              'Application-lock timeout cannot be negative.',
              1;
    END;


    DECLARE @affected_bookings TABLE
    (
        booking_id INT NOT NULL
            PRIMARY KEY,

        requester_id VARCHAR(20) NOT NULL,
        requester_name NVARCHAR(255) NOT NULL,
        email NVARCHAR(255) NOT NULL,
        phone_number NVARCHAR(50) NULL,

        space_code VARCHAR(20) NOT NULL,

        requested_start_time DATETIME2(0) NOT NULL,
        requested_end_time DATETIME2(0) NOT NULL,

        maintenance_id INT NOT NULL
    );


    BEGIN TRY

        BEGIN TRANSACTION;


        DECLARE @initial_space_code VARCHAR(20);
        DECLARE @space_code VARCHAR(20);

        DECLARE @old_impact_level NVARCHAR(20);
        DECLARE @maintenance_status NVARCHAR(30);

        DECLARE @maintenance_start_time DATETIME2(0);
        DECLARE @maintenance_end_time DATETIME2(0);

        DECLARE @lock_resource NVARCHAR(255);
        DECLARE @lock_result INT;


        /*
            Initial read only determines logical lock resource.
        */
        SELECT
            @initial_space_code =
                mr.space_code

        FROM dbo.maintenance_records AS mr

        WHERE mr.maintenance_id =
              @maintenance_id;


        IF @initial_space_code IS NULL
        BEGIN
            THROW 52283,
                  'Maintenance record was not found.',
                  1;
        END;


        SET @lock_resource =
            CONCAT(
                N'CampusSpaceBooking:',
                @initial_space_code
            );


        EXEC @lock_result = sys.sp_getapplock
            @Resource = @lock_resource,
            @LockMode = N'Exclusive',
            @LockOwner = N'Transaction',
            @LockTimeout = @lock_timeout_ms;


        IF @lock_result < 0
        BEGIN
            THROW 52284,
                  'Could not obtain the application lock for the space.',
                  1;
        END;


        /*
            Authoritative maintenance read.
        */
        SELECT
            @space_code =
                mr.space_code,

            @old_impact_level =
                mr.impact_level,

            @maintenance_status =
                mr.maintenance_status,

            @maintenance_start_time =
                mr.start_time,

            @maintenance_end_time =
                mr.completion_time

        FROM dbo.maintenance_records AS mr
            WITH (UPDLOCK, HOLDLOCK)

        WHERE mr.maintenance_id =
              @maintenance_id;


        IF @space_code IS NULL
        BEGIN
            THROW 52285,
                  'Maintenance record disappeared during the update.',
                  1;
        END;


        IF @space_code <>
           @initial_space_code
        BEGIN
            THROW 52286,
                  'Maintenance space changed concurrently. Retry the operation.',
                  1;
        END;


        IF @maintenance_status NOT IN (
            N'reported',
            N'assigned',
            N'in progress'
        )
        BEGIN
            THROW 52287,
                  'Impact level can be changed only while maintenance is open.',
                  1;
        END;


        IF @old_impact_level =
           @new_impact_level
        BEGIN
            THROW 52288,
                  'The new impact level is the same as the current level.',
                  1;
        END;


        IF @expected_current_impact_level IS NOT NULL
           AND @expected_current_impact_level <>
               @old_impact_level
        BEGIN
            THROW 52289,
                  'Maintenance impact was changed by another transaction.',
                  1;
        END;


        IF NOT EXISTS (
            SELECT 1
            FROM dbo.users AS u

            WHERE u.user_id =
                  @changed_by

              AND u.account_status =
                  N'active'

              AND u.role IN (
                  N'facility staff',
                  N'facility manager'
              )
        )
        BEGIN
            THROW 52290,
                  'Only active facility staff or managers may change maintenance impact.',
                  1;
        END;


        /*
            Trigger created by migration uses SESSION_CONTEXT to create
            MAINTENANCE_IMPACT_HISTORY.
        */
        EXEC sys.sp_set_session_context
            @key =
                N'maintenance_changed_by',
            @value =
                @changed_by;


        EXEC sys.sp_set_session_context
            @key =
                N'maintenance_change_reason',
            @value =
                @change_reason;


        UPDATE dbo.maintenance_records

        SET impact_level =
            @new_impact_level

        WHERE maintenance_id =
              @maintenance_id;


        /*
            advisory -> out-of-service

            Return all already-approved overlapping bookings.
            They are not automatically cancelled.
        */
        IF @old_impact_level =
           N'advisory'

           AND @new_impact_level =
               N'out-of-service'
        BEGIN

            INSERT INTO @affected_bookings (
                booking_id,
                requester_id,
                requester_name,
                email,
                phone_number,
                space_code,
                requested_start_time,
                requested_end_time,
                maintenance_id
            )

            SELECT
                br.booking_id,
                br.requester_id,
                u.full_name,
                u.email,
                u.phone_number,
                br.space_code,
                br.requested_start_time,
                br.requested_end_time,
                @maintenance_id

            FROM dbo.booking_requests AS br

            INNER JOIN dbo.users AS u
                ON u.user_id =
                   br.requester_id

            WHERE br.space_code =
                  @space_code

              AND br.booking_status IN (
                  N'approved',
                  N'checked in'
              )

              AND br.requested_start_time <
                  COALESCE(
                      @maintenance_end_time,
                      CONVERT(
                          DATETIME2(0),
                          '9999-12-31 23:59:59'
                      )
                  )

              AND br.requested_end_time >
                  @maintenance_start_time;

        END;


        /*
            SESSION_CONTEXT is connection-scoped, so clear it manually.
        */
        EXEC sys.sp_set_session_context
            @key =
                N'maintenance_changed_by',
            @value =
                NULL;


        EXEC sys.sp_set_session_context
            @key =
                N'maintenance_change_reason',
            @value =
                NULL;


        COMMIT TRANSACTION;


        SELECT
            @maintenance_id
                AS maintenance_id,

            @old_impact_level
                AS previous_impact_level,

            @new_impact_level
                AS new_impact_level,

            @space_code
                AS space_code;


        SELECT
            booking_id,
            requester_id,
            requester_name,
            email,
            phone_number,
            space_code,
            requested_start_time,
            requested_end_time,
            maintenance_id

        FROM @affected_bookings

        ORDER BY
            requested_start_time,
            booking_id;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        /*
            SESSION_CONTEXT survives rollback, so clean it manually.
        */
        BEGIN TRY

            EXEC sys.sp_set_session_context
                @key =
                    N'maintenance_changed_by',
                @value =
                    NULL;


            EXEC sys.sp_set_session_context
                @key =
                    N'maintenance_change_reason',
                @value =
                    NULL;

        END TRY
        BEGIN CATCH

            PRINT N'Warning: maintenance SESSION_CONTEXT cleanup failed.';

        END CATCH;


        THROW;

    END CATCH;
END;
GO


/* =====================================================================
   8. CREATE MAINTENANCE RECORD

   New maintenance may race with booking approval.

   Therefore it also uses the same per-space application lock.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_create_maintenance_record
    @space_code                 VARCHAR(20),
    @facility_id                INT = NULL,
    @reporter_id                VARCHAR(20),
    @problem_type               NVARCHAR(100),
    @problem_description        NVARCHAR(MAX),
    @impact_level               NVARCHAR(20),
    @start_time                 DATETIME2(0),
    @completion_time            DATETIME2(0) = NULL,
    @maintenance_id             INT OUTPUT,
    @lock_timeout_ms            INT = 10000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    IF @@TRANCOUNT <> 0
    BEGIN
        THROW 52300,
              'usp_create_maintenance_record must be called without an existing transaction.',
              1;
    END;


    IF @impact_level NOT IN (
        N'advisory',
        N'out-of-service'
    )
    BEGIN
        THROW 52301,
              'Invalid maintenance impact level.',
              1;
    END;


    IF @completion_time IS NOT NULL
       AND @completion_time <=
           @start_time
    BEGIN
        THROW 52302,
              'Maintenance completion time must be later than start time.',
              1;
    END;


    IF NULLIF(
           LTRIM(RTRIM(@problem_type)),
           N''
       ) IS NULL
    BEGIN
        THROW 52303,
              'Maintenance problem type is required.',
              1;
    END;


    IF NULLIF(
           LTRIM(RTRIM(@problem_description)),
           N''
       ) IS NULL
    BEGIN
        THROW 52304,
              'Maintenance problem description is required.',
              1;
    END;


    IF @lock_timeout_ms < 0
    BEGIN
        THROW 52305,
              'Application-lock timeout cannot be negative.',
              1;
    END;


    SET @maintenance_id = NULL;


    DECLARE @affected_bookings TABLE
    (
        booking_id INT NOT NULL
            PRIMARY KEY,

        requester_id VARCHAR(20) NOT NULL,
        requester_name NVARCHAR(255) NOT NULL,

        email NVARCHAR(255) NOT NULL,
        phone_number NVARCHAR(50) NULL,

        space_code VARCHAR(20) NOT NULL,

        requested_start_time DATETIME2(0) NOT NULL,
        requested_end_time DATETIME2(0) NOT NULL
    );


    BEGIN TRY

        BEGIN TRANSACTION;


        DECLARE @canonical_space_code VARCHAR(20);
        DECLARE @lock_resource NVARCHAR(255);
        DECLARE @lock_result INT;


        SELECT
            @canonical_space_code =
                s.space_code

        FROM dbo.spaces AS s

        WHERE s.space_code =
              @space_code;


        IF @canonical_space_code IS NULL
        BEGIN
            THROW 52306,
                  'The selected space was not found.',
                  1;
        END;


        SET @lock_resource =
            CONCAT(
                N'CampusSpaceBooking:',
                @canonical_space_code
            );


        EXEC @lock_result = sys.sp_getapplock
            @Resource = @lock_resource,
            @LockMode = N'Exclusive',
            @LockOwner = N'Transaction',
            @LockTimeout = @lock_timeout_ms;


        IF @lock_result < 0
        BEGIN
            THROW 52307,
                  'Could not obtain the application lock for the space.',
                  1;
        END;


        IF NOT EXISTS (
            SELECT 1
            FROM dbo.users AS u

            WHERE u.user_id =
                  @reporter_id

              AND u.account_status =
                  N'active'
        )
        BEGIN
            THROW 52308,
                  'Only an active user may report maintenance.',
                  1;
        END;


        /*
            If facility-specific maintenance is used, verify that the
            facility belongs to the selected space.
        */
        IF @facility_id IS NOT NULL
           AND NOT EXISTS (
               SELECT 1

               FROM dbo.facility_instances AS fi

               WHERE fi.facility_id =
                     @facility_id

                 AND fi.space_code =
                     @canonical_space_code
           )
        BEGIN
            THROW 52309,
                  'The selected facility does not belong to the maintenance space.',
                  1;
        END;


        DECLARE @created_maintenance TABLE
        (
            maintenance_id INT NOT NULL
        );


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

        OUTPUT
            inserted.maintenance_id

        INTO @created_maintenance (
            maintenance_id
        )

        VALUES (
            @canonical_space_code,
            @facility_id,
            @reporter_id,
            @problem_type,
            @problem_description,
            @impact_level,
            @start_time,
            @completion_time,
            N'reported',
            NULL
        );


        SELECT
            @maintenance_id =
                cm.maintenance_id

        FROM @created_maintenance AS cm;


        /*
            If an out-of-service record is created, return already-approved
            bookings affected by it.
        */
        IF @impact_level =
           N'out-of-service'
        BEGIN

            INSERT INTO @affected_bookings (
                booking_id,
                requester_id,
                requester_name,
                email,
                phone_number,
                space_code,
                requested_start_time,
                requested_end_time
            )

            SELECT
                br.booking_id,
                br.requester_id,
                u.full_name,
                u.email,
                u.phone_number,
                br.space_code,
                br.requested_start_time,
                br.requested_end_time

            FROM dbo.booking_requests AS br

            INNER JOIN dbo.users AS u
                ON u.user_id =
                   br.requester_id

            WHERE br.space_code =
                  @canonical_space_code

              AND br.booking_status IN (
                  N'approved',
                  N'checked in'
              )

              AND br.requested_start_time <
                  COALESCE(
                      @completion_time,
                      CONVERT(
                          DATETIME2(0),
                          '9999-12-31 23:59:59'
                      )
                  )

              AND br.requested_end_time >
                  @start_time;

        END;


        COMMIT TRANSACTION;


        SELECT
            mr.maintenance_id,
            mr.space_code,
            mr.facility_id,
            mr.reporter_id,
            mr.problem_type,
            mr.problem_description,
            mr.impact_level,
            mr.start_time,
            mr.completion_time,
            mr.maintenance_status

        FROM dbo.maintenance_records AS mr

        WHERE mr.maintenance_id =
              @maintenance_id;


        SELECT
            booking_id,
            requester_id,
            requester_name,
            email,
            phone_number,
            space_code,
            requested_start_time,
            requested_end_time

        FROM @affected_bookings

        ORDER BY
            requested_start_time,
            booking_id;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        SET @maintenance_id =
            NULL;


        THROW;

    END CATCH;
END;
GO


/* =====================================================================
   9. CHANGE SPACE AVAILABILITY

   FIX 3/4:
       Changing a space to temporarily closed or retired may race with
       booking approval.

       Therefore this operation uses the SAME logical application lock:

           CampusSpaceBooking:<space_code>

   Only facility staff and facility managers may call the operation.

   "in use" and "under maintenance" are operational/derived states and
   should normally be controlled by usage and maintenance workflows.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_change_space_status
    @space_code                 VARCHAR(20),
    @new_status                 NVARCHAR(30),
    @changed_by                 VARCHAR(20),
    @lock_timeout_ms            INT = 10000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;


    IF @@TRANCOUNT <> 0
    BEGIN
        THROW 52320,
              'usp_change_space_status must be called without an existing transaction.',
              1;
    END;


    /*
        Manual administrative status changes.

        "in use" should be controlled by usage sessions.
        "under maintenance" should be controlled by maintenance.
    */
    IF @new_status NOT IN (
        N'available',
        N'temporarily closed',
        N'retired'
    )
    BEGIN
        THROW 52321,
              'Invalid manually assignable space status.',
              1;
    END;


    IF @lock_timeout_ms < 0
    BEGIN
        THROW 52322,
              'Application-lock timeout cannot be negative.',
              1;
    END;


    BEGIN TRY

        BEGIN TRANSACTION;


        DECLARE @canonical_space_code VARCHAR(20);
        DECLARE @current_status NVARCHAR(30);

        DECLARE @lock_resource NVARCHAR(255);
        DECLARE @lock_result INT;


        /*
            Obtain canonical space code.
        */
        SELECT
            @canonical_space_code =
                s.space_code

        FROM dbo.spaces AS s

        WHERE s.space_code =
              @space_code;


        IF @canonical_space_code IS NULL
        BEGIN
            THROW 52323,
                  'Space was not found.',
                  1;
        END;


        SET @lock_resource =
            CONCAT(
                N'CampusSpaceBooking:',
                @canonical_space_code
            );


        /*
            Same lock used by approval and maintenance operations.
        */
        EXEC @lock_result = sys.sp_getapplock
            @Resource = @lock_resource,
            @LockMode = N'Exclusive',
            @LockOwner = N'Transaction',
            @LockTimeout = @lock_timeout_ms;


        IF @lock_result < 0
        BEGIN
            THROW 52324,
                  'Could not obtain the application lock for the space.',
                  1;
        END;


        /*
            Staff authorization.
        */
        IF NOT EXISTS (
            SELECT 1
            FROM dbo.users AS u

            WHERE u.user_id =
                  @changed_by

              AND u.account_status =
                  N'active'

              AND u.role IN (
                  N'facility staff',
                  N'facility manager'
              )
        )
        BEGIN
            THROW 52325,
                  'Only active facility staff or managers may change space status.',
                  1;
        END;


        /*
            Read the current row under update lock.
        */
        SELECT
            @current_status =
                s.current_status

        FROM dbo.spaces AS s
            WITH (UPDLOCK, HOLDLOCK)

        WHERE s.space_code =
              @canonical_space_code;


        /*
            Do not manually reopen a room while out-of-service
            maintenance is still active.
        */
        IF @new_status =
           N'available'

           AND EXISTS (
               SELECT 1

               FROM dbo.maintenance_records AS mr

               WHERE mr.space_code =
                     @canonical_space_code

                 AND mr.impact_level =
                     N'out-of-service'

                 AND mr.maintenance_status IN (
                     N'reported',
                     N'assigned',
                     N'in progress'
                 )
           )
        BEGIN
            THROW 52326,
                  'Space cannot be marked available while out-of-service maintenance is active.',
                  1;
        END;


        IF @current_status =
           @new_status
        BEGIN
            THROW 52327,
                  'The space already has the requested status.',
                  1;
        END;


        UPDATE dbo.spaces

        SET current_status =
            @new_status

        WHERE space_code =
              @canonical_space_code;


        COMMIT TRANSACTION;


        SELECT
            s.space_code,
            s.space_name,
            s.current_status

        FROM dbo.spaces AS s

        WHERE s.space_code =
              @canonical_space_code;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;


        THROW;

    END CATCH;
END;
GO


/* =====================================================================
   10. HELPER: LOAD BOOKING FOR STAFF DECISION

   Returns the latest ROWVERSION.

   Staff UI should retrieve the booking using this procedure and later
   send the returned version_token to approve/reject.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_get_booking_for_decision
    @booking_id INT
AS
BEGIN
    SET NOCOUNT ON;


    SELECT
        br.booking_id,
        br.requester_id,

        u.full_name
            AS requester_name,

        br.space_code,

        s.space_name,

        br.requested_start_time,
        br.requested_end_time,
        br.purpose_of_use,
        br.expected_participants,
        br.booking_status,

        CONVERT(
            BINARY(8),
            br.version_token
        ) AS version_token,

        stp.instant_approval_enabled

    FROM dbo.booking_requests AS br

    INNER JOIN dbo.users AS u
        ON u.user_id =
           br.requester_id

    INNER JOIN dbo.spaces AS s
        ON s.space_code =
           br.space_code

    INNER JOIN dbo.space_type_policies AS stp
        ON stp.space_type =
           s.space_type

    WHERE br.booking_id =
          @booking_id;


    /*
        This second result set is INFORMATIONAL.

        It shows currently active overlapping advisories to staff.

        Staff approval does not require acknowledgements for advisories
        created after submission.
    */
    SELECT
        mr.maintenance_id,
        mr.problem_type,
        mr.problem_description,
        mr.start_time,
        mr.completion_time,
        mr.maintenance_status

    FROM dbo.booking_requests AS br

    INNER JOIN dbo.maintenance_records AS mr
        ON mr.space_code =
           br.space_code

    WHERE br.booking_id =
          @booking_id

      AND mr.impact_level =
          N'advisory'

      AND mr.maintenance_status IN (
          N'reported',
          N'assigned',
          N'in progress'
      )

      AND br.requested_start_time <
          COALESCE(
              mr.completion_time,
              CONVERT(
                  DATETIME2(0),
                  '9999-12-31 23:59:59'
              )
          )

      AND br.requested_end_time >
          mr.start_time

    ORDER BY
        mr.start_time,
        mr.maintenance_id;
END;
GO


/* =====================================================================
   11. VERIFICATION PROCEDURE

   Returns all forbidden pairs of overlapping approved bookings.

   Expected result:
       0 rows
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_verify_no_overlapping_approved_bookings
AS
BEGIN
    SET NOCOUNT ON;


    SELECT
        b1.booking_id
            AS booking_id_1,

        b2.booking_id
            AS booking_id_2,

        b1.space_code,

        b1.requested_start_time
            AS booking_1_start,

        b1.requested_end_time
            AS booking_1_end,

        b2.requested_start_time
            AS booking_2_start,

        b2.requested_end_time
            AS booking_2_end

    FROM dbo.booking_requests AS b1

    INNER JOIN dbo.booking_requests AS b2

        ON b2.space_code =
           b1.space_code

       AND b2.booking_id >
           b1.booking_id

       AND b1.requested_start_time <
           b2.requested_end_time

       AND b1.requested_end_time >
           b2.requested_start_time

    WHERE b1.booking_status IN (
              N'approved',
              N'checked in'
          )

      AND b2.booking_status IN (
              N'approved',
              N'checked in'
          )

    ORDER BY
        b1.space_code,
        b1.requested_start_time,
        b1.booking_id,
        b2.booking_id;
END;
GO


/* =====================================================================
   12. APPLICATION SECURITY HARDENING

   FIX 4:
       sp_getapplock works only if all business operations follow the same
       locking protocol.

       Therefore normal application users must not directly modify the
       protected tables.

   Application users should be members of:
       campus_app_role

   They execute stored procedures instead of direct DML.

   IMPORTANT:
       This script creates/configures the role but does NOT automatically
       add a database user to the role.

       Example:
           ALTER ROLE campus_app_role ADD MEMBER MyApplicationUser;
   ===================================================================== */

IF DATABASE_PRINCIPAL_ID(
       N'campus_app_role'
   ) IS NULL
BEGIN
    CREATE ROLE campus_app_role
        AUTHORIZATION dbo;
END;
GO


/* -------------------------------------------------------------
   Prevent direct booking manipulation.
   ------------------------------------------------------------- */

DENY INSERT, UPDATE, DELETE
ON dbo.booking_requests
TO campus_app_role;
GO


/* -------------------------------------------------------------
   Prevent direct approval manipulation.
   ------------------------------------------------------------- */

DENY INSERT, UPDATE, DELETE
ON dbo.approvals
TO campus_app_role;
GO


/* -------------------------------------------------------------
   Prevent direct acknowledgement manipulation.

   Acknowledgements must be created through booking submission.
   ------------------------------------------------------------- */

DENY INSERT, UPDATE, DELETE
ON dbo.booking_advisory_acknowledgements
TO campus_app_role;
GO


/* -------------------------------------------------------------
   Prevent direct maintenance changes that could bypass the
   per-space application lock.
   ------------------------------------------------------------- */

DENY INSERT, UPDATE, DELETE
ON dbo.maintenance_records
TO campus_app_role;
GO


/* -------------------------------------------------------------
   Prevent direct space-status modifications.
   ------------------------------------------------------------- */

DENY UPDATE
ON dbo.spaces
TO campus_app_role;
GO


/* -------------------------------------------------------------
   Grant access only to protected business operations.
   ------------------------------------------------------------- */

GRANT EXECUTE
ON dbo.usp_submit_booking
TO campus_app_role;
GO


GRANT EXECUTE
ON dbo.usp_approve_booking
TO campus_app_role;
GO


GRANT EXECUTE
ON dbo.usp_reject_booking
TO campus_app_role;
GO


GRANT EXECUTE
ON dbo.usp_change_maintenance_impact
TO campus_app_role;
GO


GRANT EXECUTE
ON dbo.usp_create_maintenance_record
TO campus_app_role;
GO


GRANT EXECUTE
ON dbo.usp_change_space_status
TO campus_app_role;
GO


GRANT EXECUTE
ON dbo.usp_get_booking_for_decision
TO campus_app_role;
GO


GRANT EXECUTE
ON dbo.usp_verify_no_overlapping_approved_bookings
TO campus_app_role;
GO


/*
    Intentionally do NOT grant EXECUTE directly on:

        dbo.usp_approve_booking_core

    Normal application callers should only use the public wrapper
    procedures.
*/


/* =====================================================================
   13. EXAMPLE USAGE
   ===================================================================== */


/*
-----------------------------------------------------------------------
Example A
Submit booking when no advisory acknowledgement is required.
-----------------------------------------------------------------------

DECLARE @acknowledgements dbo.maintenance_id_list;

DECLARE @new_booking_id INT;
DECLARE @new_booking_status NVARCHAR(30);
DECLARE @new_version_token BINARY(8);


EXEC dbo.usp_submit_booking

    @requester_id =
        'S001',

    @space_code =
        'A101',

    @requested_start_time =
        '2026-09-01 09:00:00',

    @requested_end_time =
        '2026-09-01 11:00:00',

    @purpose_of_use =
        N'Student project meeting',

    @expected_participants =
        10,

    @usage_policy_satisfied =
        1,

    @acknowledged_advisories =
        @acknowledgements,

    @booking_id =
        @new_booking_id OUTPUT,

    @booking_status =
        @new_booking_status OUTPUT,

    @version_token =
        @new_version_token OUTPUT;


SELECT
    @new_booking_id
        AS booking_id,

    @new_booking_status
        AS booking_status,

    @new_version_token
        AS version_token;

*/


/*
-----------------------------------------------------------------------
Example B
Submit booking and acknowledge advisory maintenance IDs.
-----------------------------------------------------------------------

DECLARE @acknowledgements dbo.maintenance_id_list;


INSERT INTO @acknowledgements (
    maintenance_id
)
VALUES
    (101),
    (102);


DECLARE @new_booking_id INT;
DECLARE @new_booking_status NVARCHAR(30);
DECLARE @new_version_token BINARY(8);


EXEC dbo.usp_submit_booking

    @requester_id =
        'S001',

    @space_code =
        'A101',

    @requested_start_time =
        '2026-09-01 09:00:00',

    @requested_end_time =
        '2026-09-01 11:00:00',

    @purpose_of_use =
        N'Student project meeting',

    @expected_participants =
        10,

    @usage_policy_satisfied =
        1,

    @acknowledged_advisories =
        @acknowledgements,

    @booking_id =
        @new_booking_id OUTPUT,

    @booking_status =
        @new_booking_status OUTPUT,

    @version_token =
        @new_version_token OUTPUT;

*/


/*
-----------------------------------------------------------------------
Example C
Staff loads booking and obtains latest ROWVERSION.
-----------------------------------------------------------------------

EXEC dbo.usp_get_booking_for_decision
    @booking_id = 1001;

*/


/*
-----------------------------------------------------------------------
Example D
Staff approves a pending booking.

ROWVERSION is mandatory.
-----------------------------------------------------------------------

DECLARE @current_version BINARY(8);


SELECT
    @current_version =
        CONVERT(
            BINARY(8),
            version_token
        )

FROM dbo.booking_requests

WHERE booking_id =
      1001;


EXEC dbo.usp_approve_booking

    @booking_id =
        1001,

    @staff_id =
        'FS001',

    @expected_version_token =
        @current_version,

    @decision_note =
        N'Booking satisfies the usage policy.';

*/


/*
-----------------------------------------------------------------------
Example E
This now fails because NULL ROWVERSION is not accepted.
-----------------------------------------------------------------------

EXEC dbo.usp_approve_booking

    @booking_id =
        1001,

    @staff_id =
        'FS001',

    @expected_version_token =
        NULL,

    @decision_note =
        N'Test NULL version token';

*/


/*
-----------------------------------------------------------------------
Example F
Staff rejects a pending booking.
-----------------------------------------------------------------------

DECLARE @current_version BINARY(8);


SELECT
    @current_version =
        CONVERT(
            BINARY(8),
            version_token
        )

FROM dbo.booking_requests

WHERE booking_id =
      1002;


EXEC dbo.usp_reject_booking

    @booking_id =
        1002,

    @staff_id =
        'FS001',

    @expected_version_token =
        @current_version,

    @rejection_reason =
        N'The request does not satisfy the usage policy.',

    @decision_note =
        N'Reviewed by facility staff.';

*/


/*
-----------------------------------------------------------------------
Example G
Escalate advisory maintenance to out-of-service.
-----------------------------------------------------------------------

EXEC dbo.usp_change_maintenance_impact

    @maintenance_id =
        201,

    @new_impact_level =
        N'out-of-service',

    @changed_by =
        'FS001',

    @change_reason =
        N'The issue became more severe after inspection.',

    @expected_current_impact_level =
        N'advisory';

*/


/*
-----------------------------------------------------------------------
Example H
Temporarily close a space.

Uses the SAME application lock as booking approval.
-----------------------------------------------------------------------

EXEC dbo.usp_change_space_status

    @space_code =
        'A101',

    @new_status =
        N'temporarily closed',

    @changed_by =
        'FS001';

*/


/*
-----------------------------------------------------------------------
Example I
Reopen a space.

Fails if active out-of-service maintenance still exists.
-----------------------------------------------------------------------

EXEC dbo.usp_change_space_status

    @space_code =
        'A101',

    @new_status =
        N'available',

    @changed_by =
        'FS001';

*/


/*
-----------------------------------------------------------------------
Example J
Verify no forbidden approved-booking overlap exists.
Expected: 0 rows.
-----------------------------------------------------------------------

EXEC dbo.usp_verify_no_overlapping_approved_bookings;

*/


/*
-----------------------------------------------------------------------
Example K
Add the real application database user to the protected application role.

Replace CampusApplicationUser with the actual database username.
-----------------------------------------------------------------------

ALTER ROLE campus_app_role
ADD MEMBER CampusApplicationUser;

*/


PRINT N'12-concurrency-implementation-G10.sql completed successfully.';
GO
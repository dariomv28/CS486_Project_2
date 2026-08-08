/* =====================================================================
   File: 10-schema-migration-G10.sql
   Course: CS486 - Introduction to Database System
   Group: G10
   DBMS: Microsoft SQL Server

   Purpose:
       Migrate the Phase 1 CampusSpaceManagement database to the
       finalized Phase 2 relational schema.

   Migration strategy:
       1. Preserve all Phase 1 users, spaces, bookings, approvals,
          usage sessions and maintenance records.
       2. Create SPACE_TYPE_POLICY and disable instant approval by
          default for all existing space types.
       3. Normalize the Phase 1 facilities table into:
              - facility_types
              - facility_instances
          Each Phase 1 facility quantity is expanded into individual
          facility instances.
       4. Add ROWVERSION to booking_requests for optimistic concurrency.
       5. Add decision_method to approvals. Existing approvals are
          migrated as staff decisions.
       6. Existing Phase 1 maintenance records are migrated with the
          impact level out-of-service because Phase 1 blocked the
          whole space during maintenance.
       7. Existing assigned_staff_id values are migrated to
          maintenance_assignments.
       8. Existing maintenance records are initialized in
          maintenance_impact_history.
       9. facility_id remains NULL for existing maintenance records
          because Phase 1 did not reliably identify a specific
          facility instance.
      10. Replace Phase 1 triggers affected by the new schema.

   Important:
       Back up the CampusSpaceManagement database before execution.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO


/* =====================================================================
   1. Pre-migration validation
   ===================================================================== */

IF OBJECT_ID(N'dbo.users', N'U') IS NULL
    THROW 52000, 'Phase 1 table dbo.users was not found.', 1;

IF OBJECT_ID(N'dbo.spaces', N'U') IS NULL
    THROW 52001, 'Phase 1 table dbo.spaces was not found.', 1;

IF OBJECT_ID(N'dbo.facilities', N'U') IS NULL
    THROW 52002, 'Phase 1 table dbo.facilities was not found.', 1;

IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NULL
    THROW 52003, 'Phase 1 table dbo.booking_requests was not found.', 1;

IF OBJECT_ID(N'dbo.approvals', N'U') IS NULL
    THROW 52004, 'Phase 1 table dbo.approvals was not found.', 1;

IF OBJECT_ID(N'dbo.usage_sessions', N'U') IS NULL
    THROW 52005, 'Phase 1 table dbo.usage_sessions was not found.', 1;

IF OBJECT_ID(N'dbo.maintenance_records', N'U') IS NULL
    THROW 52006, 'Phase 1 table dbo.maintenance_records was not found.', 1;

IF OBJECT_ID(N'dbo.space_type_policies', N'U') IS NOT NULL
    THROW 52007, 'The Phase 2 migration appears to have already been applied.', 1;
GO


/* =====================================================================
   2. Structural migration
   ===================================================================== */

BEGIN TRY
    BEGIN TRANSACTION;


    /* ---------------------------------------------------------------
       2.1. Remove Phase 1 triggers that reference changed structures
       --------------------------------------------------------------- */

    IF OBJECT_ID(
           N'dbo.trg_booking_requests_validate',
           N'TR'
       ) IS NOT NULL
    BEGIN
        DROP TRIGGER dbo.trg_booking_requests_validate;
    END;


    IF OBJECT_ID(
           N'dbo.trg_approvals_validate_and_sync',
           N'TR'
       ) IS NOT NULL
    BEGIN
        DROP TRIGGER dbo.trg_approvals_validate_and_sync;
    END;


    IF OBJECT_ID(
           N'dbo.trg_maintenance_records_validate_and_sync',
           N'TR'
       ) IS NOT NULL
    BEGIN
        DROP TRIGGER dbo.trg_maintenance_records_validate_and_sync;
    END;


    /* ---------------------------------------------------------------
       2.2. SPACE_TYPE_POLICY
       --------------------------------------------------------------- */

    CREATE TABLE dbo.space_type_policies (
        space_type                NVARCHAR(40)  NOT NULL,

        instant_approval_enabled  BIT           NOT NULL
            CONSTRAINT df_space_type_policies_instant_approval
            DEFAULT (0),

        policy_description        NVARCHAR(MAX) NULL,

        CONSTRAINT pk_space_type_policies
            PRIMARY KEY (space_type)
    );


    INSERT INTO dbo.space_type_policies (
        space_type,
        instant_approval_enabled,
        policy_description
    )
    SELECT DISTINCT
        s.space_type,
        CASE
            WHEN s.space_type = N'meeting room'
                THEN 1
            ELSE 0
        END,
        CASE
            WHEN s.space_type = N'meeting room'
                THEN N'Meeting rooms support instant approval when the usage policy is satisfied.'
            ELSE N'Instant approval is disabled for this space type.'
        END
    FROM dbo.spaces AS s;


    /*
       SPACE_TYPE_POLICY now defines valid space types.
       Remove the old Phase 1 hard-coded CHECK constraint.
    */
    IF EXISTS (
        SELECT 1
        FROM sys.check_constraints
        WHERE parent_object_id =
              OBJECT_ID(N'dbo.spaces')
          AND name =
              N'chk_spaces_type'
    )
    BEGIN
        ALTER TABLE dbo.spaces
            DROP CONSTRAINT chk_spaces_type;
    END;


    ALTER TABLE dbo.spaces
        ADD CONSTRAINT fk_spaces_space_type_policy
        FOREIGN KEY (space_type)
        REFERENCES dbo.space_type_policies(space_type);


    /* ---------------------------------------------------------------
       2.3. Normalize FACILITY into
            FACILITY_TYPE and FACILITY_INSTANCE
       --------------------------------------------------------------- */

    CREATE TABLE dbo.facility_types (
        facility_type_id    INT IDENTITY(1,1) NOT NULL,
        facility_type_name  NVARCHAR(100)      NOT NULL,
        description         NVARCHAR(MAX)      NULL,

        CONSTRAINT pk_facility_types
            PRIMARY KEY (facility_type_id),

        CONSTRAINT uq_facility_types_name
            UNIQUE (facility_type_name)
    );


    CREATE TABLE dbo.facility_instances (
        facility_id       INT IDENTITY(1,1) NOT NULL,
        facility_type_id  INT               NOT NULL,
        space_code        VARCHAR(20)       NOT NULL,
        asset_tag         VARCHAR(100)      NOT NULL,

        instance_status   NVARCHAR(30)      NOT NULL
            CONSTRAINT df_facility_instances_status
            DEFAULT (N'available'),

        condition_note    NVARCHAR(MAX)     NULL,
        installed_at      DATETIME2(0)      NULL,

        CONSTRAINT pk_facility_instances
            PRIMARY KEY (facility_id),

        CONSTRAINT uq_facility_instances_asset_tag
            UNIQUE (asset_tag),

        /*
           This alternate key is required by the composite FK from
           maintenance_records(facility_id, space_code).
        */
        CONSTRAINT uq_facility_instances_id_space
            UNIQUE (
                facility_id,
                space_code
            ),

        CONSTRAINT fk_facility_instances_type
            FOREIGN KEY (facility_type_id)
            REFERENCES dbo.facility_types(facility_type_id),

        CONSTRAINT fk_facility_instances_space
            FOREIGN KEY (space_code)
            REFERENCES dbo.spaces(space_code)
            ON DELETE CASCADE
    );


    /*
       Preserve one facility type for every distinct Phase 1
       facility_name.

       If multiple Phase 1 rows use different descriptions,
       retain the first non-null description.
    */
    INSERT INTO dbo.facility_types (
        facility_type_name,
        description
    )
    SELECT
        facility_names.facility_name,

        (
            SELECT TOP (1)
                f2.description

            FROM dbo.facilities AS f2

            WHERE f2.facility_name =
                  facility_names.facility_name

              AND f2.description IS NOT NULL

            ORDER BY
                f2.facility_id
        )

    FROM (
        SELECT
            f.facility_name

        FROM dbo.facilities AS f

        GROUP BY
            f.facility_name
    ) AS facility_names;


    /*
       Phase 1 stored facility quantity.

       Phase 2 stores individual physical facility instances,
       therefore one FACILITY_INSTANCE row is created for every unit.
    */
    DECLARE @maximum_facility_quantity INT;


    SELECT
        @maximum_facility_quantity =
            ISNULL(
                MAX(f.quantity),
                0
            )

    FROM dbo.facilities AS f;


    ;WITH facility_numbers AS (
        SELECT
            1 AS instance_number

        UNION ALL

        SELECT
            instance_number + 1

        FROM facility_numbers

        WHERE instance_number <
              @maximum_facility_quantity
    )

    INSERT INTO dbo.facility_instances (
        facility_type_id,
        space_code,
        asset_tag,
        instance_status,
        condition_note,
        installed_at
    )

    SELECT
        ft.facility_type_id,

        f.space_code,

        CONCAT(
            'MIG-F',
            CONVERT(
                VARCHAR(20),
                f.facility_id
            ),
            '-',
            CONVERT(
                VARCHAR(20),
                n.instance_number
            )
        ),

        N'available',

        f.condition_note,

        NULL

    FROM dbo.facilities AS f

    INNER JOIN dbo.facility_types AS ft
        ON ft.facility_type_name =
           f.facility_name

    INNER JOIN facility_numbers AS n
        ON n.instance_number <=
           f.quantity

    OPTION (MAXRECURSION 0);


    /*
       Verify that all Phase 1 facility quantities were preserved.
    */
    DECLARE @expected_facility_instances BIGINT;
    DECLARE @migrated_facility_instances BIGINT;


    SELECT
        @expected_facility_instances =
            ISNULL(
                SUM(
                    CONVERT(
                        BIGINT,
                        f.quantity
                    )
                ),
                0
            )

    FROM dbo.facilities AS f;


    SELECT
        @migrated_facility_instances =
            COUNT_BIG(*)

    FROM dbo.facility_instances;


    IF @expected_facility_instances <>
       @migrated_facility_instances
    BEGIN
        THROW 52008,
              'Facility migration failed: generated instance count does not match Phase 1 quantity.',
              1;
    END;


    /*
       Phase 1 facility data has been preserved in normalized form.
    */
    DROP TABLE dbo.facilities;


    /* ---------------------------------------------------------------
       2.4. Add optimistic concurrency token to BOOKING_REQUEST
       --------------------------------------------------------------- */

    ALTER TABLE dbo.booking_requests
        ADD version_token ROWVERSION NOT NULL;


    /* ---------------------------------------------------------------
       2.5. Extend APPROVAL for automatic and staff decisions

       IMPORTANT:
       decision_method is created inside this transaction/batch.

       SQL Server compiles the batch before executing it, so statements
       referring to decision_method must use dynamic SQL until the next
       GO boundary.
       --------------------------------------------------------------- */

    ALTER TABLE dbo.approvals
        ADD decision_method NVARCHAR(20) NULL;


    /*
       Every existing Phase 1 approval was made by a staff member.

       Dynamic SQL delays compilation until decision_method actually
       exists.
    */
    EXEC(N'
        UPDATE dbo.approvals
        SET decision_method = N''staff'';

        ALTER TABLE dbo.approvals
            ALTER COLUMN decision_method NVARCHAR(20) NOT NULL;

        ALTER TABLE dbo.approvals
            ADD CONSTRAINT df_approvals_decision_method
            DEFAULT (N''staff'') FOR decision_method;
    ');


    /*
       Automatic approvals have no staff member.
    */
    ALTER TABLE dbo.approvals
        ALTER COLUMN staff_id VARCHAR(20) NULL;


    /*
       Remove the original Phase 1 rejection constraint because
       Phase 2 replaces it with a stronger version.
    */
    IF EXISTS (
        SELECT 1

        FROM sys.check_constraints

        WHERE parent_object_id =
              OBJECT_ID(N'dbo.approvals')

          AND name =
              N'chk_approvals_rejection_reason'
    )
    BEGIN
        ALTER TABLE dbo.approvals
            DROP CONSTRAINT chk_approvals_rejection_reason;
    END;


    /*
       These constraints reference decision_method, which was added
       earlier in this same batch.

       Therefore they must also be compiled dynamically.
    */
    EXEC(N'
        ALTER TABLE dbo.approvals
            ADD CONSTRAINT chk_approvals_method
            CHECK (
                decision_method IN (
                    N''automatic'',
                    N''staff''
                )
            );

        ALTER TABLE dbo.approvals
            ADD CONSTRAINT chk_approvals_method_actor
            CHECK (
                (
                    decision_method = N''automatic''
                    AND decision = N''approved''
                    AND staff_id IS NULL
                )
                OR
                (
                    decision_method = N''staff''
                    AND staff_id IS NOT NULL
                )
            );

        ALTER TABLE dbo.approvals
            ADD CONSTRAINT chk_approvals_rejection_reason
            CHECK (
                (
                    decision = N''rejected''
                    AND rejection_reason IS NOT NULL
                )
                OR
                (
                    decision = N''approved''
                    AND rejection_reason IS NULL
                )
            );
    ');


    /* ---------------------------------------------------------------
       2.6. Extend MAINTENANCE_RECORD

       facility_id and impact_level are new columns in this batch.
       Statements that reference them must use dynamic SQL.
       --------------------------------------------------------------- */

    ALTER TABLE dbo.maintenance_records
        ADD
            facility_id  INT          NULL,
            impact_level NVARCHAR(20) NULL;


    /*
       In Phase 1 every active maintenance record prevented booking.
       Therefore every legacy maintenance record is migrated as
       out-of-service.

       Dynamic SQL is required because impact_level was just created.
    */
    EXEC(N'
        UPDATE dbo.maintenance_records
        SET impact_level = N''out-of-service'';

        ALTER TABLE dbo.maintenance_records
            ALTER COLUMN impact_level NVARCHAR(20) NOT NULL;

        ALTER TABLE dbo.maintenance_records
            ADD CONSTRAINT df_maintenance_records_impact_level
            DEFAULT (N''out-of-service'') FOR impact_level;

        ALTER TABLE dbo.maintenance_records
            ADD CONSTRAINT chk_maintenance_records_impact_level
            CHECK (
                impact_level IN (
                    N''advisory'',
                    N''out-of-service''
                )
            );

        /*
           Composite FK ensures that when facility_id is supplied,
           the selected facility instance belongs to the same space.
        */
        ALTER TABLE dbo.maintenance_records
            ADD CONSTRAINT fk_maintenance_records_facility_instance
            FOREIGN KEY (
                facility_id,
                space_code
            )
            REFERENCES dbo.facility_instances (
                facility_id,
                space_code
            );
    ');


    /* ---------------------------------------------------------------
       2.7. MAINTENANCE_ASSIGNMENT
       --------------------------------------------------------------- */

    CREATE TABLE dbo.maintenance_assignments (
        assignment_id    BIGINT IDENTITY(1,1) NOT NULL,
        maintenance_id   INT                  NOT NULL,
        staff_id          VARCHAR(20)          NOT NULL,

        assigned_at       DATETIME2(0)         NOT NULL
            CONSTRAINT df_maintenance_assignments_assigned_at
            DEFAULT (SYSDATETIME()),

        unassigned_at     DATETIME2(0)         NULL,

        assignment_role   NVARCHAR(30)         NOT NULL
            CONSTRAINT df_maintenance_assignments_role
            DEFAULT (N'primary'),

        CONSTRAINT pk_maintenance_assignments
            PRIMARY KEY (assignment_id),

        CONSTRAINT fk_maintenance_assignments_maintenance
            FOREIGN KEY (maintenance_id)
            REFERENCES dbo.maintenance_records(maintenance_id),

        CONSTRAINT fk_maintenance_assignments_staff
            FOREIGN KEY (staff_id)
            REFERENCES dbo.users(user_id),

        CONSTRAINT chk_maintenance_assignments_time
            CHECK (
                unassigned_at IS NULL
                OR unassigned_at >= assigned_at
            ),

        CONSTRAINT chk_maintenance_assignments_role
            CHECK (
                assignment_role IN (
                    N'primary',
                    N'support'
                )
            )
    );


    /*
       Preserve Phase 1 assigned_staff_id values as assignment history.
    */
    INSERT INTO dbo.maintenance_assignments (
        maintenance_id,
        staff_id,
        assigned_at,
        unassigned_at,
        assignment_role
    )

    SELECT
        mr.maintenance_id,
        mr.assigned_staff_id,
        mr.start_time,

        CASE
            WHEN mr.maintenance_status =
                 N'completed'
            THEN mr.completion_time

            WHEN mr.maintenance_status =
                 N'cancelled'
            THEN COALESCE(
                mr.completion_time,
                mr.start_time
            )

            ELSE NULL
        END,

        N'primary'

    FROM dbo.maintenance_records AS mr

    WHERE mr.assigned_staff_id IS NOT NULL;


    /*
       Remove Phase 1 index and FK before removing assigned_staff_id.
    */
    IF EXISTS (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
              OBJECT_ID(N'dbo.maintenance_records')

          AND name =
              N'idx_maintenance_records_assigned_staff'
    )
    BEGIN
        DROP INDEX idx_maintenance_records_assigned_staff
            ON dbo.maintenance_records;
    END;


    IF EXISTS (
        SELECT 1

        FROM sys.foreign_keys

        WHERE parent_object_id =
              OBJECT_ID(N'dbo.maintenance_records')

          AND name =
              N'fk_maintenance_records_assigned_staff'
    )
    BEGIN
        ALTER TABLE dbo.maintenance_records
            DROP CONSTRAINT fk_maintenance_records_assigned_staff;
    END;


    ALTER TABLE dbo.maintenance_records
        DROP COLUMN assigned_staff_id;


    /* ---------------------------------------------------------------
       2.8. MAINTENANCE_IMPACT_HISTORY
       --------------------------------------------------------------- */

    CREATE TABLE dbo.maintenance_impact_history (
        impact_change_id       BIGINT IDENTITY(1,1) NOT NULL,

        maintenance_id         INT                  NOT NULL,

        previous_impact_level  NVARCHAR(20)         NULL,

        new_impact_level       NVARCHAR(20)         NOT NULL,

        changed_by             VARCHAR(20)          NOT NULL,

        changed_at             DATETIME2(0)         NOT NULL
            CONSTRAINT df_maintenance_impact_history_changed_at
            DEFAULT (SYSDATETIME()),

        change_reason          NVARCHAR(MAX)        NULL,

        CONSTRAINT pk_maintenance_impact_history
            PRIMARY KEY (impact_change_id),

        CONSTRAINT fk_maintenance_impact_history_maintenance
            FOREIGN KEY (maintenance_id)
            REFERENCES dbo.maintenance_records(maintenance_id),

        CONSTRAINT fk_maintenance_impact_history_changed_by
            FOREIGN KEY (changed_by)
            REFERENCES dbo.users(user_id),

        CONSTRAINT chk_maintenance_impact_history_previous
            CHECK (
                previous_impact_level IS NULL
                OR previous_impact_level IN (
                    N'advisory',
                    N'out-of-service'
                )
            ),

        CONSTRAINT chk_maintenance_impact_history_new
            CHECK (
                new_impact_level IN (
                    N'advisory',
                    N'out-of-service'
                )
            ),

        CONSTRAINT chk_maintenance_impact_history_transition
            CHECK (
                previous_impact_level IS NULL
                OR previous_impact_level <>
                   new_impact_level
            )
    );


    /*
       Initialize impact history for every migrated Phase 1
       maintenance record.
    */
    INSERT INTO dbo.maintenance_impact_history (
        maintenance_id,
        previous_impact_level,
        new_impact_level,
        changed_by,
        changed_at,
        change_reason
    )

    SELECT
        mr.maintenance_id,

        NULL,

        N'out-of-service',

        mr.reporter_id,

        mr.start_time,

        N'Migrated from Phase 1. Legacy maintenance blocked the entire space.'

    FROM dbo.maintenance_records AS mr;


    /* ---------------------------------------------------------------
       2.9. BOOKING_ADVISORY_ACKNOWLEDGEMENT
       --------------------------------------------------------------- */

    CREATE TABLE dbo.booking_advisory_acknowledgements (
        booking_id       INT          NOT NULL,

        maintenance_id   INT          NOT NULL,

        acknowledged_at  DATETIME2(0) NOT NULL
            CONSTRAINT df_booking_advisory_acknowledgements_time
            DEFAULT (SYSDATETIME()),

        CONSTRAINT pk_booking_advisory_acknowledgements
            PRIMARY KEY (
                booking_id,
                maintenance_id
            ),

        CONSTRAINT fk_booking_advisory_acknowledgements_booking
            FOREIGN KEY (booking_id)
            REFERENCES dbo.booking_requests(booking_id)
            ON DELETE CASCADE,

        CONSTRAINT fk_booking_advisory_acknowledgements_maintenance
            FOREIGN KEY (maintenance_id)
            REFERENCES dbo.maintenance_records(maintenance_id)
    );


    /* ---------------------------------------------------------------
       2.10. Structural indexes

       Performance-tuning indexes belong to deliverable 15.
       --------------------------------------------------------------- */

    CREATE INDEX idx_facility_instances_space
        ON dbo.facility_instances (
            space_code,
            facility_type_id
        );


    CREATE INDEX idx_maintenance_assignments_maintenance
        ON dbo.maintenance_assignments (
            maintenance_id,
            assigned_at
        );


    CREATE INDEX idx_maintenance_assignments_staff
        ON dbo.maintenance_assignments (
            staff_id,
            unassigned_at
        );


    /*
       Only one active primary staff assignment is allowed for each
       maintenance record.
    */
    CREATE UNIQUE INDEX ux_maintenance_assignments_active_primary
        ON dbo.maintenance_assignments (
            maintenance_id
        )

        WHERE unassigned_at IS NULL
          AND assignment_role =
              N'primary';


    CREATE INDEX idx_maintenance_impact_history_maintenance
        ON dbo.maintenance_impact_history (
            maintenance_id,
            changed_at
        );


    CREATE INDEX idx_booking_advisory_acknowledgements_maintenance
        ON dbo.booking_advisory_acknowledgements (
            maintenance_id,
            booking_id
        );


    /* ---------------------------------------------------------------
       2.11. Recalculate current space status

       Only an active out-of-service maintenance record changes the
       space status to under maintenance.

       Advisory maintenance does not make the space unavailable.

       impact_level was created earlier in this same batch, so this
       logic must use dynamic SQL.
       --------------------------------------------------------------- */

    DECLARE @migration_time DATETIME2(0) =
        SYSDATETIME();


    EXEC sys.sp_executesql
        N'
        /*
           Any space with an active out-of-service maintenance record
           becomes under maintenance unless it is explicitly closed or
           retired.
        */
        UPDATE s

        SET current_status =
            N''under maintenance''

        FROM dbo.spaces AS s

        WHERE s.current_status NOT IN (
                  N''temporarily closed'',
                  N''retired''
              )

          AND EXISTS (
              SELECT 1

              FROM dbo.maintenance_records AS mr

              WHERE mr.space_code =
                    s.space_code

                AND mr.impact_level =
                    N''out-of-service''

                AND mr.maintenance_status IN (
                    N''reported'',
                    N''assigned'',
                    N''in progress''
                )

                AND mr.start_time <=
                    @migration_time

                AND (
                    mr.completion_time IS NULL
                    OR mr.completion_time >
                       @migration_time
                )
          );


        /*
           If a Phase 1 space was marked under maintenance but it no
           longer has a currently active out-of-service record, restore
           its operational status.
        */
        UPDATE s

        SET current_status =
            CASE
                WHEN EXISTS (
                    SELECT 1

                    FROM dbo.booking_requests AS br

                    INNER JOIN dbo.usage_sessions AS us
                        ON us.booking_id =
                           br.booking_id

                    WHERE br.space_code =
                          s.space_code

                      AND us.actual_end_time IS NULL
                )
                THEN N''in use''

                ELSE N''available''
            END

        FROM dbo.spaces AS s

        WHERE s.current_status =
              N''under maintenance''

          AND NOT EXISTS (
              SELECT 1

              FROM dbo.maintenance_records AS mr

              WHERE mr.space_code =
                    s.space_code

                AND mr.impact_level =
                    N''out-of-service''

                AND mr.maintenance_status IN (
                    N''reported'',
                    N''assigned'',
                    N''in progress''
                )

                AND mr.start_time <=
                    @migration_time

                AND (
                    mr.completion_time IS NULL
                    OR mr.completion_time >
                       @migration_time
                )
          );
        ',

        N'@migration_time DATETIME2(0)',

        @migration_time =
            @migration_time;


    COMMIT TRANSACTION;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;
GO


/* =====================================================================
   3. Recreate BOOKING_REQUEST validation trigger

   This trigger preserves Phase 1 validations but changes the
   maintenance rule:

       - advisory maintenance does not block booking;
       - out-of-service maintenance blocks overlapping periods.

   The trigger detects ordinary conflicts. The concurrency-safe
   transaction solution is implemented separately in deliverable 12.
   ===================================================================== */

CREATE OR ALTER TRIGGER dbo.trg_booking_requests_validate

ON dbo.booking_requests

AFTER INSERT, UPDATE

AS
BEGIN
    SET NOCOUNT ON;


    /* ---------------------------------------------------------------
       Only active users may create or hold bookings.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        INNER JOIN dbo.users AS u
            ON u.user_id =
               i.requester_id

        WHERE u.account_status <>
              N'active'
    )
    BEGIN
        THROW 51001,
              'Only active users can submit or hold booking requests.',
              1;
    END;


    /* ---------------------------------------------------------------
       Core booking information becomes immutable after approval,
       check-in or completion.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        INNER JOIN deleted AS d
            ON d.booking_id =
               i.booking_id

        WHERE d.booking_status IN (
                  N'approved',
                  N'checked in',
                  N'completed'
              )

          AND (
                 i.requester_id <>
                 d.requester_id

              OR i.space_code <>
                 d.space_code

              OR i.requested_start_time <>
                 d.requested_start_time

              OR i.requested_end_time <>
                 d.requested_end_time

              OR i.purpose_of_use <>
                 d.purpose_of_use

              OR i.expected_participants <>
                 d.expected_participants
          )
    )
    BEGIN
        THROW 51009,
              'Booking details cannot be changed after approval, check-in, or completion.',
              1;
    END;


    /* ---------------------------------------------------------------
       Temporarily closed and retired spaces cannot be booked.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        INNER JOIN dbo.spaces AS s
            ON s.space_code =
               i.space_code

        WHERE i.booking_status IN (
                  N'pending',
                  N'approved',
                  N'checked in'
              )

          AND s.current_status IN (
                  N'temporarily closed',
                  N'retired'
              )
    )
    BEGIN
        THROW 51002,
              'A temporarily closed or retired space cannot be booked.',
              1;
    END;


    /* ---------------------------------------------------------------
       Requested capacity must fit the selected space.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        INNER JOIN dbo.spaces AS s
            ON s.space_code =
               i.space_code

        WHERE i.expected_participants >
              s.capacity
    )
    BEGIN
        THROW 51003,
              'Expected participants cannot exceed space capacity.',
              1;
    END;


    /* ---------------------------------------------------------------
       Out-of-service maintenance prevents overlapping bookings.

       Advisory maintenance intentionally does not block booking.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        INNER JOIN dbo.maintenance_records AS mr
            ON mr.space_code =
               i.space_code

        WHERE i.booking_status IN (
                  N'pending',
                  N'approved',
                  N'checked in'
              )

          AND mr.impact_level =
              N'out-of-service'

          AND mr.maintenance_status IN (
                  N'reported',
                  N'assigned',
                  N'in progress'
              )

          AND i.requested_start_time <
              COALESCE(
                  mr.completion_time,
                  CONVERT(
                      DATETIME2(0),
                      '9999-12-31 23:59:59'
                  )
              )

          AND i.requested_end_time >
              mr.start_time
    )
    BEGIN
        THROW 51010,
              'The booking overlaps an out-of-service maintenance period.',
              1;
    END;


    /* ---------------------------------------------------------------
       Ordinary overlap validation.

       Simultaneous approval concurrency is handled in
       12-concurrency-implementation-G10.sql.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        INNER JOIN dbo.booking_requests AS existing

            ON existing.space_code =
               i.space_code

           AND existing.booking_id <>
               i.booking_id

           AND existing.booking_status IN (
                   N'approved',
                   N'checked in'
               )

           AND i.requested_start_time <
               existing.requested_end_time

           AND i.requested_end_time >
               existing.requested_start_time

        WHERE i.booking_status IN (
                  N'approved',
                  N'checked in'
              )
    )
    BEGIN
        THROW 51004,
              'Approved or checked-in bookings for the same space cannot overlap.',
              1;
    END;

END;
GO


/* =====================================================================
   4. Recreate APPROVAL validation and synchronization trigger
   ===================================================================== */

CREATE OR ALTER TRIGGER dbo.trg_approvals_validate_and_sync

ON dbo.approvals

AFTER INSERT, UPDATE

AS
BEGIN
    SET NOCOUNT ON;


    /* ---------------------------------------------------------------
       Staff decisions must be made by an active facility staff member
       or facility manager.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        LEFT JOIN dbo.users AS u
            ON u.user_id =
               i.staff_id

        WHERE i.decision_method =
              N'staff'

          AND (
                 u.user_id IS NULL

              OR u.role NOT IN (
                     N'facility staff',
                     N'facility manager'
                 )

              OR u.account_status <>
                 N'active'
          )
    )
    BEGIN
        THROW 51005,
              'Only active facility staff or facility managers may make staff approval decisions.',
              1;
    END;


    /* ---------------------------------------------------------------
       Keep BOOKING_REQUEST.booking_status synchronized with the
       approval decision.
       --------------------------------------------------------------- */

    UPDATE br

    SET booking_status =
        i.decision

    FROM dbo.booking_requests AS br

    INNER JOIN inserted AS i
        ON i.booking_id =
           br.booking_id;

END;
GO


/* =====================================================================
   5. MAINTENANCE_ASSIGNMENT validation trigger
   ===================================================================== */

CREATE OR ALTER TRIGGER dbo.trg_maintenance_assignments_validate

ON dbo.maintenance_assignments

AFTER INSERT, UPDATE

AS
BEGIN
    SET NOCOUNT ON;


    /* ---------------------------------------------------------------
       Maintenance may be assigned only to active facility staff or
       facility managers.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        LEFT JOIN dbo.users AS u
            ON u.user_id =
               i.staff_id

        WHERE u.user_id IS NULL

           OR u.role NOT IN (
                  N'facility staff',
                  N'facility manager'
              )

           OR u.account_status <>
              N'active'
    )
    BEGIN
        THROW 51007,
              'Maintenance may be assigned only to active facility staff or facility managers.',
              1;
    END;


    /* ---------------------------------------------------------------
       Creating an active assignment changes a reported maintenance
       record to assigned.
       --------------------------------------------------------------- */

    UPDATE mr

    SET maintenance_status =
        N'assigned'

    FROM dbo.maintenance_records AS mr

    INNER JOIN inserted AS i
        ON i.maintenance_id =
           mr.maintenance_id

    WHERE i.unassigned_at IS NULL

      AND mr.maintenance_status =
          N'reported';

END;
GO


/* =====================================================================
   6. MAINTENANCE_RECORD impact-history and space-status trigger
   ===================================================================== */

CREATE OR ALTER TRIGGER dbo.trg_maintenance_records_validate_and_sync

ON dbo.maintenance_records

AFTER INSERT, UPDATE

AS
BEGIN
    SET NOCOUNT ON;


    DECLARE @change_time DATETIME2(0) =
        SYSDATETIME();

    DECLARE @changed_by VARCHAR(20);

    DECLARE @change_reason NVARCHAR(MAX);


    SET @changed_by =
        CONVERT(
            VARCHAR(20),
            SESSION_CONTEXT(
                N'maintenance_changed_by'
            )
        );


    SET @change_reason =
        CONVERT(
            NVARCHAR(MAX),
            SESSION_CONTEXT(
                N'maintenance_change_reason'
            )
        );


    /* ---------------------------------------------------------------
       Store the initial impact level when a new maintenance record
       is created.
       --------------------------------------------------------------- */

    INSERT INTO dbo.maintenance_impact_history (
        maintenance_id,
        previous_impact_level,
        new_impact_level,
        changed_by,
        changed_at,
        change_reason
    )

    SELECT
        i.maintenance_id,

        NULL,

        i.impact_level,

        i.reporter_id,

        i.start_time,

        N'Initial maintenance impact level.'

    FROM inserted AS i

    LEFT JOIN deleted AS d
        ON d.maintenance_id =
           i.maintenance_id

    WHERE d.maintenance_id IS NULL;


    /* ---------------------------------------------------------------
       An impact-level update must identify the authorized staff
       member who performed the change.

       The Phase 2 procedure sets the required SESSION_CONTEXT values.
       --------------------------------------------------------------- */

    IF EXISTS (
        SELECT 1

        FROM inserted AS i

        INNER JOIN deleted AS d
            ON d.maintenance_id =
               i.maintenance_id

        WHERE i.impact_level <>
              d.impact_level
    )
    BEGIN

        IF @changed_by IS NULL
        BEGIN
            THROW 51030,
                  'Changing maintenance impact requires maintenance_changed_by in SESSION_CONTEXT.',
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
            THROW 51031,
                  'Only active facility staff or facility managers may change maintenance impact.',
                  1;
        END;


        INSERT INTO dbo.maintenance_impact_history (
            maintenance_id,
            previous_impact_level,
            new_impact_level,
            changed_by,
            changed_at,
            change_reason
        )

        SELECT
            i.maintenance_id,

            d.impact_level,

            i.impact_level,

            @changed_by,

            @change_time,

            @change_reason

        FROM inserted AS i

        INNER JOIN deleted AS d
            ON d.maintenance_id =
               i.maintenance_id

        WHERE i.impact_level <>
              d.impact_level;

    END;


    /* ---------------------------------------------------------------
       Identify every space affected by the inserted or updated
       maintenance records.
       --------------------------------------------------------------- */

    DECLARE @affected_spaces TABLE (
        space_code VARCHAR(20) NOT NULL
            PRIMARY KEY
    );


    INSERT INTO @affected_spaces (
        space_code
    )

    SELECT
        i.space_code

    FROM inserted AS i

    UNION

    SELECT
        d.space_code

    FROM deleted AS d;


    /* ---------------------------------------------------------------
       Only currently active out-of-service maintenance changes the
       space status to under maintenance.
       --------------------------------------------------------------- */

    UPDATE s

    SET current_status =
        N'under maintenance'

    FROM dbo.spaces AS s

    INNER JOIN @affected_spaces AS a
        ON a.space_code =
           s.space_code

    WHERE s.current_status NOT IN (
              N'temporarily closed',
              N'retired'
          )

      AND EXISTS (
          SELECT 1

          FROM dbo.maintenance_records AS mr

          WHERE mr.space_code =
                s.space_code

            AND mr.impact_level =
                N'out-of-service'

            AND mr.maintenance_status IN (
                N'reported',
                N'assigned',
                N'in progress'
            )

            AND mr.start_time <=
                @change_time

            AND (
                mr.completion_time IS NULL
                OR mr.completion_time >
                   @change_time
            )
      );


    /* ---------------------------------------------------------------
       When no current out-of-service maintenance remains, restore the
       status to in use or available.
       --------------------------------------------------------------- */

    UPDATE s

    SET current_status =
        CASE
            WHEN EXISTS (
                SELECT 1

                FROM dbo.booking_requests AS br

                INNER JOIN dbo.usage_sessions AS us
                    ON us.booking_id =
                       br.booking_id

                WHERE br.space_code =
                      s.space_code

                  AND us.actual_end_time IS NULL
            )
            THEN N'in use'

            ELSE N'available'
        END

    FROM dbo.spaces AS s

    INNER JOIN @affected_spaces AS a
        ON a.space_code =
           s.space_code

    WHERE s.current_status =
          N'under maintenance'

      AND NOT EXISTS (
          SELECT 1

          FROM dbo.maintenance_records AS mr

          WHERE mr.space_code =
                s.space_code

            AND mr.impact_level =
                N'out-of-service'

            AND mr.maintenance_status IN (
                N'reported',
                N'assigned',
                N'in progress'
            )

            AND mr.start_time <=
                @change_time

            AND (
                mr.completion_time IS NULL
                OR mr.completion_time >
                   @change_time
            )
      );

END;
GO


/* =====================================================================
   7. Post-migration verification
   ===================================================================== */

PRINT N'Phase 2 schema migration for Group G10 completed successfully.';
GO


/* ---------------------------------------------------------------------
   Display row counts of all Phase 2 tables created during migration.
   --------------------------------------------------------------------- */

SELECT
    N'space_type_policies'
        AS table_name,

    COUNT_BIG(*)
        AS row_count

FROM dbo.space_type_policies


UNION ALL


SELECT
    N'facility_types',

    COUNT_BIG(*)

FROM dbo.facility_types


UNION ALL


SELECT
    N'facility_instances',

    COUNT_BIG(*)

FROM dbo.facility_instances


UNION ALL


SELECT
    N'maintenance_assignments',

    COUNT_BIG(*)

FROM dbo.maintenance_assignments


UNION ALL


SELECT
    N'maintenance_impact_history',

    COUNT_BIG(*)

FROM dbo.maintenance_impact_history


UNION ALL


SELECT
    N'booking_advisory_acknowledgements',

    COUNT_BIG(*)

FROM dbo.booking_advisory_acknowledgements;
GO


/* ---------------------------------------------------------------------
   Every existing approval must have a decision method.
   Expected result:
       0
   --------------------------------------------------------------------- */

SELECT
    COUNT_BIG(*)
        AS approvals_without_decision_method

FROM dbo.approvals

WHERE decision_method IS NULL;
GO


/* ---------------------------------------------------------------------
   Every migrated maintenance record must have an initial history row.

   Expected result:
       0
   --------------------------------------------------------------------- */

SELECT
    COUNT_BIG(*)
        AS maintenance_records_without_history

FROM dbo.maintenance_records AS mr

WHERE NOT EXISTS (
    SELECT 1

    FROM dbo.maintenance_impact_history AS mih

    WHERE mih.maintenance_id =
          mr.maintenance_id
);
GO


/* ---------------------------------------------------------------------
   Display migrated Phase 2 table structure.
   --------------------------------------------------------------------- */

SELECT
    t.name AS table_name,

    c.column_id,

    c.name AS column_name,

    TYPE_NAME(
        c.user_type_id
    ) AS data_type,

    c.max_length,

    c.is_nullable

FROM sys.tables AS t

INNER JOIN sys.columns AS c
    ON c.object_id =
       t.object_id

WHERE t.schema_id =
      SCHEMA_ID(N'dbo')

  AND t.name IN (
      N'space_type_policies',
      N'facility_types',
      N'facility_instances',
      N'booking_requests',
      N'approvals',
      N'maintenance_records',
      N'maintenance_assignments',
      N'maintenance_impact_history',
      N'booking_advisory_acknowledgements'
  )

ORDER BY
    t.name,
    c.column_id;
GO
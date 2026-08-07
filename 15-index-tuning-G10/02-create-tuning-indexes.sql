/* =====================================================================
   CS486 - Introduction to Database Systems
   Group G10 - Phase 2
   Folder: 15-index-tuning-G10
   File: 02-create-tuning-indexes.sql
   Target DBMS: Microsoft SQL Server

   Purpose:
     Add Phase 2 performance-tuning indexes for the four benchmarked
     workloads:
       1. Booking conflict check
       2. Room finder (Analytical Query 3)
       3. Total approved booking hours (Analytical Query 1)
       4. Approved bookings by weekday/hour (Analytical Query 2)

   Design summary:
     A. ix_tune_booking_conflict
        Equality predicates first: space_code, booking_status.
        Then requested_start_time supports the interval upper bound.
        requested_end_time is INCLUDEd for the residual overlap test.

     B. ix_tune_booking_reporting
        booking_status and requested_start_time are the main filters used
        by Query 1 and Query 2. requested_end_time and space_code make the
        index covering for the booking portion of those reports.

     C. ix_tune_maintenance_room_finder
        Supports the room-finder NOT EXISTS predicate on space, impact,
        active maintenance status, and start time. completion_time is
        INCLUDEd for the second half of the overlap predicate.

     D. ix_tune_facility_room_finder
        Covers counting available facility instances by space/type/status.

   Controlled benchmark baseline:
     - The surviving Phase 1 non-unique performance indexes are expected
       to have been removed by 00-drop-tuning-indexes.sql.
     - Primary-key, UNIQUE/constraint-backed indexes and Phase 2
       structural indexes are intentionally retained.
     - The indexes below are the Phase 2 tuning replacements used for the
       AFTER benchmark.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------
   Preconditions
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NULL
BEGIN
    THROW 55020, 'dbo.booking_requests was not found.', 1;
END;

IF OBJECT_ID(N'dbo.maintenance_records', N'U') IS NULL
BEGIN
    THROW 55021, 'dbo.maintenance_records was not found.', 1;
END;

IF OBJECT_ID(N'dbo.facility_instances', N'U') IS NULL
BEGIN
    THROW 55022, 'dbo.facility_instances was not found. Run the Phase 2 migration first.', 1;
END;

IF EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE
        (
            object_id = OBJECT_ID(N'dbo.booking_requests')
            AND name IN (
                N'idx_booking_requests_space_time',
                N'idx_booking_requests_status'
            )
        )
        OR
        (
            object_id = OBJECT_ID(N'dbo.maintenance_records')
            AND name = N'idx_maintenance_records_space_status'
        )
)
BEGIN
    THROW 55023, 'A surviving Phase 1 performance index still exists. Run 00-drop-tuning-indexes.sql before creating the Phase 2 tuning indexes.', 1;
END;
GO

/* =====================================================================
   INDEX 1 - Booking conflict check + booking-overlap part of room finder
   ===================================================================== */
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.booking_requests')
      AND name = N'ix_tune_booking_conflict'
)
BEGIN
    CREATE INDEX ix_tune_booking_conflict
        ON dbo.booking_requests (
            space_code,
            booking_status,
            requested_start_time
        )
        INCLUDE (
            requested_end_time
        );
END;
GO

/* =====================================================================
   INDEX 2 - Analytical Query 1 and Query 2
   ===================================================================== */
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.booking_requests')
      AND name = N'ix_tune_booking_reporting'
)
BEGIN
    CREATE INDEX ix_tune_booking_reporting
        ON dbo.booking_requests (
            booking_status,
            requested_start_time
        )
        INCLUDE (
            requested_end_time,
            space_code
        );
END;
GO

/* =====================================================================
   INDEX 3 - Out-of-service maintenance overlap in Room Finder
   ===================================================================== */
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.maintenance_records')
      AND name = N'ix_tune_maintenance_room_finder'
)
BEGIN
    CREATE INDEX ix_tune_maintenance_room_finder
        ON dbo.maintenance_records (
            space_code,
            impact_level,
            maintenance_status,
            start_time
        )
        INCLUDE (
            completion_time
        );
END;
GO

/* =====================================================================
   INDEX 4 - Required facility lookup in Room Finder
   ===================================================================== */
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.facility_instances')
      AND name = N'ix_tune_facility_room_finder'
)
BEGIN
    CREATE INDEX ix_tune_facility_room_finder
        ON dbo.facility_instances (
            space_code,
            facility_type_id,
            instance_status
        );
END;
GO

/* SQL Server creates statistics for index keys automatically. */
PRINT 'G10 Phase 2 tuning indexes created successfully.';
GO

/* Audit the tuning indexes and their key/include columns. */
SELECT
    OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc,
    ic.key_ordinal,
    ic.is_included_column,
    c.name AS column_name
FROM sys.indexes AS i
INNER JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id
INNER JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE i.name IN (
          N'ix_tune_booking_conflict',
          N'ix_tune_booking_reporting',
          N'ix_tune_maintenance_room_finder',
          N'ix_tune_facility_room_finder'
      )
ORDER BY
    table_name,
    index_name,
    ic.is_included_column,
    ic.key_ordinal,
    ic.index_column_id;
GO

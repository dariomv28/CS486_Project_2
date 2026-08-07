/* =====================================================================
   CS486 - Introduction to Database Systems
   Group G10 - Phase 2
   Folder: 15-index-tuning-G10
   File: 00-drop-tuning-indexes.sql
   Target DBMS: Microsoft SQL Server

   Purpose:
     Restore the database to the controlled BEFORE-TUNING state by
     dropping:
       1. The Phase 2 tuning indexes created by
          02-create-tuning-indexes.sql.
       2. The surviving Phase 1 non-unique performance indexes that
          would otherwise help the benchmarked workloads.

   Phase 1 indexes intentionally removed for this experiment:
       - idx_booking_requests_space_time
       - idx_booking_requests_status
       - idx_maintenance_records_space_status

   Notes:
     - idx_facilities_space no longer exists after the Phase 2 migration
       because dbo.facilities is replaced by facility_types and
       facility_instances.
     - idx_maintenance_records_assigned_staff is removed by the Phase 2
       migration before assigned_staff_id is dropped.
     - Primary-key, UNIQUE/constraint-backed indexes, and structural
       indexes created by 10-schema-migration-G10.sql are NOT removed.
     - This is a controlled benchmark baseline. It is not a recommendation
       to remove useful indexes from a production database.

   Recommended execution order:
     00 -> 01 -> 02 -> 03
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* =====================================================================
   A. Drop Phase 2 tuning indexes
   ===================================================================== */

/* Booking conflict / room-finder booking-overlap index */
IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'dbo.booking_requests')
         AND name = N'ix_tune_booking_conflict'
   )
BEGIN
    DROP INDEX ix_tune_booking_conflict
        ON dbo.booking_requests;
END;
GO

/* Reporting index shared by Analytical Query 1 and Query 2 */
IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'dbo.booking_requests')
         AND name = N'ix_tune_booking_reporting'
   )
BEGIN
    DROP INDEX ix_tune_booking_reporting
        ON dbo.booking_requests;
END;
GO

/* Room-finder maintenance index */
IF OBJECT_ID(N'dbo.maintenance_records', N'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'dbo.maintenance_records')
         AND name = N'ix_tune_maintenance_room_finder'
   )
BEGIN
    DROP INDEX ix_tune_maintenance_room_finder
        ON dbo.maintenance_records;
END;
GO

/* Room-finder facility-instance index */
IF OBJECT_ID(N'dbo.facility_instances', N'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'dbo.facility_instances')
         AND name = N'ix_tune_facility_room_finder'
   )
BEGIN
    DROP INDEX ix_tune_facility_room_finder
        ON dbo.facility_instances;
END;
GO


/* =====================================================================
   B. Drop surviving Phase 1 performance indexes
   ===================================================================== */

/* Phase 1 booking space/time index */
IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'dbo.booking_requests')
         AND name = N'idx_booking_requests_space_time'
   )
BEGIN
    DROP INDEX idx_booking_requests_space_time
        ON dbo.booking_requests;
END;
GO

/* Phase 1 booking-status index */
IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'dbo.booking_requests')
         AND name = N'idx_booking_requests_status'
   )
BEGIN
    DROP INDEX idx_booking_requests_status
        ON dbo.booking_requests;
END;
GO

/* Phase 1 maintenance space/status index */
IF OBJECT_ID(N'dbo.maintenance_records', N'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'dbo.maintenance_records')
         AND name = N'idx_maintenance_records_space_status'
   )
BEGIN
    DROP INDEX idx_maintenance_records_space_status
        ON dbo.maintenance_records;
END;
GO


PRINT 'Phase 2 tuning indexes and surviving Phase 1 performance indexes have been removed.';
PRINT 'The database is ready for the controlled BEFORE benchmark.';
GO


/* =====================================================================
   C. Audit remaining indexes

   The remaining indexes should be primary-key / UNIQUE indexes and the
   structural indexes intentionally retained from the Phase 2 migration.
   ===================================================================== */
SELECT
    OBJECT_SCHEMA_NAME(i.object_id) AS schema_name,
    OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc,
    i.is_unique
FROM sys.indexes AS i
WHERE i.object_id IN (
          OBJECT_ID(N'dbo.booking_requests'),
          OBJECT_ID(N'dbo.maintenance_records'),
          OBJECT_ID(N'dbo.facility_instances')
      )
  AND i.name IS NOT NULL
ORDER BY
    table_name,
    index_name;
GO

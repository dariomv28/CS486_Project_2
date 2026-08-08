/* =====================================================================
   CS486 - Introduction to Database Systems
   Group G10 - Phase 2
   Folder: 15-index-tuning-G10
   File: 01-before-index-test.sql
   Target DBMS: Microsoft SQL Server

   Purpose:
     Measure the four required workloads in the controlled BEFORE state:
       - Phase 2 tuning indexes are absent.
       - Surviving Phase 1 non-unique performance indexes that could
         help these workloads are also absent.
       - Primary-key, UNIQUE/constraint-backed indexes and Phase 2
         structural indexes remain in place.

   BEFORE RUNNING:
     1. Load the generated dataset (100,000+ booking rows).
     2. Run 00-drop-tuning-indexes.sql.
     3. In SSMS enable Include Actual Execution Plan: Ctrl+M.
     4. Run this whole file.

   RECORD FOR EACH BENCHMARK:
     - Actual execution plan operators (Scan/Seek, join type, cost).
     - Logical reads from the Messages tab.
     - CPU time and elapsed time from the Messages tab.

   Fair-comparison note:
     Do not clear SQL Server's global buffer/procedure caches on a shared
     server. For timing, run this script 2-3 times and record a stable run
     (or the median). 03-after-index-test.sql uses exactly the same four
     workload queries and parameter values.

   Controlled-baseline note:
     00-drop-tuning-indexes.sql intentionally removes these surviving
     Phase 1 performance indexes before this script runs:
       - idx_booking_requests_space_time
       - idx_booking_requests_status
       - idx_maintenance_records_space_status
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Preconditions */
IF OBJECT_ID(N'dbo.booking_requests', N'U') IS NULL
BEGIN
    THROW 55001, 'dbo.booking_requests was not found.', 1;
END;

IF OBJECT_ID(N'dbo.facility_instances', N'U') IS NULL
BEGIN
    THROW 55002, 'Phase 2 facility_instances table was not found.', 1;
END;

IF (SELECT COUNT_BIG(*) FROM dbo.booking_requests) < 100000
BEGIN
    THROW 55003, 'Fewer than 100,000 booking rows were found. Load the generated dataset before benchmarking.', 1;
END;

IF EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name IN (
        N'ix_tune_booking_conflict',
        N'ix_tune_booking_reporting',
        N'ix_tune_maintenance_room_finder',
        N'ix_tune_maintenance_facility_availability',
        N'ix_tune_facility_room_finder'
    )
      AND object_id IN (
          OBJECT_ID(N'dbo.booking_requests'),
          OBJECT_ID(N'dbo.maintenance_records'),
          OBJECT_ID(N'dbo.facility_instances')
      )
)
BEGIN
    THROW 55004, 'A G10 Phase 2 tuning index still exists. Run 00-drop-tuning-indexes.sql first.', 1;
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
    THROW 55005, 'A surviving Phase 1 performance index still exists. Run 00-drop-tuning-indexes.sql first.', 1;
END;
GO

PRINT 'BEFORE benchmark: Phase 2 tuning indexes and targeted Phase 1 performance indexes are absent.';
PRINT 'Enable Actual Execution Plan (Ctrl+M) if it is not already enabled.';
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
/* =====================================================================
   BENCHMARK 1 - BOOKING CONFLICT CHECK

   Mirrors the protected approval overlap predicate in the Phase 2
   implementation. The late-period interval intentionally makes the
   engine inspect a meaningful portion of a busy generated space.
   ===================================================================== */
PRINT '============================================================';
PRINT 'BENCHMARK 1 - Booking conflict check';
PRINT '============================================================';

DECLARE @conflict_space_code VARCHAR(20) = 'DG021';
DECLARE @conflict_start_time DATETIME2(0) = '2025-08-31 20:00:00';
DECLARE @conflict_end_time   DATETIME2(0) = '2025-08-31 21:00:00';

SELECT
    br.booking_id,
    br.space_code,
    br.booking_status,
    br.requested_start_time,
    br.requested_end_time
FROM dbo.booking_requests AS br
WHERE br.space_code = @conflict_space_code
  AND br.booking_status IN (
          N'approved',
          N'checked in'
      )
  AND @conflict_start_time < br.requested_end_time
  AND @conflict_end_time > br.requested_start_time
OPTION (RECOMPILE);
GO

/* =====================================================================
   BENCHMARK 2 - ROOM FINDER (Analytical Query 3)

   Same semantics as 16-analytical-queries-G10.sql:
     capacity + operational status + all usable required facilities +
     no approved-booking overlap + no active out-of-service maintenance
     overlap. A facility instance under overlapping active maintenance is
     not counted as usable, even when that maintenance is only advisory.
   ===================================================================== */
PRINT '============================================================';
PRINT 'BENCHMARK 2 - Room finder';
PRINT '============================================================';

DECLARE @required_capacity INT = 30;
DECLARE @requested_start_time DATETIME2(0) = '2025-08-31 20:00:00';
DECLARE @requested_end_time   DATETIME2(0) = '2025-08-31 21:00:00';

DECLARE @RequiredFacilities TABLE (
    facility_name      NVARCHAR(100) NOT NULL PRIMARY KEY,
    required_quantity  INT           NOT NULL
        CHECK (required_quantity > 0)
);

INSERT INTO @RequiredFacilities (facility_name, required_quantity)
VALUES
    (N'Projector', 1),
    (N'Air conditioner', 1);

SELECT
    s.space_code,
    s.space_name,
    s.space_type,
    s.building,
    s.floor,
    s.room_number,
    s.capacity,
    s.current_status
FROM dbo.spaces AS s
WHERE s.capacity >= @required_capacity
  AND s.current_status NOT IN (
          N'temporarily closed',
          N'retired'
      )
  AND NOT EXISTS (
      SELECT 1
      FROM @RequiredFacilities AS required
      WHERE required.required_quantity > (
          SELECT COUNT_BIG(*)
          FROM dbo.facility_instances AS fi
          INNER JOIN dbo.facility_types AS ft
              ON ft.facility_type_id = fi.facility_type_id
          WHERE fi.space_code = s.space_code
            AND ft.facility_type_name = required.facility_name
            AND fi.instance_status = N'available'
            AND NOT EXISTS (
                SELECT 1
                FROM dbo.maintenance_records AS fm
                WHERE fm.facility_id = fi.facility_id
                  AND fm.maintenance_status IN (
                          N'reported',
                          N'assigned',
                          N'in progress'
                      )
                  AND fm.start_time < @requested_end_time
                  AND COALESCE(
                          fm.completion_time,
                          CONVERT(DATETIME2(0), '9999-12-31 23:59:59')
                      ) > @requested_start_time
            )
      )
  )
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.booking_requests AS br
      WHERE br.space_code = s.space_code
        AND br.booking_status IN (
                N'approved',
                N'checked in',
                N'completed',
                N'no-show'
            )
        AND br.requested_start_time < @requested_end_time
        AND br.requested_end_time > @requested_start_time
  )
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.maintenance_records AS mr
      WHERE mr.space_code = s.space_code
        AND mr.impact_level = N'out-of-service'
        AND mr.maintenance_status IN (
                N'reported',
                N'assigned',
                N'in progress'
            )
        AND mr.start_time < @requested_end_time
        AND COALESCE(
                mr.completion_time,
                CONVERT(DATETIME2(0), '9999-12-31 23:59:59')
            ) > @requested_start_time
  )
ORDER BY
    s.capacity,
    s.space_code
OPTION (RECOMPILE);
GO

/* =====================================================================
   BENCHMARK 3 - ANALYTICAL QUERY 1
   Total approved booking hours of each space for a semester.
   Only the booking portion inside [semester_start, semester_end) counts.
   ===================================================================== */
PRINT '============================================================';
PRINT 'BENCHMARK 3 - Analytical Query 1: approved booking hours';
PRINT '============================================================';

DECLARE @semester_start DATETIME2(0) = '2024-09-01 00:00:00';
DECLARE @semester_end   DATETIME2(0) = '2025-02-01 00:00:00';

;WITH ApprovedBookingSegments AS (
    SELECT
        br.booking_id,
        br.space_code,
        CASE
            WHEN br.requested_start_time < @semester_start
                THEN @semester_start
            ELSE br.requested_start_time
        END AS effective_start_time,
        CASE
            WHEN br.requested_end_time > @semester_end
                THEN @semester_end
            ELSE br.requested_end_time
        END AS effective_end_time
    FROM dbo.booking_requests AS br
    WHERE br.booking_status IN (
              N'approved',
              N'checked in',
              N'completed',
              N'no-show'
          )
      AND br.requested_start_time < @semester_end
      AND br.requested_end_time > @semester_start
)
SELECT
    s.space_code,
    s.space_name,
    s.space_type,
    s.building,
    s.room_number,
    CAST(
        COALESCE(
            SUM(
                DATEDIFF_BIG(
                    SECOND,
                    seg.effective_start_time,
                    seg.effective_end_time
                )
            ),
            0
        ) / 3600.0
        AS DECIMAL(18,2)
    ) AS total_approved_booking_hours
FROM dbo.spaces AS s
LEFT JOIN ApprovedBookingSegments AS seg
    ON seg.space_code = s.space_code
GROUP BY
    s.space_code,
    s.space_name,
    s.space_type,
    s.building,
    s.room_number
ORDER BY
    total_approved_booking_hours DESC,
    s.space_code
OPTION (RECOMPILE);
GO

/* =====================================================================
   BENCHMARK 4 - ANALYTICAL QUERY 2
   Number of approved bookings by weekday/hour of requested start time.
   Each booking contributes exactly one count.
   ===================================================================== */
PRINT '============================================================';
PRINT 'BENCHMARK 4 - Analytical Query 2: booking starts by weekday/hour';
PRINT '============================================================';

DECLARE @semester_start DATETIME2(0) = '2024-09-01 00:00:00';
DECLARE @semester_end   DATETIME2(0) = '2025-02-01 00:00:00';

;WITH ApprovedBookingStarts AS (
    SELECT
        br.booking_id,
        br.requested_start_time
    FROM dbo.booking_requests AS br
    WHERE br.booking_status IN (
              N'approved',
              N'checked in',
              N'completed',
              N'no-show'
          )
      AND br.requested_start_time >= @semester_start
      AND br.requested_start_time < @semester_end
),
BookingStartLabels AS (
    SELECT
        abs.booking_id,
        (
            (
                DATEDIFF(
                    DAY,
                    CONVERT(DATE, '19000101'),
                    CONVERT(DATE, abs.requested_start_time)
                ) % 7 + 7
            ) % 7
        ) + 1 AS weekday_number,
        DATENAME(WEEKDAY, abs.requested_start_time) AS weekday_name,
        DATEPART(HOUR, abs.requested_start_time) AS hour_of_day
    FROM ApprovedBookingStarts AS abs
)
SELECT
    bsl.weekday_number,
    bsl.weekday_name,
    bsl.hour_of_day,
    COUNT_BIG(*) AS approved_booking_count
FROM BookingStartLabels AS bsl
GROUP BY
    bsl.weekday_number,
    bsl.weekday_name,
    bsl.hour_of_day
ORDER BY
    bsl.weekday_number,
    bsl.hour_of_day
OPTION (RECOMPILE);
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

PRINT 'BEFORE benchmark complete. Save the execution plans and Messages output for deliverable 15.';
GO

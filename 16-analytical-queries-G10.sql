/* =====================================================================
   CS486 - Introduction to Database Systems
   Group G10 - Phase 2
   Deliverable 16: Analytical Queries
   Target DBMS: Microsoft SQL Server

   Database: CampusSpaceManagement

   Reports implemented:
     1. Total approved booking hours of each space for a semester.
     2. Number of approved bookings by weekday and hour for a semester.
     3. Room finder by capacity, facilities, booking conflicts, and maintenance.
     4. Approved bookings affected by advisory -> out-of-service escalation.

   Shared booking-status semantics used in this file:
     A booking is treated as belonging to the "approved lifecycle" when
     booking_status is one of:
         approved, checked in, completed, no-show

   This intentionally follows the Phase 2 reporting semantics. Pending,
   rejected, and cancelled requests are not counted as approved bookings.

   Interval semantics:
     All time ranges are treated as half-open intervals [start, end).
     Two intervals overlap exactly when:
         start_1 < end_2 AND end_1 > start_2
   This allows one booking/maintenance interval to end exactly when another
   one starts without being considered overlapping.
   ===================================================================== */

USE CampusSpaceManagement;
GO

/* =====================================================================
   QUERY 1
   Total approved booking hours of each space for a given semester.

   Important semantic choice:
   - Only the portion of a booking that actually lies inside the semester
     is counted.
   - Example: semester begins at 08:00 and a booking is 07:00-09:00;
     only 08:00-09:00 contributes to the report.
   - Spaces with no approved booking time are still returned with 0 hours.

   @semester_end is EXCLUSIVE.
   Replace the example parameter values as needed.
   ===================================================================== */

DECLARE @semester_start DATETIME2(0) = '2024-09-01 00:00:00';
DECLARE @semester_end   DATETIME2(0) = '2025-02-01 00:00:00';

IF @semester_end <= @semester_start
    THROW 56001, '@semester_end must be later than @semester_start.', 1;

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
      -- Keep only bookings that intersect the semester.
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
    s.space_code;
GO

/* =====================================================================
   QUERY 2
   Number of approved bookings by weekday and hour for a given semester.

   Chosen interpretation: FULL HOURLY OCCUPANCY.

   A booking contributes once to every hourly bucket that it overlaps.
   Therefore a booking from 09:00 to 12:00 contributes to:
       09:00, 10:00, 11:00

   A booking from 09:30 to 10:30 contributes to both the 09:00 and 10:00
   buckets because it overlaps both hourly intervals.

   Implementation choice:
   - First clip each approved booking to the semester interval.
   - Then recursively expand only that booking into the hour buckets it
     actually touches.
   This avoids generating every hour of the semester and joining every
   slot against the whole booking table.

   weekday_number uses Monday = 1, ..., Sunday = 7 and does not depend on
   SET DATEFIRST. weekday_name follows the SQL Server session language.

   @semester_end is EXCLUSIVE.
   ===================================================================== */

DECLARE @semester_start DATETIME2(0) = '2024-09-01 00:00:00';
DECLARE @semester_end   DATETIME2(0) = '2025-02-01 00:00:00';

IF @semester_end <= @semester_start
    THROW 56002, '@semester_end must be later than @semester_start.', 1;

;WITH ApprovedBookingSegments AS (
    SELECT
        br.booking_id,
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
),
BookingHourBuckets AS (
    -- Anchor: first hourly bucket touched by each clipped booking.
    SELECT
        abs.booking_id,
        CONVERT(
            DATETIME2(0),
            DATEADD(
                HOUR,
                DATEDIFF(HOUR, 0, abs.effective_start_time),
                0
            )
        ) AS hour_bucket_start,
        abs.effective_end_time
    FROM ApprovedBookingSegments AS abs

    UNION ALL

    -- Recursively add the next hour while it still intersects the booking.
    SELECT
        bhb.booking_id,
        DATEADD(HOUR, 1, bhb.hour_bucket_start),
        bhb.effective_end_time
    FROM BookingHourBuckets AS bhb
    WHERE DATEADD(HOUR, 1, bhb.hour_bucket_start) < bhb.effective_end_time
),
BucketLabels AS (
    SELECT
        bhb.booking_id,
        (
            (
                DATEDIFF(
                    DAY,
                    CONVERT(DATE, '19000101'),
                    CONVERT(DATE, bhb.hour_bucket_start)
                ) % 7 + 7
            ) % 7
        ) + 1 AS weekday_number,
        DATENAME(WEEKDAY, bhb.hour_bucket_start) AS weekday_name,
        DATEPART(HOUR, bhb.hour_bucket_start) AS hour_of_day
    FROM BookingHourBuckets AS bhb
)
SELECT
    bl.weekday_number,
    bl.weekday_name,
    bl.hour_of_day,
    COUNT_BIG(*) AS approved_booking_count
FROM BucketLabels AS bl
GROUP BY
    bl.weekday_number,
    bl.weekday_name,
    bl.hour_of_day
ORDER BY
    bl.weekday_number,
    bl.hour_of_day
OPTION (MAXRECURSION 0);
GO

/* =====================================================================
   QUERY 3
   ROOM FINDER

   Find spaces that satisfy ALL of the following:
     1. capacity >= @required_capacity
     2. current_status permits use
     3. the space has every required facility in sufficient quantity
     4. no approved-lifecycle booking overlaps the requested interval
     5. no active out-of-service maintenance overlaps the interval

   Phase 2 facility note:
   The Phase 1 dbo.facilities table was normalized into:
       dbo.facility_types
       dbo.facility_instances
   Therefore facility quantity is calculated by counting usable physical
   facility instances for each required facility type.

   Current-status semantic choice:
   - 'available' and 'in use' are operational statuses that may still be
     considered for another requested time interval.
   - 'under maintenance', 'temporarily closed', and 'retired' are excluded.

   Facility semantic choice:
   Only facility_instances whose instance_status = 'available' count toward
   the requested quantity.

   Replace the example parameters/facilities as needed.
   ===================================================================== */

DECLARE @required_capacity INT = 30;
DECLARE @requested_start_time DATETIME2(0) = '2025-03-10 09:00:00';
DECLARE @requested_end_time   DATETIME2(0) = '2025-03-10 11:00:00';

DECLARE @RequiredFacilities TABLE (
    facility_name      NVARCHAR(100) NOT NULL PRIMARY KEY,
    required_quantity  INT           NOT NULL
        CHECK (required_quantity > 0)
);

-- Example facility requirements. Edit or remove rows as needed.
INSERT INTO @RequiredFacilities (facility_name, required_quantity)
VALUES
    (N'Projector', 1),
    (N'Air conditioner', 1);

IF @required_capacity <= 0
    THROW 56003, '@required_capacity must be greater than zero.', 1;

IF @requested_end_time <= @requested_start_time
    THROW 56004, '@requested_end_time must be later than @requested_start_time.', 1;

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

  -- These statuses permit the space to be considered by the room finder.
  AND s.current_status IN (
          N'available',
          N'in use'
      )

  /* ---------------------------------------------------------------
     Relational division:
     There must NOT exist a required facility for which the space has
     fewer usable instances than the required quantity.
     --------------------------------------------------------------- */
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
      )
  )

  /* ---------------------------------------------------------------
     No overlapping booking that belongs to the approved lifecycle.
     --------------------------------------------------------------- */
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

  /* ---------------------------------------------------------------
     Advisory maintenance does NOT block the room.
     Only active out-of-service maintenance blocks an overlapping period.
     Open maintenance uses an effectively infinite completion time.
     --------------------------------------------------------------- */
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
    s.space_code;
GO

/* =====================================================================
   QUERY 4
   Approved bookings affected when maintenance is escalated from
   advisory to out-of-service.

   The historical table dbo.maintenance_impact_history is used instead of
   checking only maintenance_records.impact_level. This is important
   because a maintenance record may later be downgraded again, while the
   escalation event must remain historically discoverable.

   Required escalation condition:
       previous_impact_level = 'advisory'
       new_impact_level      = 'out-of-service'

   Required overlap condition:
       booking_start < maintenance_end
       booking_end   > maintenance_start

   @escalated_maintenance_id is optional:
     NULL -> report affected bookings for every advisory -> out-of-service
             escalation in history.
     value -> report only that maintenance record.

   The result contains the requester contact fields staff need in order to
   contact affected users. impact_change_id and escalated_at are included
   as additional audit information.
   ===================================================================== */

DECLARE @escalated_maintenance_id INT = NULL;

;WITH Escalations AS (
    SELECT
        mih.impact_change_id,
        mih.maintenance_id,
        mih.changed_at AS escalated_at,
        mih.changed_by,
        mih.change_reason
    FROM dbo.maintenance_impact_history AS mih
    WHERE mih.previous_impact_level = N'advisory'
      AND mih.new_impact_level = N'out-of-service'
      AND (
            @escalated_maintenance_id IS NULL
            OR mih.maintenance_id = @escalated_maintenance_id
          )
)
SELECT
    br.booking_id,
    br.requester_id,
    u.full_name AS requester_name,
    u.email,
    u.phone_number,
    br.space_code,
    br.requested_start_time,
    br.requested_end_time,
    mr.maintenance_id,
    mr.problem_description,
    e.impact_change_id,
    e.escalated_at
FROM Escalations AS e
INNER JOIN dbo.maintenance_records AS mr
    ON mr.maintenance_id = e.maintenance_id
INNER JOIN dbo.booking_requests AS br
    ON br.space_code = mr.space_code
   AND br.booking_status IN (
           N'approved',
           N'checked in',
           N'completed',
           N'no-show'
       )
   AND br.requested_start_time < COALESCE(
           mr.completion_time,
           CONVERT(DATETIME2(0), '9999-12-31 23:59:59')
       )
   AND br.requested_end_time > mr.start_time
INNER JOIN dbo.users AS u
    ON u.user_id = br.requester_id
ORDER BY
    e.escalated_at DESC,
    mr.maintenance_id,
    br.requested_start_time,
    br.booking_id;
GO

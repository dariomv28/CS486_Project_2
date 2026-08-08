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

   Interpretation used for the required Phase 2 report:
   - Each approved booking is counted exactly ONCE.
   - The weekday and hour are taken from requested_start_time.
   - Example: a booking starting Monday at 09:30 contributes one count to
     Monday / hour 09. It is not expanded into later hourly occupancy
     buckets.

   This follows the literal requirement "number of approved bookings by
   weekday and hour" and keeps this report distinct from an occupancy-hours
   report.

   weekday_number uses Monday = 1, ..., Sunday = 7 and does not depend on
   SET DATEFIRST. weekday_name follows the SQL Server session language.

   @semester_end is EXCLUSIVE.
   ===================================================================== */

DECLARE @semester_start DATETIME2(0) = '2024-09-01 00:00:00';
DECLARE @semester_end   DATETIME2(0) = '2025-02-01 00:00:00';

IF @semester_end <= @semester_start
    THROW 56002, '@semester_end must be later than @semester_start.', 1;

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
    bsl.hour_of_day;
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
   - 'available', 'in use', and 'under maintenance' may be considered
     for the requested time interval.
   - 'under maintenance' alone does not block booking in Phase 2.
     Maintenance availability is determined by impact level and overlap.
   - 'temporarily closed' and 'retired' are excluded.
   - An overlapping active out-of-service maintenance record blocks
     the requested time interval.

   Facility semantic choice:
   A facility instance counts toward the requested quantity only when:
     - instance_status = 'available', and
     - the physical instance is not itself affected by active maintenance
       that overlaps the requested interval.
   This matters for Phase 2 advisory maintenance: the room may remain usable,
   but a broken projector / faulty air conditioner must not be counted as a
   usable required facility while that maintenance is active.

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

  -- Phase 2:
  -- 'under maintenance' does not automatically make a space unavailable.
  -- Availability depends on whether an overlapping out-of-service
  -- maintenance record exists for the requested time interval.
  AND s.current_status NOT IN (
          N'temporarily closed',
          N'retired'
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

            -- A room-level advisory does not automatically remove a
            -- facility. A maintenance record tied to this exact physical
            -- facility instance does.
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

   Historical semantics:
   - dbo.maintenance_impact_history identifies the exact escalation event.
   - The out-of-service interval begins at the later of:
         maintenance start time, escalation time
     because time before escalation was still advisory.
   - The interval ends at the earlier of:
         maintenance completion time, next impact-level change
     so a later downgrade back to advisory is handled correctly.
   - A booking is treated as "already approved" when an approval decision
     exists at or before the escalation timestamp. This preserves bookings
     that were approved at escalation time even if their current status was
     later changed (for example, later cancellation).

   Schema limitation:
   The current schema does not store a complete booking-status history.
   Therefore, if a booking was approved and then cancelled BEFORE the
   escalation, that cancellation time cannot be reconstructed from the
   existing tables. Approval history is the strongest historical criterion
   available without changing the schema.

   @escalated_maintenance_id is optional:
     NULL -> report affected bookings for every advisory -> out-of-service
             escalation in history.
     value -> report only that maintenance record.

   The result includes requester contact fields so staff can contact the
   affected users, plus the effective out-of-service window used by the
   overlap test.
   ===================================================================== */

DECLARE @escalated_maintenance_id INT = NULL;

;WITH Escalations AS (
    SELECT
        mih.impact_change_id,
        mih.maintenance_id,
        mih.changed_at AS escalated_at,
        mih.changed_by,
        mih.change_reason,
        (
            SELECT TOP (1)
                next_mih.changed_at
            FROM dbo.maintenance_impact_history AS next_mih
            WHERE next_mih.maintenance_id = mih.maintenance_id
              AND (
                    next_mih.changed_at > mih.changed_at
                    OR (
                        next_mih.changed_at = mih.changed_at
                        AND next_mih.impact_change_id > mih.impact_change_id
                    )
                  )
            ORDER BY
                next_mih.changed_at,
                next_mih.impact_change_id
        ) AS next_impact_change_at
    FROM dbo.maintenance_impact_history AS mih
    WHERE mih.previous_impact_level = N'advisory'
      AND mih.new_impact_level = N'out-of-service'
      AND (
            @escalated_maintenance_id IS NULL
            OR mih.maintenance_id = @escalated_maintenance_id
          )
),
EscalationWindows AS (
    SELECT
        e.impact_change_id,
        e.maintenance_id,
        e.escalated_at,
        e.changed_by,
        e.change_reason,
        mr.space_code,
        mr.problem_description,
        CASE
            WHEN mr.start_time > e.escalated_at
                THEN mr.start_time
            ELSE e.escalated_at
        END AS out_of_service_start,
        CASE
            WHEN e.next_impact_change_at IS NOT NULL
                 AND e.next_impact_change_at < COALESCE(
                         mr.completion_time,
                         CONVERT(DATETIME2(0), '9999-12-31 23:59:59')
                     )
                THEN e.next_impact_change_at
            ELSE COALESCE(
                     mr.completion_time,
                     CONVERT(DATETIME2(0), '9999-12-31 23:59:59')
                 )
        END AS out_of_service_end
    FROM Escalations AS e
    INNER JOIN dbo.maintenance_records AS mr
        ON mr.maintenance_id = e.maintenance_id
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
    ew.maintenance_id,
    ew.problem_description,
    ew.impact_change_id,
    ew.escalated_at,
    ew.out_of_service_start,
    ew.out_of_service_end,
    a.decision_time AS approved_at,
    a.decision_method
FROM EscalationWindows AS ew
INNER JOIN dbo.booking_requests AS br
    ON br.space_code = ew.space_code
   AND br.requested_start_time < ew.out_of_service_end
   AND br.requested_end_time > ew.out_of_service_start
INNER JOIN dbo.approvals AS a
    ON a.booking_id = br.booking_id
   AND a.decision = N'approved'
   AND a.decision_time <= ew.escalated_at
INNER JOIN dbo.users AS u
    ON u.user_id = br.requester_id
WHERE ew.out_of_service_end > ew.out_of_service_start
ORDER BY
    ew.escalated_at DESC,
    ew.maintenance_id,
    br.requested_start_time,
    br.booking_id;
GO

/* =====================================================================
   File: 10-maint-approval-first-B.sql
   TEST 3A — Session B: maintenance escalation

   Run while 09-maint-approval-first-A.sql is waiting.

   Requires the updated dbo.usp_change_maintenance_impact from
   12-concurrency-implementation-G10-fixed-v3.sql because this test uses
   @return_result_sets = 0 to suppress internal output.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

DECLARE @MaintenanceId INT;

SELECT
    @MaintenanceId = mr.maintenance_id
FROM dbo.maintenance_records AS mr
WHERE mr.space_code = 'CONC-MAINT-G10'
  AND mr.start_time = '2035-03-01T09:00:00'
  AND mr.impact_level = N'advisory'
  AND mr.maintenance_status IN (N'reported', N'assigned', N'in progress');

IF @MaintenanceId IS NULL
    THROW 52366, 'Advisory maintenance M1 was not found. Run 00-test-setup.sql first.', 1;

EXEC dbo.usp_change_maintenance_impact
    @maintenance_id = @MaintenanceId,
    @new_impact_level = N'out-of-service',
    @changed_by = 'FS002',
    @change_reason = N'TEST 3A - issue became severe while a booking approval was racing.',
    @expected_current_impact_level = N'advisory',
    @lock_timeout_ms = 30000,
    @return_result_sets = 0;


/* RESULT 1:
   Full booking evidence.
   Shows exactly which booking, space and interval were approved. */
SELECT
    br.booking_id,
    br.requester_id,
    br.space_code,
    br.requested_start_time,
    br.requested_end_time,
    br.purpose_of_use,
    br.expected_participants,
    br.booking_status,
    a.decision,
    a.decision_method,
    a.staff_id,
    a.decision_time
FROM dbo.booking_requests AS br
LEFT JOIN dbo.approvals AS a
    ON a.booking_id = br.booking_id
WHERE br.space_code = 'CONC-MAINT-G10'
  AND br.requester_id = 'U001'
  AND br.requested_start_time = '2035-03-01T10:00:00'
  AND br.requested_end_time = '2035-03-01T12:00:00';


/* RESULT 2:
   Full maintenance evidence.
   Shows the maintenance record on the SAME space and its overlapping
   maintenance interval after escalation to out-of-service. */
SELECT
    mr.maintenance_id,
    mr.space_code,
    mr.facility_id,
    mr.problem_type,
    mr.problem_description,
    mr.start_time,
    mr.completion_time,
    mr.maintenance_status,
    mr.impact_level
FROM dbo.maintenance_records AS mr
WHERE mr.maintenance_id = @MaintenanceId;
GO
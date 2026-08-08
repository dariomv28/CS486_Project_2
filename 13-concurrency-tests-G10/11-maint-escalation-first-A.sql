/* =====================================================================
   File: 11-maint-escalation-first-A.sql
   Scenario: TEST 3B — maintenance escalation wins before approval
             Session A (maintenance escalation)

   TEST HARNESS ONLY.

   The production procedure dbo.usp_change_maintenance_impact refuses
   to join an existing transaction (error 52280), so this harness
   replicates its critical section verbatim in order to create the
   deterministic 10-second race window:

       BEGIN TRAN
       sp_getapplock CampusSpaceBooking:CONC-MAINT-G10
       WAITFOR 10 seconds          <-- run Session B here
       SESSION_CONTEXT for the maintenance history trigger
       UPDATE impact advisory -> out-of-service
       COMMIT

   SESSION_CONTEXT keys maintenance_changed_by /
   maintenance_change_reason are required by
   dbo.trg_maintenance_records_validate_and_sync, exactly as the
   production procedure sets them.

   While WAITFOR is active, run 12-maint-escalation-first-B.sql.
   Session B tries to approve booking MAINT-3B and must WAIT on the
   same lock, then fail with error 52229.
   ===================================================================== */

USE CampusSpaceManagement;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

DECLARE @MaintenanceId INT;
DECLARE @LockResult INT;
DECLARE @LockResource NVARCHAR(255) = N'CampusSpaceBooking:CONC-MAINT-G10';

SELECT
    @MaintenanceId = maintenance_id
FROM dbo.maintenance_records
WHERE space_code = 'CONC-MAINT-G10'
  AND start_time = '2035-03-02T09:00:00'
  AND impact_level = N'advisory'
  AND maintenance_status IN (N'reported', N'assigned', N'in progress');

IF @MaintenanceId IS NULL
    THROW 52367, 'Advisory maintenance M2 was not found. Run 00-test-setup.sql first.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = N'Exclusive',
        @LockOwner = N'Transaction',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 52368, 'TEST 3B Session A could not obtain the application lock.', 1;

    SELECT
        N'TEST 3B Session A acquired application lock' AS event_name,
        @LockResource AS lock_resource,
        @LockResult AS lock_result,
        @MaintenanceId AS maintenance_id,
        SYSDATETIME() AS event_time;

    PRINT 'TEST 3B Session A: lock acquired. Waiting 10 seconds. RUN SESSION B (12) NOW.';

    WAITFOR DELAY '00:00:10';

    /* Same SESSION_CONTEXT protocol as usp_change_maintenance_impact. */
    EXEC sys.sp_set_session_context
        @key = N'maintenance_changed_by',
        @value = 'FS001';

    EXEC sys.sp_set_session_context
        @key = N'maintenance_change_reason',
        @value = N'TEST 3B - escalated before the racing booking approval.';

    UPDATE dbo.maintenance_records
    SET impact_level = N'out-of-service'
    WHERE maintenance_id = @MaintenanceId;

    EXEC sys.sp_set_session_context
        @key = N'maintenance_changed_by',
        @value = NULL;

    EXEC sys.sp_set_session_context
        @key = N'maintenance_change_reason',
        @value = NULL;

    COMMIT TRANSACTION;

    PRINT CONCAT('TEST 3B Session A committed at ', CONVERT(VARCHAR(30), SYSDATETIME(), 126));

    SELECT
        maintenance_id,
        space_code,
        impact_level,
        maintenance_status,
        start_time,
        completion_time
    FROM dbo.maintenance_records
    WHERE maintenance_id = @MaintenanceId;

    SELECT
        impact_change_id,
        maintenance_id,
        previous_impact_level,
        new_impact_level,
        changed_by,
        changed_at,
        change_reason
    FROM dbo.maintenance_impact_history
    WHERE maintenance_id = @MaintenanceId
    ORDER BY impact_change_id;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    /* SESSION_CONTEXT survives rollback, so clean it manually. */
    BEGIN TRY
        EXEC sys.sp_set_session_context
            @key = N'maintenance_changed_by',
            @value = NULL;

        EXEC sys.sp_set_session_context
            @key = N'maintenance_change_reason',
            @value = NULL;
    END TRY
    BEGIN CATCH
        PRINT N'Warning: maintenance SESSION_CONTEXT cleanup failed.';
    END CATCH;

    THROW;
END CATCH;
GO

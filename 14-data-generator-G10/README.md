# 14-data-generator-G10

Deterministic large-data generator for **CS486 Phase 2 – Group G10**.

This folder is designed for the schema produced by the following execution order:

1. `05-db-definition-G10.sql`
2. `06-sample-data-G10.sql`
3. `10-schema-migration-G10.sql`
4. `12-concurrency-implementation-G10.sql`
5. Generate data with `generate_data.py`
6. Load it with `load_generated_data.sql`

## What is generated

Default run creates exactly **100,000 generated booking requests** over three full academic years:

- 2022–2023
- 2023–2024
- 2024–2025

Default booking-status distribution:

| Status | Percentage | Rows at 100,000 |
|---|---:|---:|
| approved | 15% | 15,000 |
| completed | 40% | 40,000 |
| cancelled | 15% | 15,000 |
| rejected | 10% | 10,000 |
| no-show | 5% | 5,000 |
| pending | 15% | 15,000 |

Thus `approved + completed = 55%`. This is the **chosen benchmark distribution** for G10; Phase 2 requires realistic large data but does not prescribe these exact percentages.

The generator also creates:

- 500 active users for the benchmark workload.
- 60 bookable spaces across all six Phase 1 space types.
- Facility instances linked to the normalized Phase 2 `facility_types` / `facility_instances` model.
- Approval records for approved, completed, no-show, and rejected requests, including both `staff` and `automatic` decision methods.
- Usage sessions for completed bookings.
- 1,200 maintenance records.
- Advisory maintenance and advisory acknowledgements.
- 100 advisory → out-of-service escalation cases so the “affected approved bookings” report has meaningful rows.
- Maintenance assignments.
- Equipment-consistent maintenance links: `broken projector` references a `Projector` instance and `air-conditioning failure` references an `Air conditioner` instance.

## Automatic approval generation

Phase 2 file `10-schema-migration-G10.sql` enables instant approval for the `meeting room` space type, while file `12-concurrency-implementation-G10.sql` requires automatic approvals to have no staff actor.

The generator therefore makes **60% of otherwise-approved meeting-room decisions automatic** (`AUTO_APPROVAL_RATE = 0.60`). All other approval decisions remain staff decisions; rejected requests are always staff decisions. Automatic rows use:

- `decision = approved`
- `decision_method = automatic`
- `staff_id = NULL` (empty CSV field)
- decision time equal to booking submission time

With the default seed and 100,000 bookings, the current generated dataset contains **5,936 automatic approvals** and **64,064 staff decisions**. The generator validates that no automatic approval is attached to a non-meeting-room booking.

## Maintenance-to-facility consistency

The normalized Phase 2 model stores individual facility instances. Equipment-specific generated maintenance therefore references a matching instance instead of a random facility in the room:

- `broken projector` → `Projector`
- `air-conditioning failure` → `Air conditioner`

Room-level issues such as damaged furniture, cleaning, network problems, or generic issues keep `facility_id = NULL`. The loader validates these equipment links before changing base tables.

## Determinism

The generator always uses:

```python
random.seed(48610)
```

Therefore the same command produces the same CSV contents.

## Booking-overlap rule

For every booking that entered the approved lifecycle (`approved`, `completed`, `no-show`), the generator allocates room/time blocks from a per-space slot set. Two such bookings are never assigned overlapping time intervals for the same space.

Pending, rejected, and cancelled requests may overlap, which gives the conflict-check/index workload realistic noise.

Normal out-of-service maintenance is generated outside booking hours. A small separate set of maintenance rows deliberately starts as `advisory` and is later escalated to `out-of-service` after bookings already existed. Those rows are intentional because Phase 2 explicitly requires finding already-approved bookings affected by an escalation.

## Advisory acknowledgement rule

Every generated booking whose requested interval overlaps a maintenance record that **started as advisory** receives a row in `booking_advisory_acknowledgements.csv`.

For escalation cases, the booking acknowledges the advisory first; the maintenance is then changed to out-of-service. This matches the Phase 2 workflow.

## Files in `generated/`

After generation:

```text
generated/
├── users.csv
├── spaces.csv
├── facility_instances.csv
├── booking_requests.csv
├── approvals.csv
├── usage_sessions.csv
├── maintenance_records.csv
├── maintenance_assignments.csv
├── maintenance_escalations.csv
├── booking_advisory_acknowledgements.csv
└── manifest.json
```

`manifest.json` contains row counts, the seed, status distribution, invariant-check results, and SHA-256 hashes of the generated CSV files.

## Step 1 — Generate 100,000 bookings

From this folder:

```bash
python generate_data.py
```

No third-party Python package is required.

To regenerate a larger dataset for index testing:

```bash
python generate_data.py --bookings 500000
```

The generator refuses values below 100,000 because Phase 2 requires at least 100,000 booking records.

> Note: 500,000 rows produce much larger CSV files and take longer to load. Start with 100,000 and only increase if the execution-plan/time difference is not clear enough.

## Step 2 — Load into SQL Server

`load_generated_data.sql` uses `BULK INSERT` and a SQLCMD variable named `DataDir`.

### SSMS on Windows

1. Open `load_generated_data.sql`.
2. Enable **Query → SQLCMD Mode**.
3. Edit this line near the top:

```sql
:setvar DataDir "C:\absolute\path\to\14-data-generator-G10\generated\"
```

4. The path must be readable by the **SQL Server service**, not only by SSMS.
5. Execute the whole script.

### SQL Server in Docker/Linux

Mount the generated folder into the SQL Server container, for example as:

```text
/var/opt/mssql/data-generator/
```

Then set:

```sql
:setvar DataDir "/var/opt/mssql/data-generator/"
```

and execute the script through a SQLCMD-capable client.

## How the loader preserves the workflow

The loader does not simply force all final booking statuses into the table.

1. Generated bookings that will become approved/rejected/completed/no-show are inserted as `pending`.
2. `approvals.csv` is inserted; the existing approval trigger synchronizes approved/rejected status.
3. `usage_sessions.csv` is inserted; the existing usage-session trigger changes completed bookings to `completed`.
4. Approved bookings that were not used are changed to `no-show`.
5. Maintenance is inserted with its initial impact level.
6. The 100 generated escalation rows are updated from advisory to out-of-service with the required maintenance session context, so the Phase 2 maintenance-history trigger records the change.
7. Advisory acknowledgement rows are inserted.

This keeps the generated dataset consistent with the Phase 2 schema and trigger design while still using set-based bulk loading.

## Rerunning safely

The CSV generator still uses deterministic identity values beginning at `1,000,000`, but the loader **does not use `>= 1,000,000` as its cleanup rule**. SQL Server may assign ordinary rows values above that threshold after a benchmark load.

Generated ownership is identified by the reserved `DG...` users/spaces instead:

- generated spaces use `space_code LIKE 'DG%'`
- generated users use `user_id LIKE 'DG%'`
- generated bookings are discovered through a DG space/requester
- generated maintenance is discovered through a DG space
- child rows are deleted through those captured booking/maintenance IDs

Therefore rerunning the loader does not delete an unrelated normal booking or maintenance row merely because its identity value is greater than `1,000,000`. Rows attached to DG benchmark parents are considered part of the generated dataset and are intentionally replaced on reload.

## Required statistics refresh

At the end of the load script:

```sql
UPDATE STATISTICS dbo.booking_requests WITH FULLSCAN;
UPDATE STATISTICS dbo.maintenance_records WITH FULLSCAN;
```

The script also refreshes statistics for `facility_instances` and `booking_advisory_acknowledgements` because they participate in Phase 2 reporting.

## Expected verification results

At the end of `load_generated_data.sql`, check that:

- `generated_booking_count >= 100000`.
- Three academic years are present.
- Cancellation rows exist.
- No-show rows exist.
- Maintenance rows exist.
- Advisory acknowledgement rows exist.
- Both `automatic` and `staff` approval rows exist.
- Equipment-specific maintenance rows reference matching facility types.
- `approved_booking_overlap_pairs_should_be_zero = 0`.
- `unintended_oos_overlap_pairs_should_be_zero = 0`.
- `intentional_escalation_affected_booking_pairs > 0`.

These checks give direct evidence that the generated data satisfies the Phase 2 data requirements and contains useful cases for the later analytical-query and index-tuning deliverables.

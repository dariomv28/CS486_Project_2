# 15. Index Tuning and Query Performance Report — G10

## 1. Purpose

This report documents the Phase 2 indexing and query-tuning work for the Campus Space Management database. The benchmark covers the four workloads selected for detailed performance analysis:

1. Booking conflict check.
2. Room Finder (Analytical Query 3).
3. Analytical Query 1 — total approved booking hours of each space for a semester.
4. Analytical Query 2 — number of approved bookings by weekday and hour for a semester.

The goal is to compare the same queries before and after adding targeted nonclustered indexes, using SQL Server `SET STATISTICS IO ON`, `SET STATISTICS TIME ON`, and Actual Execution Plan in SSMS.

---

## 2. Benchmark Dataset

The benchmark uses the generated Phase 2 dataset from `14-data-generator-G10/`.

| Item | Generated amount |
|---|---:|
| Academic years | 3 (`2022-2023`, `2023-2024`, `2024-2025`) |
| Booking requests | 100,000 |
| Spaces | 60 |
| Facility instances | 473 |
| Maintenance records | 1,200 |
| Approvals | 70,000 |
| Usage sessions | 40,000 |
| Advisory acknowledgements | 4,144 |

The booking data covers the interval from `2022-09-01` through `2025-08-31`. This volume is large enough for the benchmark to expose substantial differences in logical I/O when the booking table is accessed with and without suitable indexes.

---

## 3. Controlled Benchmark Method

The benchmark scripts are executed in the following order:

```text
15-index-tuning-G10/
├── 00-drop-tuning-indexes.sql
├── 01-before-index-test.sql
├── 02-create-tuning-indexes.sql
└── 03-after-index-test.sql
```

### 3.1 BEFORE state

`00-drop-tuning-indexes.sql` removes the Phase 2 tuning indexes and also removes the surviving Phase 1 non-unique performance indexes that could otherwise influence the comparison:

- `idx_booking_requests_space_time`
- `idx_booking_requests_status`
- `idx_maintenance_records_space_status`

Primary-key indexes, UNIQUE/constraint-backed indexes, and structural Phase 2 indexes are intentionally retained. Therefore, the BEFORE state is a controlled no-tuning baseline rather than a recommendation for a production system.

### 3.2 AFTER state

`02-create-tuning-indexes.sql` creates the five indexes described in Section 5. `03-after-index-test.sql` then runs the same four benchmark queries with the same parameter values as the BEFORE test.

Both test scripts use:

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
```

and each benchmark query uses:

```sql
OPTION (RECOMPILE);
```

This reduces the chance that an old cached plan makes the before/after comparison misleading.

### 3.3 Timing interpretation

The values in this report are the captured runs stored in:

- `before_index_result.txt`
- `after_index_result.txt`

Execution time can vary between runs because of CPU scheduling, cache state, compilation, and other activity on the SQL Server instance. Logical reads are therefore treated as the most stable evidence of reduced data access, while CPU and elapsed time are reported as additional evidence.

---

## 4. Benchmark Workloads

### 4.1 Booking conflict check

Parameters:

```text
space_code = DG021
requested interval = 2025-08-31 20:00:00 to 2025-08-31 21:00:00
```

The query searches for overlapping bookings for the same space where the current booking status is `approved` or `checked in`.

Core predicates:

```sql
br.space_code = @conflict_space_code
AND br.booking_status IN (N'approved', N'checked in')
AND @conflict_start_time < br.requested_end_time
AND @conflict_end_time > br.requested_start_time
```

### 4.2 Room Finder — Analytical Query 3

Parameters:

```text
required capacity = 30
requested interval = 2025-08-31 20:00:00 to 2025-08-31 21:00:00
required facilities = Projector x1, Air conditioner x1
```

The Room Finder checks all of the following:

- required room capacity;
- usable space status;
- sufficient available facility instances;
- facility instances not affected by overlapping active maintenance;
- no overlapping approved/active booking lifecycle record;
- no overlapping active `out-of-service` maintenance record.

### 4.3 Analytical Query 1 — approved booking hours

Semester interval:

```text
2024-09-01 00:00:00 to 2025-02-01 00:00:00
```

The report calculates the portion of each approved-lifecycle booking that lies inside the semester and sums those durations by space. The statuses included are:

```text
approved, checked in, completed, no-show
```

### 4.4 Analytical Query 2 — approved bookings by weekday/hour

The same semester interval is used. Each booking contributes one count according to the weekday and hour of its `requested_start_time`.

The statuses included are:

```text
approved, checked in, completed, no-show
```

---

## 5. Index Design

### 5.1 `ix_tune_booking_conflict`

```sql
CREATE INDEX ix_tune_booking_conflict
    ON dbo.booking_requests (
        space_code,
        booking_status,
        requested_start_time
    )
    INCLUDE (requested_end_time);
```

**Used by:**

- Booking conflict check.
- Booking-overlap component of Room Finder.

**Rationale:**

`space_code` is the strongest equality predicate because every conflict is checked within one room. `booking_status` is also filtered directly. `requested_start_time` then supports the upper-bound part of the overlap condition. `requested_end_time` is included so SQL Server can evaluate the remaining overlap condition from the index without needing an additional lookup for that column.

---

### 5.2 `ix_tune_booking_reporting`

```sql
CREATE INDEX ix_tune_booking_reporting
    ON dbo.booking_requests (
        booking_status,
        requested_start_time
    )
    INCLUDE (
        requested_end_time,
        space_code
    );
```

**Used by:**

- Analytical Query 1.
- Analytical Query 2.

**Rationale:**

Both reports first restrict bookings to approved lifecycle statuses and a semester-related time range. `booking_status` and `requested_start_time` are therefore the leading key columns. `requested_end_time` is required by Analytical Query 1 for interval clipping, while `space_code` is required to aggregate hours by room. Including those columns makes the booking portion of the reports substantially more covering than the baseline table access.

---

### 5.3 `ix_tune_maintenance_room_finder`

```sql
CREATE INDEX ix_tune_maintenance_room_finder
    ON dbo.maintenance_records (
        space_code,
        impact_level,
        maintenance_status,
        start_time
    )
    INCLUDE (completion_time);
```

**Used by:** Room Finder.

**Rationale:**

The room-level maintenance exclusion is correlated by `space_code` and only considers `out-of-service` maintenance with an active status. `start_time` participates in the interval predicate, while `completion_time` is included for the second half of the overlap check.

---

### 5.4 `ix_tune_facility_room_finder`

```sql
CREATE INDEX ix_tune_facility_room_finder
    ON dbo.facility_instances (
        space_code,
        facility_type_id,
        instance_status
    );
```

**Used by:** Room Finder.

**Rationale:**

The Room Finder counts available facility instances for each space and required facility type. The key order matches the correlated room lookup, facility type filtering, and `available` instance-status filtering.

---

### 5.5 `ix_tune_maintenance_facility_availability`

```sql
CREATE INDEX ix_tune_maintenance_facility_availability
    ON dbo.maintenance_records (
        facility_id,
        maintenance_status,
        start_time
    )
    INCLUDE (completion_time)
    WHERE facility_id IS NOT NULL;
```

**Used by:** Room Finder.

**Rationale:**

A physical facility instance must not be counted as usable while that exact instance has overlapping active maintenance. The filtered index targets only maintenance rows associated with a facility instance, making the correlated lookup by `facility_id` smaller than an unfiltered general-purpose index.

---

## 6. Before/After Results

### 6.1 Overall performance summary

The table below summarizes the captured BEFORE and AFTER benchmark results. Logical reads are the primary comparison metric because they are more stable than short execution-time measurements.

| # | Workload | Main read metric | BEFORE | AFTER | Improvement | CPU time | Elapsed time |
|---:|---|---|---:|---:|---:|---|---|
| 1 | Booking conflict check | `booking_requests` logical reads | 2,539 | 9 | **99.65% fewer reads** | 15 ms → 0 ms | 17 ms → 0 ms |
| 2 | Room Finder | Core physical-table logical reads | 56,453 | 1,194 | **97.88% fewer reads** | 407 ms → 0 ms | 439 ms → 7 ms |
| 3 | Analytical Query 1 | `booking_requests` logical reads | 2,539 | 317 | **87.51% fewer reads** | 63 ms → 16 ms | 62 ms → 24 ms |
| 4 | Analytical Query 2 | `booking_requests` logical reads | 2,539 | 68 | **97.32% fewer reads** | 16 ms → 16 ms | 40 ms → 11 ms |

> **Overall result:** all four workloads require substantially fewer logical reads after indexing. The largest improvement is the booking conflict check, which drops from 2,539 reads to only 9.

---

### 6.2 Benchmark 1 — Booking Conflict Check

#### Performance results

| Metric | BEFORE | AFTER | Change |
|---|---:|---:|---:|
| `booking_requests` scan count | 1 | 2 | — |
| `booking_requests` logical reads | 2,539 | 9 | **↓ 99.65%** |
| CPU time | 15 ms | 0 ms | **↓ 15 ms** |
| Elapsed time | 17 ms | 0 ms | **↓ 17 ms** |

#### Interpretation

The most important result is the reduction in `booking_requests` logical reads from **2,539 to 9**. The `ix_tune_booking_conflict` index lets SQL Server narrow the search by `space_code`, `booking_status`, and `requested_start_time`, while `requested_end_time` is available directly from the index through `INCLUDE`.

Although the AFTER timing is displayed as `0 ms`, this should be interpreted as being below the display resolution of `SET STATISTICS TIME`, not as literally requiring zero processing time. The logical-read reduction is therefore the stronger performance evidence.

---

### 6.3 Benchmark 2 — Room Finder

#### Logical reads by object

| Object | BEFORE | AFTER | Difference | Change |
|---|---:|---:|---:|---:|
| `booking_requests` | 55,858 | 451 | -55,407 | **↓ 99.19%** |
| `maintenance_records` | 124 | 415 | +291 | ↑ |
| `facility_instances` | 305 | 162 | -143 | **↓ 46.89%** |
| `facility_types` | 160 | 160 | 0 | No change |
| `spaces` | 6 | 6 | 0 | No change |
| **Core physical tables total** | **56,453** | **1,194** | **-55,259** | **↓ 97.88%** |
| Temporary table | 95 | 95 | 0 | No change |
| Worktable | 343 | 0 | -343 | **Eliminated** |
| **Total listed reads** | **56,891** | **1,289** | **-55,602** | **↓ 97.73%** |

#### Execution time

| Metric | BEFORE | AFTER | Change |
|---|---:|---:|---:|
| CPU time | 407 ms | 0 ms | **↓ 407 ms** |
| Elapsed time | 439 ms | 7 ms | **↓ 98.41%** |

#### Interpretation

The dominant BEFORE cost is the booking-overlap check. `booking_requests` alone requires **55,858 logical reads** before tuning but only **451** afterward. This is a **99.19% reduction** for that table.

`maintenance_records` increases from 124 to 415 reads because the Room Finder performs several targeted correlated maintenance checks. However, this increase is small compared with the reduction of more than 55,000 booking-table reads. The worktable activity is also removed completely, from 343 reads to 0.

As a result, total core physical-table reads fall from **56,453 to 1,194**, and captured elapsed time falls from **439 ms to 7 ms**.

---

### 6.4 Benchmark 3 — Analytical Query 1: Approved Booking Hours

#### Performance results

| Metric | BEFORE | AFTER | Change |
|---|---:|---:|---:|
| `booking_requests` scan count | 1 | 4 | — |
| `booking_requests` logical reads | 2,539 | 317 | **↓ 87.51%** |
| `spaces` logical reads | 6 | 6 | No change |
| CPU time | 63 ms | 16 ms | **↓ 74.60%** |
| Elapsed time | 62 ms | 24 ms | **↓ 61.29%** |

#### Interpretation

The reporting index reduces access to `booking_requests` from **2,539 logical reads to 317**. SQL Server still needs to calculate clipped booking durations and aggregate them by space, so some processing remains unavoidable.

The warning `Null value is eliminated by an aggregate or other SET operation.` may appear because the query uses a `LEFT JOIN` with aggregation. It appears independently of the indexing improvement and does not indicate an index error.

---

### 6.5 Benchmark 4 — Analytical Query 2: Approved Bookings by Weekday and Hour

#### Performance results

| Metric | BEFORE | AFTER | Change |
|---|---:|---:|---:|
| `booking_requests` scan count | 1 | 4 | — |
| `booking_requests` logical reads | 2,539 | 68 | **↓ 97.32%** |
| CPU time | 16 ms | 16 ms | No change |
| Elapsed time | 40 ms | 11 ms | **↓ 72.50%** |

#### Interpretation

Logical reads fall from **2,539 to 68**, which is a **97.32% reduction**. Elapsed time also improves from **40 ms to 11 ms**.

CPU time remains 16 ms in both captured runs. This is reasonable for a short query because CPU timing is coarse and the query still performs weekday/hour expression evaluation, grouping, and sorting. The major reduction in logical reads remains the clearest evidence that the reporting index improves access to the semester's qualifying booking rows.

---

### 6.6 Result ranking

| Rank | Workload | Logical-read reduction |
|---:|---|---:|
| 1 | Booking conflict check | **99.65%** |
| 2 | Room Finder — core physical tables | **97.88%** |
| 3 | Analytical Query 2 | **97.32%** |
| 4 | Analytical Query 1 | **87.51%** |

All four tuned workloads show a clear reduction in logical I/O, with every benchmark reducing its principal read metric by more than **87%**.

---

## 7. Execution-Plan Comparison

The benchmark scripts explicitly require Actual Execution Plan (`Ctrl+M`) to be enabled in SSMS. However, the submitted ZIP contains the SQL scripts and the `STATISTICS IO/TIME` text outputs but **does not contain saved `.sqlplan` files or execution-plan screenshots**. For that reason, this report does not fabricate exact operator names or operator costs that are not present in the captured evidence.

The available I/O results nevertheless show the intended plan effect:

| Benchmark | Evidence from I/O | Index responsible for the main improvement |
|---|---|---|
| Booking conflict | `booking_requests` reads: 2,539 → 9 | `ix_tune_booking_conflict` |
| Room Finder | `booking_requests` reads: 55,858 → 451; core reads: 56,453 → 1,194 | `ix_tune_booking_conflict`, `ix_tune_facility_room_finder`, `ix_tune_maintenance_room_finder`, `ix_tune_maintenance_facility_availability` |
| Analytical Query 1 | `booking_requests` reads: 2,539 → 317 | `ix_tune_booking_reporting` |
| Analytical Query 2 | `booking_requests` reads: 2,539 → 68 | `ix_tune_booking_reporting` |

### Evidence to attach for strict execution-plan documentation

Before final submission, the group should save or screenshot the Actual Execution Plan for each benchmark in both the BEFORE and AFTER states. The plan evidence should be used to record, for each query:

- whether the large booking-table access changes from a broad scan to targeted index access;
- which of the new indexes SQL Server actually selects;
- join operators used by Room Finder;
- aggregate/sort operators used by Analytical Queries 1 and 2;
- any remaining high-cost operator or warning.

This is the only benchmark evidence that is not currently preserved in `final_ver2(1).zip`.

---

## 8. Why Five Indexes Are Used for Four Workloads

The assignment asks for tuning of four workloads, but a complex query does not necessarily require only one index. Room Finder accesses three main data areas:

1. booking overlap;
2. room-level maintenance overlap;
3. facility availability and facility-specific maintenance.

Therefore, using several focused indexes for Room Finder is more appropriate than creating one oversized index that attempts to cover unrelated tables and predicates.

The booking-conflict index is also reused by Room Finder, while the reporting index is reused by both selected analytical reports. This avoids creating a separate index for every individual query when the access patterns are compatible.

---

## 9. Trade-offs of the Tuning Strategy

The new indexes improve read-heavy booking and reporting workloads, but they also introduce standard indexing costs:

- additional disk space;
- additional work on `INSERT`, `UPDATE`, and `DELETE` operations;
- more index maintenance when booking status or requested times change;
- more index maintenance when maintenance status/time data changes;
- additional statistics that SQL Server must maintain.

For this database, the trade-off is reasonable because conflict checking and room availability are correctness-critical operations and the analytical reports are expected to run repeatedly over a large historical booking table.

The filtered facility-maintenance index reduces part of this write/storage overhead by indexing only rows where `facility_id IS NOT NULL`.

---

## 10. Reproduction Procedure

To reproduce the benchmark:

1. Create the Phase 1 database and apply the Phase 2 migration.
2. Load the generated data from `14-data-generator-G10/` and verify that at least 100,000 booking rows exist.
3. Open SSMS and enable **Include Actual Execution Plan** (`Ctrl+M`).
4. Run `15-index-tuning-G10/00-drop-tuning-indexes.sql`.
5. Run `15-index-tuning-G10/01-before-index-test.sql` and save the Messages output and execution plans.
6. Run `15-index-tuning-G10/02-create-tuning-indexes.sql`.
7. Run `15-index-tuning-G10/03-after-index-test.sql` and save the Messages output and execution plans.
8. Compare logical reads, CPU time, elapsed time, and execution-plan operators.

For fair timing comparison, repeat the benchmark two or three times and use a stable run or median rather than intentionally clearing SQL Server's global buffer/procedure caches on a shared server.

---

## 11. Final Evaluation

### Final performance comparison

| Workload | BEFORE logical reads | AFTER logical reads | Reduction | BEFORE elapsed | AFTER elapsed | Evaluation |
|---|---:|---:|---:|---:|---:|---|
| Booking conflict check | 2,539 | 9 | **99.65%** | 17 ms | 0 ms | Excellent improvement |
| Room Finder — core tables | 56,453 | 1,194 | **97.88%** | 439 ms | 7 ms | Excellent improvement |
| Analytical Query 1 | 2,539 | 317 | **87.51%** | 62 ms | 24 ms | Strong improvement |
| Analytical Query 2 | 2,539 | 68 | **97.32%** | 40 ms | 11 ms | Excellent improvement |

The chosen indexes are effective for the Phase 2 workload. All four tuned queries show substantial reductions in logical I/O, and three of the four reduce the principal logical-read metric by more than **97%**.

The strongest result is the **Booking Conflict Check**, where reads fall from **2,539 to 9**. The most expensive baseline workload is the **Room Finder**, where core physical-table reads fall from **56,453 to 1,194** and elapsed time falls from **439 ms to 7 ms**.

Therefore, the indexing strategy satisfies the Phase 2 query-tuning objective for the captured benchmark data. The remaining documentation task is to preserve the Actual Execution Plan screenshots or `.sqlplan` files so that the operator-level BEFORE/AFTER comparison can also be demonstrated directly.


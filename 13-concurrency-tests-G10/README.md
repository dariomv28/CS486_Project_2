# 13-concurrency-tests-G10

Concurrency test scripts for **CS486 Phase 2 – Group G10**.

These scripts demonstrate both sides of the same race condition:

1. **Without concurrency control**: two overlapping requests for the same space both pass an early conflict check and are then both approved.
2. **With the G10 solution**: Session A owns the per-space application lock, Session B waits, and after Session A commits, Session B rechecks the data and receives conflict error **52230**.

The production solution being tested is implemented in `12-concurrency-implementation-G10.sql` using the transaction-owned application-lock resource:

```text
CampusSpaceBooking:<space_code>
```

For these tests the dedicated space is:

```text
CampusSpaceBooking:CONC-G10
```

## Prerequisites

Run the project scripts in this order before starting the tests:

```text
05-db-definition-G10.sql
06-sample-data-G10.sql
10-schema-migration-G10.sql
12-concurrency-implementation-G10.sql
00-test-setup.sql
```

Open **two SSMS query windows**, both connected to database `CampusSpaceManagement`.

> Run the tests with a database owner/admin account. The production `campus_app_role` is intentionally denied direct DML by deliverable 12.

## Test data

`00-test-setup.sql` creates one dedicated space and four pending requests:

| Scenario | Requester | Time |
|---|---|---|
| UNSAFE A | U001 | 2035-01-15 09:00–11:00 |
| UNSAFE B | U002 | 2035-01-15 10:00–12:00 |
| SAFE A | U001 | 2035-01-16 09:00–11:00 |
| SAFE B | U002 | 2035-01-16 10:00–12:00 |

Each pair overlaps by one hour and uses the same space `CONC-G10`.

---

## Test 1 — no concurrency control

### SSMS Session A

Run:

```text
01-race-condition-session-A.sql
```

When Session A prints that it is waiting for 10 seconds, immediately run Session B.

### SSMS Session B

Run:

```text
02-race-condition-session-B.sql
```

### Expected result

Both sessions perform a conflict check while both requests are still `pending`, so both checks report no conflict. Session B approves and commits while Session A is waiting. Session A does **not recheck** after the wait and approves using its stale decision.

Expected final state for the UNSAFE pair:

```text
UNSAFE A = approved
UNSAFE B = approved
```

### Why the booking validation trigger is temporarily disabled in this negative test

`10-schema-migration-G10.sql` still contains the ordinary overlap-validation trigger `dbo.trg_booking_requests_validate`. Under the exact deterministic schedule required here (B commits before A writes), that trigger would reject A and hide the application-level **check-then-write** race.

Therefore `01-race-condition-session-A.sql` temporarily disables only this validation trigger while the intentionally unsafe test runs, then re-enables it. This is a **test harness only** and is not part of the production design. The positive test below keeps the trigger enabled and tests the actual `sp_getapplock` solution.

---

## Test 2 — concurrency-safe approval

After Test 1 finishes, keep the same database state. Do **not** rerun setup.

### SSMS Session A

Run:

```text
03-safe-approval-session-A.sql
```

Session A explicitly obtains the same transaction-owned application lock used by the implementation, then waits 10 seconds before approving SAFE A.

### SSMS Session B

While Session A is waiting, run:

```text
04-safe-approval-session-B.sql
```

Session B calls the public procedure `dbo.usp_approve_booking` for SAFE B.

### Expected result

1. Session A owns `CampusSpaceBooking:CONC-G10`.
2. Session B blocks inside `sp_getapplock`.
3. Session A approves SAFE A and commits.
4. Session B acquires the lock only after A commits.
5. Session B rechecks overlapping approved bookings.
6. Session B receives:

```text
Error 52230
The booking conflicts with another approved booking.
```

Expected final state for the SAFE pair:

```text
SAFE A = approved
SAFE B = pending
```

---

## Verify

After both tests, run:

```text
05-verify-results.sql
```

The script first proves the negative test produced **2 approved overlapping bookings**, then proves the protected test produced **exactly 1 approved booking**. It then removes the intentionally invalid UNSAFE approvals, restores the trigger defensively, and performs a final invariant check.

Expected final test-space state after verification/cleanup:

```text
Exactly one booking is approved.
```

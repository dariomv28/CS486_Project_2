# 11. Concurrency Design – Group G10

## 1. Purpose

This document identifies the concurrency conflicts that may occur in the Phase 2 Campus Space Management System and presents the concurrency-control solution selected by Group G10.

The primary business invariant is:

> Two bookings for the same space whose requested time intervals overlap must never both become approved, even when booking submission, instant approval, and staff approval are executed concurrently.

The design targets Microsoft SQL Server and is based on the Phase 2 schema after the migration implemented in `10-schema-migration-G10.sql`.

---

# 2. Concurrency Problems

## 2.1 Concurrent booking approval

Assume space **A101** currently has no approved booking.

Two pending booking requests exist:

```
Booking B1 : A101, 09:00 – 11:00
Booking B2 : A101, 10:00 – 12:00
```

Two staff members approve them simultaneously.

```
Transaction T1                  Transaction T2
-----------------------------------------------------------
BEGIN TRAN

Check conflict
No conflict

                                BEGIN TRAN

                                Check conflict
                                No conflict

Approve B1

                                Approve B2

COMMIT

                                COMMIT
```

Both transactions observe the room as available before either transaction commits.

Final result:

- B1 approved
- B2 approved

Although both bookings overlap.

This is a classic **check-then-act race condition**.

---

## 2.2 Concurrent approval and maintenance escalation

Suppose maintenance is initially:

```
impact_level = advisory
```

Transaction A approves an overlapping booking.

At the same time,

Transaction B changes

```
advisory
→
out-of-service
```

Without proper synchronization,

the booking may become approved although the room has already become unavailable.

---

## 2.3 Two staff members modifying the same booking

Example:

```
Staff A approves booking B1.

Staff B rejects booking B1 using an old screen.
```

The second operation must not overwrite the first decision.

---

# 3. Design Goals

The concurrency solution must guarantee:

1. Two overlapping bookings for the same space cannot both become approved.

2. Automatic approval and staff approval follow exactly the same synchronization protocol.

3. Maintenance escalation is coordinated with booking approval.

4. One booking receives only one final decision.

5. Transactions affecting different spaces should still execute concurrently.

---

# 4. Solutions Considered

## 4.1 ROWVERSION only

The migration introduces

```
BOOKING_REQUEST.version_token
```

implemented as SQL Server `ROWVERSION`.

It detects stale updates on the same booking.

Example:

```
Staff A approves booking.

Staff B still edits the old version.
```

The version mismatch is detected.

However,

ROWVERSION cannot prevent

```
Booking B1
Booking B2
```

from being approved simultaneously because they are different rows.

Therefore,

ROWVERSION alone is insufficient.

---

## 4.2 Trigger-only validation

The migration already recreates

```
trg_booking_requests_validate
```

The trigger checks overlapping approved bookings.

However,

under READ COMMITTED isolation,

Transaction T2 may not observe T1's uncommitted approval.

Therefore,

both trigger executions may succeed.

Triggers remain a defensive validation mechanism but are not the primary concurrency-control solution.

---

## 4.3 SERIALIZABLE isolation

Using SERIALIZABLE isolation would serialize all conflicting range scans.

Advantages:

- correctness

Disadvantages:

- larger lock ranges
- unnecessary blocking
- higher deadlock probability
- reduced concurrency

Therefore,

Group G10 does not serialize the entire booking workload.

---

## 4.4 SQL Server Application Lock

SQL Server provides

```sql
EXEC sp_getapplock
```

which locks a logical resource instead of a database row.

The chosen resource is

```
CampusSpaceBooking:<space_code>
```

Example:

```
CampusSpaceBooking:A101
```

Advantages:

- bookings for the same room execute sequentially
- bookings for different rooms remain concurrent
- independent of table structure
- automatically released after COMMIT or ROLLBACK

Therefore,

this is selected as the primary synchronization mechanism.

---

# 5. Selected Concurrency Strategy

Every operation capable of approving a booking or making a room unavailable must execute inside one SQL Server transaction.

The procedure performs the following steps.

```
BEGIN TRANSACTION

↓

Read booking

↓

Verify booking is pending

↓

Check ROWVERSION

↓

Acquire application lock
CampusSpaceBooking:<space_code>

↓

Re-check booking information

↓

Check overlapping approved bookings

↓

Check overlapping
out-of-service maintenance

↓

Insert approval

↓

Update booking status

↓

COMMIT
```

Conflict checking is always performed **after obtaining the application lock**.

---

# 6. Lock Granularity

The application lock is created per room.

Example:

```
CampusSpaceBooking:A101
```

If two transactions affect

```
A101
```

the second transaction waits.

If transactions affect

```
A101
B205
```

they execute concurrently.

This maximizes concurrency while protecting each room independently.

---

# 7. Instant Approval

If

```
SPACE_TYPE_POLICY.instant_approval_enabled = 1
```

the booking may be automatically approved.

However,

instant approval must not directly execute

```sql
UPDATE booking_requests
SET booking_status='approved'
```

Instead,

automatic approval calls exactly the same protected approval procedure as staff approval.

Therefore,

both approval methods use identical locking behavior.

---

# 8. ROWVERSION

ROWVERSION protects modifications to the same booking.

Workflow:

```
User loads booking

↓

Database changes booking

↓

User submits old version

↓

Version mismatch detected

↓

Reject update
```

ROWVERSION does not solve overlapping bookings,

but prevents stale updates.

---

# 9. Maintenance Escalation

Suppose

```
advisory
→
out-of-service
```

The maintenance procedure also acquires

```
CampusSpaceBooking:<space_code>
```

before changing maintenance status.

Two outcomes exist.

### Escalation commits first

```
Maintenance becomes
out-of-service

↓

Booking approval waits

↓

Booking rechecks maintenance

↓

Approval rejected
```

### Approval commits first

```
Booking approved

↓

Maintenance escalates

↓

Affected booking identified

↓

Staff contacts requester
```

The booking is not automatically cancelled.

---

# 10. Advisory Acknowledgement

If a booking overlaps advisory maintenance,

the requester must acknowledge it.

The booking transaction performs:

```
Create booking

↓

Find active advisories

↓

Validate acknowledgements

↓

Insert acknowledgement rows

↓

Commit
```

Booking creation and acknowledgement commit together.

---

# 11. Deadlock Prevention

The design minimizes deadlocks by following several rules.

## Rule 1

Most booking transactions lock only one room.

## Rule 2

If multiple rooms must be locked,

always acquire them in ascending `space_code`.

Example:

```
A101

↓

B205

↓

C301
```

## Rule 3

Transactions remain short.

Long operations such as

- email sending
- report generation
- remote API calls

must occur after COMMIT.

---

# 12. Isolation Level

The design uses SQL Server's default

```
READ COMMITTED
```

instead of SERIALIZABLE.

Correctness is guaranteed by

- transaction
- application lock
- conflict revalidation
- ROWVERSION

rather than by globally increasing the isolation level.

---

# 13. Relationship with Indexes

The application lock guarantees correctness.

Indexes only improve performance.

Typical indexes include

```
(space_code,
 booking_status,
 requested_start_time)
```

for booking conflict checking,

and

```
(space_code,
 impact_level,
 maintenance_status,
 start_time)
```

for maintenance validation.

Detailed evaluation is presented in

```
15-index-tuning-report-G10.md
```

---

# 14. Concurrency Test Plan

The implementation will be validated using two SQL Server sessions.

## Test 1

Two staff approve overlapping bookings.

Expected:

```
Only one booking approved.
```

---

## Test 2

Automatic approval and staff approval execute simultaneously.

Expected:

```
One transaction waits.

Conflict rechecked.

Only one booking approved.
```

---

## Test 3

Maintenance escalation and booking approval execute simultaneously.

Expected:

```
Escalation first
→ approval rejected

Approval first
→ affected booking identified
```

---

## Test 4

Two staff modify the same booking.

Expected:

```
First transaction succeeds.

Second transaction rejected
because booking status or
ROWVERSION has changed.
```

---

# 15. Correctness Argument

Every approval transaction must obtain

```
CampusSpaceBooking:<space_code>
```

before checking conflicts.

SQL Server grants an exclusive application lock to only one transaction for each room.

Therefore,

only one transaction can evaluate booking conflicts and maintenance conditions for the same room at a time.

After one transaction commits,

the next transaction observes the committed result before making its approval decision.

Consequently,

two overlapping bookings for the same room cannot both become approved.

Transactions involving different rooms use different application-lock resources and therefore execute concurrently.

---

# 16. Final Design Decision

Group G10 selects the following strategy:

- Explicit SQL Server transactions.
- Transaction-owned `sp_getapplock` per `space_code`.
- Conflict checking after obtaining the lock.
- Maintenance revalidation after obtaining the lock.
- Shared approval procedure for automatic and staff approval.
- ROWVERSION for stale updates.
- Triggers retained as defensive validation.
- Per-room locking instead of database-wide serialization.

This design guarantees correctness while preserving high concurrency for operations involving different spaces.
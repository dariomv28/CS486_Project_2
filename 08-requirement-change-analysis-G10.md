# 08. Requirement Change Analysis – Group G10

## 1. Purpose

Phase 2 extends the Phase 1 Campus Space Management System after the pilot semester. The changes affect maintenance handling, booking approval, concurrency control, and reporting.

This document identifies:

- the Phase 2 requirement changes;
- the entities and relationships affected by those changes;
- the business rules that must be revised or added;
- the concurrency conflicts that can occur during booking and approval;
- the resulting design implications implemented by Group G10.

The analysis is aligned with the finalized Group G10 Phase 2 implementation in `final_ver2(1).zip`, especially:

- `09-updated-erd-and-logical-design-G10.md`;
- `10-schema-migration-G10.sql`;
- `11-concurrency-design-G10.md`;
- `12-concurrency-implementation-G10.sql`;
- `13-concurrency-tests-G10/`;
- `16-analytical-queries-G10.sql`.

---

## 2. Summary of Phase 2 Requirement Changes

| ID | Requirement area | Phase 1 behavior / limitation | Phase 2 requirement | Main impact on Group G10 design |
|---|---|---|---|---|
| RC-01 | Maintenance availability | Maintenance effectively made the whole space unavailable. | Distinguish `advisory` and `out-of-service` maintenance. | Add `impact_level` to maintenance and change booking-availability logic. |
| RC-02 | Advisory notification | No acknowledgement of maintenance advisories was stored with bookings. | A space with advisory maintenance remains bookable, but the requester must be informed and acknowledgement must be recorded. | Add `booking_advisory_acknowledgements`; add advisory lookup and validation during submission. |
| RC-03 | Multiple maintenance records | The old rule did not need to distinguish simultaneous maintenance effects. | A space may have several active maintenance records with different impact levels. | Availability must evaluate all overlapping maintenance records rather than a single room status. |
| RC-04 | Impact-level changes | No explicit history of impact-level escalation/downgrade was required. | Open maintenance may change `advisory ↔ out-of-service`; affected approved bookings must be identifiable after escalation. | Add `maintenance_impact_history`; synchronize escalation with booking approval. |
| RC-05 | Instant approval | Approval was staff-based. | Selected space types may be approved automatically when the usage policy is satisfied. | Add `space_type_policies` and `approvals.decision_method`; automatic decisions have no staff actor. |
| RC-06 | Concurrent booking and approval | Ordinary validation is insufficient when simultaneous operations check availability before either commits. | Two overlapping bookings for the same space must never both become approved, regardless of automatic or staff approval. | Add per-space transaction synchronization using `sp_getapplock` and revalidation after locking. |
| RC-07 | Stale booking decisions | A staff member could act using an outdated copy of the booking row. | A later stale operation must not overwrite an earlier final decision. | Add `booking_requests.version_token` using SQL Server `ROWVERSION`. |
| RC-08 | Reporting | Phase 1 reports do not cover the new accumulated history requirements. | Add semester utilization, weekday/hour booking counts, room finder, and affected-booking reports. | Preserve richer booking, facility, maintenance, and impact-history data and implement four analytical queries. |

---

## 3. Requirement Change 1 – Maintenance Impact Levels

### 3.1 Previous rule

The Phase 1 model treated active maintenance as a reason that a space could not be booked. This was suitable when every maintenance record was assumed to make the space unusable.

That assumption is too strong for Phase 2 because some problems affect only equipment or comfort while the room itself remains usable.

### 3.2 New maintenance semantics

Phase 2 introduces two impact levels:

| Impact level | Meaning | Booking effect |
|---|---|---|
| `advisory` | The space remains usable, although equipment or comfort may be degraded. | Booking is allowed if all other rules pass, but the requester must acknowledge every relevant active advisory. |
| `out-of-service` | The maintenance makes the space unusable. | Any booking whose requested interval overlaps the maintenance interval must be rejected / prevented. |

Therefore, the rule changes from a simple state check to an interval-based rule involving:

```text
space_code
impact_level
maintenance_status
start_time
completion_time
requested_start_time
requested_end_time
```

The finalized overlap convention is the half-open interval rule:

```text
booking_start < maintenance_end
AND
booking_end > maintenance_start
```

This allows one interval to end exactly when another begins without treating them as overlapping.

### 3.3 Multiple simultaneous maintenance records

A space may now have several active maintenance records at the same time. For example:

| Maintenance | Impact | Effect |
|---|---|---|
| Broken projector | `advisory` | Room remains bookable; requester must be informed. |
| Damaged whiteboard | `advisory` | Room remains bookable; another acknowledgement may be required. |
| Electrical repair | `out-of-service` | Room cannot be booked for the overlapping period. |

Consequently, `SPACE.current_status` alone is no longer sufficient to determine whether a requested time period is bookable. Booking logic must inspect the maintenance records that overlap the requested interval.

---

## 4. Requirement Change 2 – Advisory Acknowledgement

The Phase 2 requirement states that the requester must be informed of all active advisory maintenance affecting the requested booking period and that this acknowledgement must be stored.

Group G10 therefore models acknowledgement as a separate relationship between a booking and maintenance records.

### 4.1 Required relationship

```text
BOOKING_REQUEST
    M : N
MAINTENANCE_RECORD
```

implemented through:

```text
BOOKING_ADVISORY_ACKNOWLEDGEMENT(
    booking_id,
    maintenance_id,
    acknowledged_at
)
```

with composite primary key:

```text
(booking_id, maintenance_id)
```

### 4.2 Why a separate relation is necessary

A single booking may overlap several advisories, and one advisory may affect many bookings. A single Boolean such as `booking.advisory_acknowledged` would not record **which** advisories were shown to the requester.

The separate relation preserves a precise acknowledgement history.

### 4.3 Final submission rule implemented by G10

The finalized implementation uses the following workflow:

1. `usp_get_booking_advisories` returns the currently relevant advisory records for the chosen space and time.
2. The requester is informed of those advisories.
3. The requester submits the booking with the acknowledged maintenance IDs.
4. `usp_submit_booking` obtains the per-space lock and recalculates the required advisories.
5. Submission succeeds only when every currently required advisory is present in the acknowledgement list.
6. Unrelated / forged maintenance IDs are rejected.
7. Valid acknowledgements are stored in `booking_advisory_acknowledgements`.

This prevents a booking from being created with incomplete acknowledgement information for the advisory set that exists at submission time.

---

## 5. Requirement Change 3 – Maintenance Escalation and Downgrade

An open maintenance record may change impact level, for example:

```text
advisory -> out-of-service
```

or:

```text
out-of-service -> advisory
```

Only storing the current value in `maintenance_records.impact_level` would lose the historical transition. Group G10 therefore keeps the current impact level in `maintenance_records` and stores each change in `maintenance_impact_history`.

### 5.1 New history relation

```text
MAINTENANCE_IMPACT_HISTORY(
    impact_change_id,
    maintenance_id,
    previous_impact_level,
    new_impact_level,
    changed_by,
    changed_at,
    change_reason
)
```

This supports questions such as:

- when an advisory was escalated;
- who changed the impact level;
- why the change occurred;
- whether it was later downgraded;
- which bookings were already approved when the out-of-service period became effective.

### 5.2 Affected approved bookings

When a maintenance record is escalated from `advisory` to `out-of-service`, the system must identify already-approved bookings that overlap the effective out-of-service interval.

The final implementation supports this in two places:

- `usp_change_maintenance_impact` returns affected approved bookings when escalation occurs;
- Analytical Query 4 in `16-analytical-queries-G10.sql` reconstructs affected bookings from maintenance impact history and approval history.

---

## 6. Requirement Change 4 – Automatic Approval

Phase 2 allows selected space types to use instant approval when the usage policy is satisfied.

The previous staff-only approval representation is therefore insufficient.

### 6.1 Space-type approval policy

Group G10 introduces:

```text
SPACE_TYPE_POLICY(
    space_type,
    instant_approval_enabled,
    policy_description
)
```

with relationship:

```text
SPACE_TYPE_POLICY 1 : N SPACE
```

This avoids repeating the same instant-approval configuration on every individual space.

In the finalized migration, `meeting room` is configured with instant approval enabled; other migrated space types are initialized with instant approval disabled.

### 6.2 Approval actor and method

`APPROVAL` is extended with:

```text
decision_method
```

whose valid values are:

```text
automatic
staff
```

The final constraints implement the following rules:

| Decision type | `decision_method` | `staff_id` | Allowed decision |
|---|---|---|---|
| Automatic approval | `automatic` | `NULL` | `approved` only |
| Staff decision | `staff` | Required | `approved` or `rejected` |

A rejected booking must contain a rejection reason.

### 6.3 Automatic approval eligibility

In `usp_submit_booking`, automatic approval is attempted only when both conditions hold:

```text
instant_approval_enabled = 1
AND
usage_policy_satisfied = 1
```

If either condition is false, the request remains in the staff workflow.

---

## 7. Affected Entities

The following table summarizes the schema impact of the Phase 2 changes as implemented by Group G10.

| Entity / relation | Change type | Phase 2 change | Reason |
|---|---|---|---|
| `USER` | No major structural change | Existing users now also act as maintenance impact changers and maintenance assignees. | New workflows reuse the existing user identity model. |
| `SPACE` | Relationship / rule change | `space_type` now references `SPACE_TYPE_POLICY`; maintenance availability is no longer determined from `current_status` alone. | Support configurable instant approval and advisory maintenance. |
| `SPACE_TYPE_POLICY` | **New** | Stores `instant_approval_enabled` and policy description per space type. | Support selected space types with instant approval. |
| Phase 1 facility representation | Replaced / normalized | Split into `FACILITY_TYPE` and `FACILITY_INSTANCE`. | Support physical facility instances and more precise maintenance / room-finder behavior. |
| `FACILITY_TYPE` | **New** | Stores facility categories such as projector or air conditioner. | Separate type-level data from physical instances. |
| `FACILITY_INSTANCE` | **New** | Stores each physical facility with `space_code`, asset tag, status, and condition. | A maintenance issue may affect one particular facility rather than the whole room. |
| `BOOKING_REQUEST` | Extended | Add `version_token ROWVERSION`. | Detect stale decisions on the same booking. |
| `APPROVAL` | Extended | Add `decision_method`; allow nullable `staff_id` for automatic approval. | Represent both staff and automatic decisions correctly. |
| `USAGE_SESSION` | No major structural change | Existing usage history is preserved. | Still needed for the approved booking lifecycle and utilization reporting. |
| `MAINTENANCE_RECORD` | Extended | Add `facility_id` and `impact_level`. | Distinguish advisory/out-of-service maintenance and optionally target a physical facility. |
| `MAINTENANCE_ASSIGNMENT` | **New** | Stores maintenance assignment history. | Preserve reassignment/history instead of only one current staff value. |
| `MAINTENANCE_IMPACT_HISTORY` | **New** | Stores each impact-level transition. | Support escalation/downgrade history and affected-booking analysis. |
| `BOOKING_ADVISORY_ACKNOWLEDGEMENT` | **New** | Connects bookings to acknowledged advisory maintenance records. | Store evidence that the requester was informed. |

---

## 8. Affected Relationships

| Relationship | Cardinality | Phase 2 effect |
|---|---|---|
| `SPACE_TYPE_POLICY` – `SPACE` | `1 : N` | A policy controls the booking behavior of all spaces of one space type. |
| `SPACE` – `FACILITY_INSTANCE` | `1 : N` | A space contains individual physical facility instances. |
| `FACILITY_TYPE` – `FACILITY_INSTANCE` | `1 : N` | A facility type classifies many physical instances. |
| `FACILITY_INSTANCE` – `MAINTENANCE_RECORD` | `0..1 : N` from the maintenance side | A maintenance record may target one facility instance or the whole space. |
| `BOOKING_REQUEST` – `APPROVAL` | `1 : 0..1` | A booking may remain undecided; at most one final approval row exists. |
| `USER` – `APPROVAL` | optional actor on each approval | Staff approvals reference a user; automatic approvals intentionally have no staff actor. |
| `MAINTENANCE_RECORD` – `MAINTENANCE_ASSIGNMENT` | `1 : N` | One maintenance task can have assignment history and multiple staff participants over time. |
| `MAINTENANCE_RECORD` – `MAINTENANCE_IMPACT_HISTORY` | `1 : N` | One maintenance record can have multiple impact transitions. |
| `BOOKING_REQUEST` – `BOOKING_ADVISORY_ACKNOWLEDGEMENT` | `1 : N` | One booking may acknowledge multiple advisories. |
| `MAINTENANCE_RECORD` – `BOOKING_ADVISORY_ACKNOWLEDGEMENT` | `1 : N` | One advisory may be acknowledged by many bookings. |

---

## 9. Revised and New Business Rules

The following rules form the Phase 2 business-rule set relevant to the requirement changes.

| Rule ID | Business rule | Status |
|---|---|---|
| BR-P2-01 | An active `advisory` maintenance record does **not** by itself make the space unavailable. | New |
| BR-P2-02 | An active `out-of-service` maintenance record blocks any booking whose requested interval overlaps the maintenance interval. | Revised |
| BR-P2-03 | A space may have several active maintenance records simultaneously, including records with different impact levels. | New |
| BR-P2-04 | A requester must acknowledge **all** active advisory records relevant to the requested booking interval before submission is accepted. | New |
| BR-P2-05 | Each stored acknowledgement identifies both the booking and the specific maintenance advisory. | New |
| BR-P2-06 | An open maintenance record may be escalated or downgraded between `advisory` and `out-of-service`. | New |
| BR-P2-07 | Every impact-level change must be historically traceable through maintenance impact history. | New |
| BR-P2-08 | When an advisory becomes `out-of-service`, already-approved bookings overlapping the effective out-of-service interval must be identifiable. | New |
| BR-P2-09 | Selected space types may use automatic approval only when instant approval is enabled for that type and the usage policy is satisfied. | New |
| BR-P2-10 | An automatic decision can only approve a booking and has no `staff_id`. | New |
| BR-P2-11 | A staff decision requires a staff actor; rejection requires a rejection reason. | Revised |
| BR-P2-12 | Two bookings for the same space whose time intervals overlap must never both belong to the approved state simultaneously. | Strengthened for concurrency |
| BR-P2-13 | BR-P2-12 must hold regardless of whether the decisions come from automatic approval, staff approval, or concurrent combinations of both. | New |
| BR-P2-14 | Booking approval must be revalidated after obtaining synchronization for the target space; an earlier availability check alone is not sufficient. | New |
| BR-P2-15 | Approval/booking operations for different spaces should not be unnecessarily serialized with each other. | New concurrency design goal |
| BR-P2-16 | A staff decision based on an old `version_token` must be rejected rather than overwrite a newer booking state. | New |
| BR-P2-17 | Temporarily closed and retired spaces remain unbookable. | Preserved |
| BR-P2-18 | Expected participants must not exceed the selected space capacity. | Preserved |
| BR-P2-19 | Once core booking information is finalized through approval/check-in/completion, protected booking details cannot be silently changed. | Preserved / enforced |

---

## 10. Concurrency Conflict Analysis

The most important Phase 2 risk is a **check-then-act race condition**: two operations can both read the same space as available before either writes its approval result.

### 10.1 Conflict CC-01 – Staff approval vs staff approval

Assume two pending bookings for the same space:

```text
B1: 09:00 - 11:00
B2: 10:00 - 12:00
```

Possible interleaving without concurrency control:

| Step | Staff transaction T1 | Staff transaction T2 |
|---:|---|---|
| 1 | Check B1 conflict → none | |
| 2 | | Check B2 conflict → none |
| 3 | Approve B1 | |
| 4 | | Approve B2 |
| 5 | Commit | Commit |

Incorrect final state:

```text
B1 = approved
B2 = approved
```

even though the time periods overlap.

**Required handling:** both staff approval paths must synchronize on the same `space_code`, then recheck conflicts while holding that synchronization.

---

### 10.2 Conflict CC-02 – Automatic approval vs staff approval

A booking may be automatically approved at submission time while a staff member is approving another overlapping pending request for the same space.

Without a shared protocol, the automatic and manual paths could each check availability independently and both approve.

**Required handling:** automatic approval and staff approval must use the **same per-space synchronization resource and conflict check**, rather than implementing two independent approval rules.

The finalized implementation routes both through the same core approval logic and uses the application-lock resource:

```text
CampusSpaceBooking:<space_code>
```

---

### 10.3 Conflict CC-03 – Automatic approval vs automatic approval

Two users can submit overlapping requests for a popular instant-approval space at nearly the same time. If both satisfy the usage policy, both could attempt automatic approval.

**Required handling:** submission and automatic approval for the same space must be serialized by the same per-space lock, and the second operation must revalidate the first committed approval before it can approve its own booking.

---

### 10.4 Conflict CC-04 – Booking approval vs maintenance escalation

Initial state:

```text
maintenance impact = advisory
```

Possible concurrent operations:

- Transaction A approves an overlapping booking.
- Transaction B escalates the maintenance to `out-of-service`.

If these operations are not coordinated, the system can finish in an inconsistent state where a newly approved booking overlaps a maintenance interval that has become unavailable.

**Required handling:** maintenance escalation and booking approval must acquire the same per-space synchronization resource. Whichever transaction obtains the lock first establishes the state that the second transaction must revalidate.

Expected outcomes:

| First transaction | Second transaction behavior |
|---|---|
| Booking approval commits first | Escalation proceeds and identifies the already-approved booking as affected. |
| Escalation commits first | Later booking approval sees `out-of-service` maintenance and fails. |

---

### 10.5 Conflict CC-05 – Two staff decisions on the same booking

Example:

1. Staff A reads booking B1 while it is pending.
2. Staff B also reads B1.
3. Staff A approves B1.
4. Staff B later attempts to reject B1 using the old screen state.

A per-space lock prevents overlapping-space races but does not by itself prove that Staff B is using the current version of the **same booking row**.

**Required handling:** compare the expected `version_token` with the current SQL Server `ROWVERSION`. A mismatch means the operation is stale and must be rejected.

This is why Group G10 uses both mechanisms:

| Mechanism | Protects against |
|---|---|
| Per-space `sp_getapplock` | Conflicts between different booking / maintenance rows affecting the same physical space. |
| `ROWVERSION` | Stale updates / stale decisions on the same booking row. |

`ROWVERSION` alone is not sufficient for two different overlapping booking rows, while the per-space lock alone does not provide the same explicit stale-screen detection semantics for a booking decision.

---

## 11. Selected Concurrency-Control Strategy

Group G10's final concurrency design uses a **transaction-owned exclusive application lock per `space_code`**.

Conceptually:

```text
BEGIN TRANSACTION

Acquire Exclusive application lock:
    CampusSpaceBooking:<space_code>

Re-read and revalidate current database state

Perform approval / maintenance change / submission

COMMIT
```

### 11.1 Why lock by space

The main invariant is local to a physical space. Operations affecting A101 must be coordinated with other operations affecting A101, but they do not need to block operations for B205.

Therefore, a lock resource based on `space_code` provides finer concurrency than one global booking lock.

### 11.2 Operations using the same synchronization protocol

The final implementation uses the same per-space lock for operations including:

- booking submission;
- automatic approval;
- staff approval;
- maintenance impact escalation;
- maintenance creation;
- relevant space-status changes.

This is important because a concurrency invariant is only reliable when all code paths that can violate it participate in the same locking protocol.

---

## 12. Facility Model Impact

Although the core Phase 2 maintenance requirement is expressed at the space level, examples such as a broken projector or one faulty air conditioner show that a maintenance issue may affect a **specific physical facility** rather than the whole room.

The finalized Group G10 design therefore replaces the Phase 1 quantity-style facility representation with:

```text
FACILITY_TYPE
FACILITY_INSTANCE
```

This supports:

- multiple instances of the same facility type in one room;
- maintenance tied to one particular asset;
- facility availability checks for the room finder;
- advisory problems that reduce usable equipment quantity without necessarily closing the room.

When `maintenance_records.facility_id` is supplied, the composite reference:

```text
(facility_id, space_code)
    -> FACILITY_INSTANCE(facility_id, space_code)
```

ensures that the selected facility instance belongs to the same space as the maintenance record.

---

## 13. Reporting Impact

Phase 2 adds four required reports. The requirement changes affect the data needed by each report as follows.

| Required report | Main data required | Phase 2 design dependency |
|---|---|---|
| Total approved booking hours of each space for a semester | `booking_requests`, spaces, approved booking lifecycle | Requires preserved historical bookings and statuses. |
| Number of approved bookings by weekday and hour for a semester | `booking_requests` and approved lifecycle | Requires large booking history and time attributes. |
| Available spaces satisfying capacity and facility requirements for a time period | `spaces`, `facility_types`, `facility_instances`, `booking_requests`, `maintenance_records` | Must distinguish advisory from out-of-service maintenance and count usable physical facility instances. |
| Approved bookings affected by maintenance escalation | `maintenance_records`, `maintenance_impact_history`, `approvals`, `booking_requests` | Requires exact escalation history and approval timing. |

A key consequence is that historical data must not be overwritten when an impact level or assignment changes. This justifies the dedicated history relations introduced in the updated design.

---

## 14. Migration Implications

The requirement changes must be applied on top of the existing Phase 1 database while preserving its data semantics.

The final migration strategy in `10-schema-migration-G10.sql` addresses this as follows:

| Phase 1 data | Phase 2 migration treatment | Rationale |
|---|---|---|
| Existing spaces | Preserved; each existing `space_type` receives a corresponding policy row. | Retain spaces while enabling configurable instant approval. |
| Existing approvals | Preserved and marked `decision_method = 'staff'`. | Phase 1 decisions were staff decisions. |
| Existing booking requests | Preserved; SQL Server adds a `ROWVERSION` token. | Add optimistic concurrency without replacing booking history. |
| Existing maintenance records | Preserved and initialized as `out-of-service`. | Phase 1 maintenance blocked the whole room, so `out-of-service` preserves the old semantics. |
| Existing maintenance assignment | Migrated into `maintenance_assignments`. | Preserve assignment information in the new history-capable structure. |
| Existing maintenance impact state | Initial history rows are created in `maintenance_impact_history`. | Provide a valid history baseline after migration. |
| Existing facility quantities | Expanded into individual `facility_instances` grouped by `facility_types`. | Preserve quantity while enabling physical-instance modeling. |
| Existing maintenance → specific facility link | `facility_id` remains `NULL` where Phase 1 could not reliably identify one physical instance. | Avoid inventing unsupported historical detail. |

---

## 15. Traceability from Requirements to Final Implementation

| Requirement | Design / schema artifact | Final implementation |
|---|---|---|
| Advisory vs out-of-service maintenance | `maintenance_records.impact_level` | Booking trigger and stored procedures distinguish the two levels. |
| Advisory acknowledgement | `booking_advisory_acknowledgements` | `usp_get_booking_advisories`, `usp_submit_booking` |
| Maintenance impact history | `maintenance_impact_history` | `usp_change_maintenance_impact` |
| Identify affected bookings after escalation | Impact history + booking/approval history | `usp_change_maintenance_impact`; Analytical Query 4 |
| Automatic approval by space type | `space_type_policies` | `usp_submit_booking` + `usp_approve_booking_core` |
| Staff and automatic decision representation | `approvals.decision_method` | Approval constraints and approval procedures |
| Prevent overlapping concurrent approvals | Per-space transaction protocol | `sp_getapplock` in concurrency implementation |
| Prevent stale same-booking decisions | `booking_requests.version_token` | Staff approve/reject procedures compare expected rowversion |
| Demonstrate unsafe vs safe concurrency | Concurrency design + test scripts | `13-concurrency-tests-G10/` |
| Semester utilization report | Existing + extended booking history | Analytical Query 1 |
| Weekday/hour report | Booking history | Analytical Query 2 |
| Room finder | Spaces, facilities, bookings, maintenance | Analytical Query 3 |
| Escalation affected-bookings report | Maintenance impact history + approvals | Analytical Query 4 |

---

## 16. Requirement-to-Conflict Matrix

| Requirement | Potential inconsistency without control | Control required in final design |
|---|---|---|
| No overlapping approved bookings | Two staff members approve different overlapping requests. | Same per-space lock + conflict recheck. |
| Instant approval | Automatic and staff paths approve overlapping requests independently. | Both paths use the same synchronization protocol. |
| High-volume simultaneous submissions | Two automatically eligible submissions both see the room as free. | Serialize same-space submission/approval critical section. |
| Maintenance escalation | Approval commits while maintenance becomes out-of-service. | Escalation and approval share the per-space lock. |
| One final booking decision | A stale staff screen overwrites a newer decision. | `ROWVERSION` validation and one approval row per booking. |
| Advisory acknowledgement | Advisory set changes between initial lookup and submission. | Recalculate required advisory set while holding the submission lock and validate acknowledgement IDs. |

---

## 17. Final Analysis

The Phase 2 requirements are not only additive schema changes. They fundamentally change the meaning of **space availability** and introduce a concurrency-sensitive approval workflow.

The most important consequences for Group G10 are:

1. Maintenance can no longer be represented as a simple room-level unavailable state. Availability must consider maintenance impact, status, and time overlap.
2. Advisory maintenance requires a many-to-many acknowledgement record between bookings and maintenance records.
3. Escalation history must be preserved so affected already-approved bookings can be found reliably.
4. Automatic approval introduces another writer that must obey the same overlap invariant as staff approval.
5. Ordinary trigger validation is not enough for simultaneous check-then-act operations; the design therefore requires transaction-level same-space synchronization.
6. `ROWVERSION` complements the per-space lock by detecting stale decisions on the same booking.
7. The richer maintenance and facility structure also supports the new room-finder and historical reporting requirements.

These findings form the basis for the updated ERD and logical design in `09-updated-erd-and-logical-design-G10.md`, the migration in `10-schema-migration-G10.sql`, and the concurrency solution implemented and tested in deliverables 11–13.

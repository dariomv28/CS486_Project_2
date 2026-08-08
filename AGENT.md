# AGENT DEFINITION: CAMPUS SPACE MANAGEMENT SYSTEM AGENT

## 1. Role & Mission

You are the AI Agent for **Group G10** in the CS486 – Introduction to Database System project.

Your responsibility is to maintain and extend the **Campus Space Management System** from Phase 1 into Phase 2 using **Microsoft SQL Server**, while preserving valid Phase 1 behavior and implementing the new Phase 2 requirements consistently across the design documents, migration scripts, concurrency logic, generated data, analytical queries, and index-tuning evidence.

The agent must treat the project requirements and the existing G10 implementation as the source of truth. Do not silently redesign working parts of the system unless a Phase 2 requirement requires a change.

---

## 2. Phase 1 Foundation

Phase 2 extends the Phase 1 system. The following Phase 1 concepts remain part of the system unless explicitly refined below.

### 2.1. Users

Each user has a university account. The system stores:

- `user_id`
- full name
- email
- phone number
- role
- department
- account status

Supported roles include:

- student
- lecturer
- teaching assistant
- facility staff
- department administrator
- facility manager

### 2.2. Spaces

The School manages shared spaces such as:

- auditoriums
- classrooms
- computer laboratories
- project laboratories
- meeting rooms
- student workspaces

Each space stores information including:

- `space_code`
- space name
- space type
- building
- floor
- room number
- capacity
- current status
- usage policy

### 2.3. Booking Requests

A booking request includes:

- requester
- space
- requested start time
- requested end time
- purpose of use
- expected number of participants
- booking status

Supported booking statuses include:

- `pending`
- `approved`
- `rejected`
- `cancelled`
- `checked in`
- `completed`
- `no-show`

The central invariant remains:

> The same space must never have two approved bookings with overlapping requested time periods.

### 2.4. Approvals and Usage Sessions

The system records approval/rejection decisions and usage-session information such as check-in, actual start/end time, room condition, and usage notes.

### 2.5. Maintenance

The system keeps maintenance history for space and equipment problems and records the responsible users/staff, time period, status, and result information.

---

# 3. Phase 2 Requirement Changes

## 3.1. Maintenance Impact Levels

Phase 1 treated any maintenance as making a space unavailable. Phase 2 replaces that rule with two impact levels:

| Impact level | Booking behavior |
|---|---|
| `advisory` | The space remains bookable. The requester must be informed of every overlapping active advisory and acknowledgement must be stored. |
| `out-of-service` | The space cannot be booked for a requested interval that overlaps the effective out-of-service interval. |

A space may have multiple open maintenance records at the same time with different impact levels.

The agent must **not** implement availability by simply checking `spaces.current_status = 'under maintenance'`. Availability must be determined from the requested interval and overlapping maintenance impact records.

### Maintenance impact changes

An open maintenance record may be:

- escalated from `advisory` to `out-of-service`; or
- downgraded while still open.

The system must preserve impact-level history.

When an advisory is escalated to out-of-service, already-approved bookings overlapping the effective out-of-service period must be identifiable so staff can contact requesters. These bookings are reported; they are **not automatically cancelled**.

---

## 3.2. Advisory Acknowledgement

Before a booking is submitted, the requester can obtain all active advisory maintenance records overlapping the requested interval.

The submission workflow must ensure that every advisory that exists and overlaps at submission time has been acknowledged.

The G10 implementation uses:

- `dbo.usp_get_booking_advisories`
- `dbo.usp_submit_booking`
- `dbo.booking_advisory_acknowledgements`

Advisory acknowledgement belongs to booking submission time. A new advisory that appears after submission does not retroactively invalidate the acknowledgement. If maintenance later becomes out-of-service, the out-of-service rule applies.

---

## 3.3. Automatic and Staff Approval

Phase 2 allows selected space types to support instant approval when their usage policy is satisfied.

G10 stores this configuration in:

- `dbo.space_type_policies`
- `instant_approval_enabled`

The current migration enables instant approval for the `meeting room` space type. Other types can remain staff-approved unless their policy is changed.

Approval records distinguish:

- `decision_method = 'automatic'`
- `decision_method = 'staff'`

Automatic approval must not have a staff actor. Staff approval must record the responsible staff user.

Most importantly, **automatic approval and staff approval must use the same protected conflict-checking logic** so that concurrency cannot bypass the no-overlap rule.

---

# 4. Phase 2 Data Model Rules

The finalized Phase 2 logical design includes the following important additions/refinements.

## 4.1. `SPACE_TYPE_POLICY`

Stores policy once per `space_type` instead of repeating instant-approval configuration in every space.

Important attributes:

- `space_type` – primary key
- `instant_approval_enabled`
- `policy_description`

## 4.2. Facility Normalization

The Phase 1 facility representation is normalized into:

- `FACILITY_TYPE`
- `FACILITY_INSTANCE`

A facility type describes a category such as projector or air conditioner. A facility instance represents a physical asset in a specific space.

Equipment-specific maintenance should reference the appropriate facility instance when applicable.

## 4.3. `BOOKING_REQUEST.version_token`

Booking requests include a SQL Server `ROWVERSION` column used to detect stale updates to the **same booking row**.

`ROWVERSION` is not sufficient for preventing overlapping approval of different booking rows; the space-level concurrency strategy in Section 5 is also required.

## 4.4. Maintenance History

Phase 2 preserves:

- maintenance assignment history through `MAINTENANCE_ASSIGNMENT`;
- maintenance impact changes through `MAINTENANCE_IMPACT_HISTORY`.

## 4.5. Advisory Acknowledgement

`BOOKING_ADVISORY_ACKNOWLEDGEMENT` records which advisory maintenance records were acknowledged for a booking.

---

# 5. Concurrency Rules

Concurrency correctness is a mandatory Phase 2 requirement.

## 5.1. Conflicts that must be handled

The agent must account for at least the following races:

1. Two overlapping booking requests are approved concurrently.
2. Automatic approval races with staff approval for the same space/time interval.
3. Booking approval races with maintenance escalation to `out-of-service`.
4. Two staff members attempt decisions using different versions of the same booking.

## 5.2. G10 Selected Strategy

The current G10 solution combines:

- SQL Server transactions;
- transaction-owned `sys.sp_getapplock` locks scoped by `space_code`;
- revalidation after acquiring the lock;
- one shared protected approval core for automatic and staff approval;
- `ROWVERSION` for stale same-row decisions.

The application lock serializes business operations that can change availability for the same space.

All operations that participate in this invariant must follow the same locking protocol. A solution that protects only one code path is not sufficient.

## 5.3. Required revalidation

After acquiring the protected space lock, approval/submission logic must recheck relevant state, including:

- current booking status;
- overlapping approved bookings;
- overlapping `out-of-service` maintenance;
- stale `ROWVERSION` when a staff decision is based on a previously read booking version.

Do not rely on a prior availability check performed before the transaction lock was acquired.

## 5.4. Direct DML

Normal application workflows should use the provided stored procedures instead of bypassing concurrency control through direct writes to protected booking/approval state.

---

# 6. Phase 2 Reporting Requirements

The implementation must support all four required reports.

| Query | Required report |
|---|---|
| Query 1 | Total approved booking hours of each space for a given semester. |
| Query 2 | Number of approved bookings by weekday and hour for a given semester. |
| Query 3 | Available spaces satisfying a required capacity and required facility list for a given time period. |
| Query 4 | Approved bookings affected when maintenance is escalated from advisory to out-of-service. |

The G10 implementation stores these reports in:

`16-analytical-queries-G10.sql`

### Room Finder rules

The room finder must consider:

- required capacity;
- required facility types/quantities;
- overlapping approved bookings;
- overlapping active `out-of-service` maintenance;
- availability of the individual facility instances being counted.

An advisory maintenance record alone must not remove an otherwise usable room from the result.

---

# 7. Sample Data Generation Rules

Phase 2 data generation must contain:

- at least **three academic years**;
- at least **100,000 booking records**;
- maintenance data;
- cancellations;
- no-show bookings;
- advisory acknowledgements;
- automatic and staff approval cases.

The current G10 generator defaults to 100,000 deterministic booking rows and contains cases for maintenance escalation and the affected-booking report.

Generated data must preserve business invariants, especially:

- no unintended overlapping approved bookings;
- no normal approved booking overlapping an out-of-service maintenance interval;
- intentional advisory-to-out-of-service escalation cases may produce affected approved bookings for Query 4.

---

# 8. Indexing and Query-Tuning Rules

Phase 2 requires tuning and before/after comparison for:

1. booking conflict check;
2. room finder;
3. two reporting queries other than the room finder.

G10 benchmarks:

- booking conflict check;
- room finder (Query 3);
- Analytical Query 1;
- Analytical Query 2.

Current tuning indexes include support for:

- booking conflict lookups by space/status/time;
- booking reporting by status/time;
- room-level out-of-service maintenance overlap;
- facility lookup by space/type/status;
- facility-specific maintenance availability.

Performance work must be evidence-based. Compare the same workload before and after indexes using SQL Server statistics and execution plans where available. Do not invent plan operators or timing values.

---

# 9. Normalization Validation

The Phase 2 relational schema must satisfy at least **Third Normal Form (3NF)**.

For every relation, the agent must be able to identify relevant functional dependencies and verify that non-key attributes depend on a key, the whole key, and not transitively on another non-key attribute.

Important normalization decisions in G10 include:

- separating `SPACE_TYPE_POLICY` from `SPACE`;
- separating `FACILITY_TYPE` from `FACILITY_INSTANCE`;
- preserving maintenance assignment history rather than storing only one current assignee;
- preserving maintenance impact history separately from the current maintenance record;
- representing booking/advisory acknowledgement as a relationship table.

Normalization validation must remain consistent with the keys and constraints implemented by the SQL schema.

---

# 10. Required Deliverables

Phase 1 deliverables remain part of the repository:

1. `outputs/01-business-req-analysis-G10.md`
2. `outputs/02-erd-design-G10.md`
3. `outputs/03-logical-design-G10.md`
4. `outputs/04-design-validation-G10.md`
5. `outputs/05-db-definition-G10.sql`
6. `outputs/06-sample-data-G10.sql`
7. `outputs/07-query-design-G10.sql`

Phase 2 adds/updates:

8. `outputs/08-requirement-change-analysis-G10.md`
9. `outputs/09-updated-erd-and-logical-design-G10.md`
10. `outputs/10-schema-migration-G10.sql`
11. `outputs/11-concurrency-design-G10.md`
12. `outputs/12-concurrency-implementation-G10.sql`
13. `outputs/13-concurrency-tests-G10/`
14. `outputs/14-data-generator-G10/`
15. `outputs/15-index-tuning-report-G10.md`
16. `outputs/16-analytical-queries-G10.sql`

The repository may also contain supporting benchmark scripts such as `15-index-tuning-G10/`; these support the required report but do not replace `15-index-tuning-report-G10.md`.

---

# 11. Cross-Deliverable Consistency Rules

Whenever one deliverable is changed, check whether the same rule appears elsewhere.

At minimum, keep these artifacts synchronized:

| Change | Files that may need review |
|---|---|
| Entity/attribute/key change | 08, 09, 10, 12, 14, 16 |
| Approval rule change | 08, 09, 10, 11, 12, 13, 14 |
| Maintenance rule change | 08, 09, 10, 11, 12, 13, 14, 16 |
| Concurrency strategy change | 11, 12, 13 |
| Generated-data assumption change | 14, 15, 16 |
| Query definition change | 15 benchmark/report and 16 analytical queries |
| Index change | 15 benchmark scripts and 15 report |
| Normalization/key change | 09 and 10 |

Do not fix one file in isolation if doing so makes another deliverable inconsistent.

---

# 12. Agent Quality and Improvement Process

Phase 2 improves the Phase 1 agent from a static database-design agent into an agent that can reason about **schema evolution, concurrency, large-data testing, analytical reporting, performance tuning, and normalization**.

The improvement process should follow this loop:

1. **Requirement traceability** – map each Phase 2 requirement to affected schema objects, procedures, tests, and reports.
2. **Implementation consistency check** – compare design documents with actual SQL behavior.
3. **Adversarial testing** – test race conditions and exceptional maintenance/booking cases, not only normal single-session behavior.
4. **Data-scale validation** – verify requirements on a generated dataset of at least 100,000 bookings across three academic years.
5. **Performance evaluation** – compare before/after reads, CPU/elapsed time, and execution plans for the same benchmark queries.
6. **Normalization validation** – verify functional dependencies and at least 3NF after schema changes.
7. **Refinement** – when a test exposes an inconsistency, update all affected deliverables rather than patching only the test output.

The agent must clearly distinguish:

- a requirement from the assignment;
- a G10 design decision;
- an observed test/benchmark result;
- an assumption that still requires evidence.

Never fabricate benchmark results, execution-plan details, concurrency outcomes, or data counts.

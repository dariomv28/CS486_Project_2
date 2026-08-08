# SKILL DEFINITION: DATABASE DESIGN, CONCURRENCY, ANALYTICS, AND SQL SERVER TUNING

This file defines the skills the Group G10 agent must use to complete and maintain the **Campus Space Management System** through both Phase 1 and Phase 2.

The target DBMS is **Microsoft SQL Server**.

---

# 1. Requirement Analysis Skills

## 1.1. Business Requirement Analysis

The agent must be able to extract and document:

- actors;
- entities;
- attributes;
- relationships;
- cardinalities;
- participation constraints;
- business rules;
- exceptional cases;
- temporal rules.

The agent must distinguish between requirements explicitly stated by the project and implementation decisions introduced by G10.

## 1.2. Requirement Change Analysis

For Phase 2, the agent must be able to compare the new requirements against the Phase 1 design and identify:

- affected entities and relations;
- new attributes/tables;
- changed business rules;
- removed or refined assumptions;
- migration consequences;
- concurrency risks;
- reporting consequences;
- performance consequences.

Important Phase 2 changes include:

- `advisory` vs `out-of-service` maintenance;
- advisory acknowledgement;
- automatic approval for selected space types;
- concurrent booking/approval;
- maintenance impact escalation/downgrade;
- large historical reporting;
- indexing and query tuning;
- 3NF validation.

---

# 2. Conceptual and Logical Database Design Skills

## 2.1. ERD Design

The agent must be able to design or update an ERD with:

- entities;
- attributes;
- primary/candidate keys;
- relationships;
- cardinalities;
- optional/mandatory participation.

The ERD must reflect the actual Phase 2 SQL schema rather than an idealized schema that is not implemented.

## 2.2. Relational Mapping

The agent must correctly convert the ERD into relations with:

- primary keys;
- candidate/unique keys;
- foreign keys;
- composite keys;
- nullable vs mandatory attributes;
- referential actions where appropriate.

## 2.3. Phase 2 Modeling Skills

The agent must understand and preserve the G10 modeling choices for:

- `SPACE_TYPE_POLICY`;
- `FACILITY_TYPE`;
- `FACILITY_INSTANCE`;
- `BOOKING_REQUEST.version_token`;
- `MAINTENANCE_ASSIGNMENT`;
- `MAINTENANCE_IMPACT_HISTORY`;
- `BOOKING_ADVISORY_ACKNOWLEDGEMENT`;
- automatic/staff approval method.

The agent must understand why facility type and facility instance are separate concepts and why assignment/impact history should not be overwritten in the parent maintenance row.

---

# 3. Normalization Skills

The agent must be able to identify functional dependencies for each relation and evaluate normal forms.

For 3NF validation, the agent must:

1. identify candidate keys;
2. identify functional dependencies supported by the business rules/schema;
3. verify first normal form;
4. verify no partial dependency on part of a composite key;
5. verify no transitive dependency of non-key attributes on other non-key attributes;
6. document any decomposition used to remove redundancy/anomalies.

Important G10 normalization examples include:

- `SPACE_TYPE_POLICY` separated from `SPACE`;
- `FACILITY_TYPE` separated from `FACILITY_INSTANCE`;
- maintenance assignments stored as history rows;
- maintenance impact changes stored as history rows;
- advisory acknowledgement represented by the booking-maintenance relationship.

Do not claim a relation is in 3NF without identifying the dependency/key reasoning that supports the claim.

---

# 4. SQL DDL and Schema Migration Skills

## 4.1. SQL Server DDL

The agent must be able to write and review:

- `CREATE TABLE`;
- `ALTER TABLE`;
- primary keys;
- foreign keys;
- `UNIQUE` constraints;
- `CHECK` constraints;
- `DEFAULT` constraints;
- indexes;
- SQL Server `ROWVERSION` columns.

## 4.2. Safe Phase 1 → Phase 2 Migration

The migration must be applied on top of the Phase 1 database and should preserve existing data whenever practical.

The agent must be able to:

- create new Phase 2 tables;
- copy/transform Phase 1 facility data into normalized tables;
- add new columns without invalidating existing rows;
- seed default policy rows;
- classify legacy maintenance consistently with the documented migration rule;
- migrate approval information to support decision methods;
- add indexes/constraints only after data is compatible;
- document any deliberate transformation or information loss.

Migration scripts should be rerunnable or defensively check for already-created objects where the project implementation follows that pattern.

---

# 5. Stored Procedure and Transaction Skills

The agent must be able to design, review, and test SQL Server stored procedures that preserve business invariants under concurrency.

Important G10 procedures include:

- `dbo.usp_get_booking_advisories`
- `dbo.usp_submit_booking`
- `dbo.usp_approve_booking_core`
- `dbo.usp_approve_booking`
- `dbo.usp_reject_booking`
- `dbo.usp_change_maintenance_impact`
- `dbo.usp_create_maintenance_record`
- `dbo.usp_change_space_status`
- `dbo.usp_get_booking_for_decision`
- `dbo.usp_verify_no_overlapping_approved_bookings`

The agent must understand transaction boundaries, error handling, rollback behavior, and revalidation after locks are obtained.

---

# 6. Concurrency Analysis Skills

## 6.1. Race-Condition Identification

The agent must be able to explain race conditions as interleavings rather than merely saying that “two users run at the same time.”

Required examples include:

- two sessions both check that a space is free, then both approve overlapping bookings;
- automatic approval racing with staff approval;
- booking approval racing with maintenance escalation;
- two staff decisions using stale versions of the same booking.

## 6.2. Locking Strategy Evaluation

The agent must understand the limitations and trade-offs of approaches considered by G10, including:

- `ROWVERSION` alone;
- trigger-only validation;
- `SERIALIZABLE` isolation;
- SQL Server application locks.

It must understand that `ROWVERSION` protects stale writes to the same row but does not by itself serialize different overlapping booking rows.

## 6.3. `sp_getapplock`

The selected G10 design uses transaction-owned application locks by `space_code`.

The agent must know how to:

- acquire an application lock inside a transaction;
- check the return code;
- use a deterministic resource name;
- hold the lock through validation and write operations;
- ensure competing approval/maintenance paths use the same protocol;
- release the lock through transaction completion.

## 6.4. Revalidation

After a protected lock is obtained, the agent must recheck state that may have changed, including:

- booking status;
- approved overlap;
- out-of-service maintenance overlap;
- expected `ROWVERSION` for staff decisions.

A check made before acquiring the lock is not sufficient evidence of correctness.

## 6.5. Deadlock Awareness

When an operation needs multiple resources, the agent must use a consistent lock acquisition order and keep transactions as short as practical.

---

# 7. Maintenance-Impact Skills

The agent must correctly distinguish:

### Advisory maintenance

- does not block room booking by itself;
- must be shown to the requester when it overlaps the requested interval;
- must be acknowledged at submission time.

### Out-of-service maintenance

- blocks a booking whose requested interval overlaps the effective out-of-service period.

### Escalation

For advisory → out-of-service changes, the agent must:

- preserve impact history;
- serialize the operation with competing approval operations for the same space;
- identify affected already-approved bookings;
- avoid incorrectly treating the entire pre-escalation advisory interval as out-of-service;
- avoid automatically cancelling existing bookings unless a requirement explicitly says to do so.

---

# 8. Automatic Approval Skills

The agent must understand the policy-driven approval model.

It must be able to:

- read `space_type_policies.instant_approval_enabled`;
- determine whether the request satisfies the usage policy implemented by the project;
- send eligible requests through automatic approval;
- leave other requests in the staff workflow;
- record `decision_method` correctly;
- enforce that automatic approval has no staff actor;
- use exactly the same protected overlap logic as staff approval.

Automatic approval is not a shortcut around the concurrency rules.

---

# 9. Test Design Skills

## 9.1. Multi-Session Concurrency Tests

The agent must be able to produce reproducible two-session SQL Server tests using controlled delays and transactions.

Tests should demonstrate both:

1. the unsafe race condition; and
2. the behavior after concurrency control is applied.

The current G10 test suite includes cases for:

- unsafe overlapping approval;
- safe approval using the protected lock;
- automatic approval;
- automatic vs staff approval;
- approval vs maintenance escalation in both commit orders;
- stale `ROWVERSION` decisions.

## 9.2. Evidence Quality

A concurrency test must show enough output to prove the result, for example:

- booking IDs;
- space code;
- requested interval;
- final booking status;
- approval method;
- maintenance impact/status;
- version token before/after;
- explicit PASS/FAIL verification.

Do not infer success only because a script completed without an exception.

---

# 10. Large Data Generation Skills

The agent must be able to generate realistic relational test data satisfying Phase 2 requirements.

Minimum requirements:

- at least three academic years;
- at least 100,000 bookings;
- maintenance;
- cancellations;
- no-shows;
- advisory acknowledgements.

The generated dataset should also exercise the implemented G10 features, including automatic/staff approvals and maintenance escalation cases.

The agent must preserve referential integrity and business invariants while generating data.

## 10.1. Deterministic Generation

A fixed random seed should be used when reproducible benchmarking is required.

## 10.2. Bulk Loading

The agent must understand:

- CSV generation;
- SQL Server bulk import/load scripts;
- load order based on foreign-key dependencies;
- trigger/session-context interactions when applicable;
- safe cleanup/reload of generated benchmark data;
- statistics refresh after bulk loading.

## 10.3. Dataset Verification

After load, verify at least:

- booking count;
- academic-year coverage;
- cancellation count;
- no-show count;
- maintenance count;
- advisory acknowledgement count;
- presence of automatic and staff approvals;
- zero unintended approved-booking overlap pairs;
- zero unintended out-of-service overlap pairs;
- non-zero intentional escalation-affected pairs when Query 4 test data is generated.

---

# 11. Analytical SQL Skills

The agent must be able to write and explain all four required Phase 2 analytical queries.

## 11.1. Query 1 – Approved Booking Hours

Compute total approved/effective booking hours by space within the requested semester interval while handling interval boundaries correctly.

## 11.2. Query 2 – Approved Bookings by Weekday and Hour

Aggregate approved bookings by weekday/hour for a semester using a clearly documented interpretation of hourly distribution.

## 11.3. Query 3 – Room Finder

Find spaces satisfying:

- capacity;
- required facility list;
- no conflicting approved booking;
- no overlapping active out-of-service maintenance;
- required physical facility instances are themselves usable for the interval.

Do not exclude a room solely because `current_status` says `under maintenance` when the relevant overlapping maintenance is only advisory.

## 11.4. Query 4 – Bookings Affected by Escalation

Identify approved bookings affected by advisory → out-of-service maintenance changes using maintenance impact history and the effective out-of-service interval.

The query must distinguish the advisory period before escalation from the period during which the maintenance was actually out-of-service.

---

# 12. Index Design Skills

The agent must be able to derive indexes from actual predicates, joins, ordering, grouping, and projection columns rather than creating generic indexes on every foreign key.

Important concepts include:

- equality columns before useful range columns;
- covering indexes with `INCLUDE`;
- filtered indexes where appropriate;
- avoiding excessive/wide indexes;
- considering write overhead;
- distinguishing structural constraint indexes from workload-tuning indexes.

The current G10 tuning work covers:

- booking conflict lookup;
- reporting on booking status/time;
- room-level maintenance overlap;
- facility lookup;
- facility-specific maintenance overlap.

---

# 13. SQL Server Performance Measurement Skills

The agent must be able to compare query performance before and after indexing using the **same data and same logical workload**.

Relevant evidence includes:

- `SET STATISTICS IO ON`;
- `SET STATISTICS TIME ON`;
- Actual Execution Plan;
- scan count;
- logical reads;
- CPU time;
- elapsed time;
- access method/operator changes where an actual plan is available.

The agent must understand that elapsed time can fluctuate because of caching, machine load, compilation, and parallelism. Logical reads and plan changes should therefore be interpreted together with timing.

Never invent an execution-plan operator when the plan was not captured.

---

# 14. Reporting and Documentation Skills

The agent must present technical evidence clearly.

For benchmark results, prefer tables such as:

| Metric | Before | After | Change |
|---|---:|---:|---:|
| Logical reads | ... | ... | ... |
| CPU time | ... | ... | ... |
| Elapsed time | ... | ... | ... |

For requirement/change analysis, use traceability tables showing:

- requirement;
- affected entity/object;
- required change;
- implemented artifact.

For concurrency reports, describe the interleaving and then show the observed result.

Documentation must remain concise enough to review but detailed enough that another student can reproduce the result.

---

# 15. Cross-Artifact Validation Skills

The agent must compare deliverables against each other instead of reviewing each file independently.

Examples:

- an entity added in `09` must exist in `10`;
- a concurrency protocol described in `11` must be implemented in `12` and exercised in `13`;
- assumptions made by the data generator in `14` must match the schema/procedures in `10`/`12`;
- analytical queries in `16` must match the benchmarks and index reasoning in `15`;
- normalization claims in `09` must match actual keys and dependencies in `10`.

When inconsistencies are found, identify which artifact is authoritative and update all dependent artifacts.

---

# 16. Agent Improvement Capability

Compared with Phase 1, the Phase 2 agent must additionally be able to:

- reason about requirement changes instead of designing only from a static specification;
- migrate an existing schema while preserving data;
- model historical changes;
- reason about transaction interleavings and race conditions;
- implement pessimistic coordination with application locks;
- use optimistic `ROWVERSION` checks for stale writes;
- create and run multi-session concurrency tests;
- generate large deterministic datasets;
- implement analytical reporting over historical data;
- design workload-specific indexes;
- evaluate before/after performance evidence;
- validate functional dependencies and 3NF;
- maintain consistency across all project deliverables.

The agent should refine its work using evidence from schema validation, concurrency tests, generated-data verification, and performance benchmarks rather than relying only on static reasoning.

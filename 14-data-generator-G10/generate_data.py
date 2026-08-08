#!/usr/bin/env python3
"""Deterministic Phase 2 data generator for CS486 Group G10.

Target schema:
  05-db-definition-G10.sql
  06-sample-data-G10.sql
  10-schema-migration-G10.sql
  12-concurrency-implementation-G10.sql

The generator writes CSV files into ./generated. It does not connect to SQL Server.
Use load_generated_data.sql to load the CSVs.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import random
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

SEED = 48610
DEFAULT_BOOKINGS = 100_000
BOOKING_ID_START = 1_000_000
MAINTENANCE_ID_START = 1_000_000
FACILITY_ID_START = 1_000_000
AUTO_APPROVAL_RATE = 0.60

ACADEMIC_START = datetime(2022, 9, 1, 0, 0, 0)
ACADEMIC_END = datetime(2025, 8, 31, 23, 59, 59)

PURPOSES = [
    "lecture",
    "examination",
    "seminar",
    "workshop",
    "meeting",
    "student activity",
    "administrative event",
]

SPACE_TYPES = [
    "auditorium",
    "classroom",
    "computer laboratory",
    "project laboratory",
    "meeting room",
    "student workspace",
]

FACILITY_TYPES = [
    "Projector",
    "Whiteboard",
    "Microphone",
    "Computer",
    "Air conditioner",
    "Livestreaming equipment",
    "TV screen",
]

PROBLEM_TYPES = [
    "broken projector",
    "air-conditioning failure",
    "damaged furniture",
    "cleaning issue",
    "network problem",
    "other",
]

# Equipment-specific maintenance problems must reference a matching
# facility instance when that problem is generated. Room-level problems
# intentionally leave facility_id NULL.
PROBLEM_FACILITY_TYPE = {
    "broken projector": "Projector",
    "air-conditioning failure": "Air conditioner",
}

# Exact distribution for the default 100,000 rows. For other sizes, the same
# percentages are applied and rounding is corrected on the final status.
STATUS_WEIGHTS = [
    ("approved", 0.15),
    ("completed", 0.40),
    ("cancelled", 0.15),
    ("rejected", 0.10),
    ("no-show", 0.05),
    ("pending", 0.15),
]

APPROVED_LIFECYCLE_STATUSES = {"approved", "completed", "no-show", "checked in"}


@dataclass(frozen=True)
class Space:
    code: str
    space_type: str
    capacity: int


@dataclass
class Booking:
    booking_id: int
    requester_id: str
    space_code: str
    start: datetime
    end: datetime
    purpose: str
    participants: int
    final_status: str
    created_at: datetime


@dataclass
class Maintenance:
    maintenance_id: int
    space_code: str
    reporter_id: str
    facility_id: Optional[int]
    problem_type: str
    description: str
    start: datetime
    completion: Optional[datetime]
    status: str
    result_note: Optional[str]
    initial_impact: str
    final_impact: str
    escalated_at: Optional[datetime] = None


def iso(dt: Optional[datetime]) -> str:
    return "" if dt is None else dt.strftime("%Y-%m-%dT%H:%M:%S")


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def write_csv(path: Path, fieldnames: Sequence[str], rows: Iterable[dict]) -> int:
    count = 0
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
            count += 1
    return count


def distribute_statuses(total: int) -> List[str]:
    counts: Dict[str, int] = {}
    assigned = 0
    for status, weight in STATUS_WEIGHTS[:-1]:
        n = int(total * weight)
        counts[status] = n
        assigned += n
    last_status = STATUS_WEIGHTS[-1][0]
    counts[last_status] = total - assigned

    statuses: List[str] = []
    for status, _ in STATUS_WEIGHTS:
        statuses.extend([status] * counts[status])
    random.shuffle(statuses)
    return statuses


def generate_users() -> Tuple[List[dict], List[str], List[str]]:
    rows: List[dict] = []
    requester_ids: List[str] = []
    staff_ids: List[str] = []

    specs = [
        ("student", 400, "DGU"),
        ("lecturer", 35, "DGL"),
        ("teaching assistant", 25, "DGTA"),
        ("department administrator", 10, "DGDA"),
        ("facility staff", 25, "DGFS"),
        ("facility manager", 5, "DGFM"),
    ]

    serial = 1
    for role, count, prefix in specs:
        for i in range(1, count + 1):
            user_id = f"{prefix}{i:04d}"
            full_name = f"Generated User {serial:04d}"
            email = f"generated.user{serial:04d}@hcmus.edu.vn"
            phone = f"09{70000000 + serial:08d}"[-10:]
            department = "Facility Office" if role in {"facility staff", "facility manager"} else "Computer Science"
            rows.append(
                {
                    "user_id": user_id,
                    "full_name": full_name,
                    "email": email,
                    "phone_number": phone,
                    "role": role,
                    "department": department,
                    "account_status": "active",
                }
            )
            if role not in {"facility staff", "facility manager"}:
                requester_ids.append(user_id)
            if role in {"facility staff", "facility manager"}:
                staff_ids.append(user_id)
            serial += 1

    return rows, requester_ids, staff_ids


def generate_spaces(count: int = 60) -> Tuple[List[dict], List[Space]]:
    rows: List[dict] = []
    spaces: List[Space] = []

    capacity_ranges = {
        "auditorium": (120, 300),
        "classroom": (35, 90),
        "computer laboratory": (30, 60),
        "project laboratory": (15, 40),
        "meeting room": (8, 30),
        "student workspace": (20, 60),
    }

    for i in range(1, count + 1):
        stype = SPACE_TYPES[(i - 1) % len(SPACE_TYPES)]
        lo, hi = capacity_ranges[stype]
        capacity = random.randrange(lo, hi + 1, 5)
        code = f"DG{i:03d}"
        building_letter = chr(ord("H") + ((i - 1) // 15))
        floor = str(((i - 1) % 5) + 1)
        room = f"{100 + i:03d}"
        rows.append(
            {
                "space_code": code,
                "space_name": f"Generated {stype.title()} {code}",
                "space_type": stype,
                "building": f"Generated Building {building_letter}",
                "floor": floor,
                "room_number": room,
                "capacity": capacity,
                "current_status": "available",
                "usage_policy": "Generated Phase 2 benchmark space. Standard academic-use policy applies.",
            }
        )
        spaces.append(Space(code=code, space_type=stype, capacity=capacity))

    return rows, spaces


def facilities_for_space(space_type: str) -> List[str]:
    required = {
        "auditorium": ["Projector", "Microphone", "Livestreaming equipment", "Air conditioner"],
        "classroom": ["Projector", "Whiteboard", "Air conditioner"],
        "computer laboratory": ["Computer", "Projector", "Air conditioner"],
        "project laboratory": ["Computer", "Whiteboard", "Air conditioner"],
        "meeting room": ["TV screen", "Whiteboard", "Air conditioner"],
        "student workspace": ["Whiteboard", "Air conditioner"],
    }[space_type][:]

    extras = [f for f in FACILITY_TYPES if f not in required]
    random.shuffle(extras)
    extra_count = random.randint(0, 2)
    return required + extras[:extra_count]


def generate_facility_instances(
    spaces: Sequence[Space],
) -> Tuple[List[dict], Dict[str, Dict[str, List[int]]]]:
    rows: List[dict] = []
    by_space_and_type: Dict[str, Dict[str, List[int]]] = defaultdict(lambda: defaultdict(list))
    next_id = FACILITY_ID_START

    for space in spaces:
        for facility_name in facilities_for_space(space.space_type):
            quantity = 1
            if facility_name == "Computer" and space.space_type in {"computer laboratory", "project laboratory"}:
                quantity = random.randint(8, 16)
            elif facility_name == "Microphone" and space.space_type == "auditorium":
                quantity = random.randint(2, 5)

            for unit in range(1, quantity + 1):
                fid = next_id
                next_id += 1
                by_space_and_type[space.code][facility_name].append(fid)
                installed = datetime(2021, 1, 1) + timedelta(days=random.randint(0, 900))
                rows.append(
                    {
                        "facility_id": fid,
                        "facility_type_name": facility_name,
                        "space_code": space.code,
                        "asset_tag": f"DG-{space.code}-{fid}",
                        "instance_status": "available",
                        "condition_note": "Generated benchmark asset in serviceable condition.",
                        "installed_at": iso(installed),
                    }
                )

    return rows, by_space_and_type


def random_date_between(start: datetime, end: datetime) -> datetime:
    span_days = (end.date() - start.date()).days
    day = start.date() + timedelta(days=random.randint(0, span_days))
    return datetime.combine(day, datetime.min.time())


def choose_purpose(space_type: str) -> str:
    preferred = {
        "auditorium": ["seminar", "workshop", "administrative event", "examination"],
        "classroom": ["lecture", "examination", "seminar"],
        "computer laboratory": ["lecture", "examination", "student activity"],
        "project laboratory": ["student activity", "workshop", "meeting"],
        "meeting room": ["meeting", "seminar", "administrative event"],
        "student workspace": ["student activity", "meeting", "workshop"],
    }
    if random.random() < 0.85:
        return random.choice(preferred[space_type])
    return random.choice(PURPOSES)


def generate_bookings(
    total: int,
    spaces: Sequence[Space],
    requester_ids: Sequence[str],
) -> List[Booking]:
    statuses = distribute_statuses(total)
    space_map = {s.code: s for s in spaces}
    space_codes = [s.code for s in spaces]

    # Tracks one-hour blocks used by approval-derived bookings. All such
    # bookings are hour-aligned and occupy a unique set of blocks per room.
    occupied_approved: set[Tuple[str, str, int]] = set()
    bookings: List[Booking] = []

    for idx, status in enumerate(statuses):
        booking_id = BOOKING_ID_START + idx
        is_approved_lifecycle = status in APPROVED_LIFECYCLE_STATUSES

        if is_approved_lifecycle:
            # Rejection sampling is cheap because only ~8% of all possible room-hour
            # blocks are occupied at 100k rows / 60 rooms / three academic years.
            for _ in range(10_000):
                code = random.choice(space_codes)
                space = space_map[code]
                base = random_date_between(ACADEMIC_START, ACADEMIC_END)
                duration_hours = random.choices([1, 2, 3], weights=[0.60, 0.30, 0.10], k=1)[0]
                latest_start = 18 - duration_hours
                hour = random.randint(8, latest_start)
                keys = [(code, base.strftime("%Y-%m-%d"), h) for h in range(hour, hour + duration_hours)]
                if any(k in occupied_approved for k in keys):
                    continue
                occupied_approved.update(keys)
                start = base + timedelta(hours=hour)
                end = start + timedelta(hours=duration_hours)
                break
            else:
                raise RuntimeError("Could not allocate a non-overlapping approved booking slot.")
        else:
            code = random.choice(space_codes)
            space = space_map[code]
            base = random_date_between(ACADEMIC_START, ACADEMIC_END)
            half_hour = random.choice([0, 30])
            hour = random.randint(8, 16)
            duration_minutes = random.choices([60, 90, 120], weights=[0.55, 0.20, 0.25], k=1)[0]
            start = base + timedelta(hours=hour, minutes=half_hour)
            end = start + timedelta(minutes=duration_minutes)
            if end.hour > 18 or (end.hour == 18 and end.minute > 0):
                end = base + timedelta(hours=18)
                if end <= start:
                    start = base + timedelta(hours=16)
                    end = base + timedelta(hours=18)

        created_days_before = random.randint(2, 60)
        created_minutes = random.randint(0, 10 * 60)
        created_at = start - timedelta(days=created_days_before, minutes=created_minutes)
        participants = random.randint(max(1, int(space.capacity * 0.15)), space.capacity)
        purpose = choose_purpose(space.space_type)
        requester = random.choice(requester_ids)

        bookings.append(
            Booking(
                booking_id=booking_id,
                requester_id=requester,
                space_code=code,
                start=start,
                end=end,
                purpose=purpose,
                participants=participants,
                final_status=status,
                created_at=created_at,
            )
        )

    return bookings


def generate_approvals(
    bookings: Sequence[Booking],
    staff_ids: Sequence[str],
    spaces: Sequence[Space],
) -> List[dict]:
    rows: List[dict] = []
    space_type_by_code = {s.code: s.space_type for s in spaces}

    for b in bookings:
        if b.final_status not in {"approved", "completed", "no-show", "rejected"}:
            continue

        decision = "rejected" if b.final_status == "rejected" else "approved"
        is_automatic = (
            decision == "approved"
            and space_type_by_code[b.space_code] == "meeting room"
            and random.random() < AUTO_APPROVAL_RATE
        )

        if is_automatic:
            # Mirrors Phase 2: only a space type with instant approval enabled
            # can receive an automatic approval, and automatic rows have no staff actor.
            decision_time = b.created_at
            staff_id = ""
            note = "Automatically approved at submission time; generated usage policy satisfied."
            reason = ""
            method = "automatic"
        else:
            max_delay = max(1, int((b.start - b.created_at).total_seconds() // 3600) - 1)
            delay_hours = random.randint(1, min(max_delay, 72))
            decision_time = b.created_at + timedelta(hours=delay_hours)
            if decision_time >= b.start:
                decision_time = b.start - timedelta(hours=1)

            staff_id = random.choice(staff_ids)
            method = "staff"
            if decision == "approved":
                note = "Generated staff approval: room, capacity, and policy checks passed."
                reason = ""
            else:
                note = "Generated staff review rejected this request."
                reason = random.choice(
                    [
                        "Requested setup is not supported.",
                        "Purpose does not satisfy the space policy.",
                        "Requested operational support is unavailable.",
                    ]
                )

        rows.append(
            {
                "booking_id": b.booking_id,
                "staff_id": staff_id,
                "decision": decision,
                "decision_time": iso(decision_time),
                "decision_note": note,
                "rejection_reason": reason,
                "decision_method": method,
            }
        )
    return rows


def generate_usage_sessions(bookings: Sequence[Booking], staff_ids: Sequence[str]) -> List[dict]:
    rows: List[dict] = []
    for b in bookings:
        if b.final_status != "completed":
            continue
        actual_start = b.start + timedelta(minutes=random.randint(-10, 10))
        actual_end = b.end + timedelta(minutes=random.randint(-5, 15))
        if actual_end <= actual_start:
            actual_end = actual_start + timedelta(minutes=30)
        rows.append(
            {
                "booking_id": b.booking_id,
                "actual_start_time": iso(actual_start),
                "checked_in_by": random.choice(staff_ids),
                "initial_condition": "Generated check-in: room ready for use.",
                "actual_end_time": iso(actual_end),
                "final_condition": "Generated completion: room returned in acceptable condition.",
                "usage_notes": "Generated completed usage session.",
            }
        )
    return rows


def intervals_overlap(a_start: datetime, a_end: datetime, b_start: datetime, b_end: datetime) -> bool:
    return a_start < b_end and a_end > b_start


def generate_maintenance(
    bookings: Sequence[Booking],
    spaces: Sequence[Space],
    requester_ids: Sequence[str],
    staff_ids: Sequence[str],
    facility_ids_by_space_and_type: Dict[str, Dict[str, List[int]]],
) -> Tuple[List[Maintenance], List[dict], List[dict], List[dict]]:
    """Return maintenance, assignments, escalation rows, and acknowledgements.

    Mix:
      - 500 advisory windows centered on existing bookings.
      - 100 advisory->out-of-service escalations centered on approved lifecycle bookings.
      - 500 completed/cancelled out-of-service maintenance windows outside booking hours.
      - 100 open advisory records late in the third academic year.
    """

    by_space: Dict[str, List[Booking]] = defaultdict(list)
    for b in bookings:
        by_space[b.space_code].append(b)
    for arr in by_space.values():
        arr.sort(key=lambda x: x.start)

    space_codes = [s.code for s in spaces]
    maintenance: List[Maintenance] = []
    next_mid = MAINTENANCE_ID_START

    def choose_reporter() -> str:
        # Mostly ordinary users, sometimes facility staff.
        return random.choice(requester_ids if random.random() < 0.8 else staff_ids)

    def choose_problem_and_facility(code: str) -> Tuple[str, Optional[int]]:
        facilities = facility_ids_by_space_and_type.get(code, {})

        # Only generate an equipment-specific problem when the room actually
        # has that equipment type. If selected, facility_id always references
        # an instance of the matching type. Room-level problems use NULL.
        possible_problems = ["damaged furniture", "cleaning issue", "network problem", "other"]
        for problem, facility_type in PROBLEM_FACILITY_TYPE.items():
            if facilities.get(facility_type):
                possible_problems.append(problem)

        problem = random.choice(possible_problems)
        facility_type = PROBLEM_FACILITY_TYPE.get(problem)
        if facility_type is None:
            return problem, None

        return problem, random.choice(facilities[facility_type])

    # 1) Advisory maintenance intentionally overlapping normal booking windows.
    targeted = random.sample(list(bookings), 500)
    for b in targeted:
        start = b.start - timedelta(minutes=30)
        completion = b.end + timedelta(minutes=30)
        problem_type, facility_id = choose_problem_and_facility(b.space_code)
        maintenance.append(
            Maintenance(
                maintenance_id=next_mid,
                space_code=b.space_code,
                reporter_id=choose_reporter(),
                facility_id=facility_id,
                problem_type=problem_type,
                description="Generated advisory: partial equipment/comfort issue; space remained usable.",
                start=start,
                completion=completion,
                status="completed",
                result_note="Advisory issue resolved after inspection or repair.",
                initial_impact="advisory",
                final_impact="advisory",
            )
        )
        next_mid += 1

    # 2) Escalation cases. These deliberately overlap already-approved bookings so
    # the Phase 2 affected-bookings report has meaningful rows.
    approved_candidates = [b for b in bookings if b.final_status in APPROVED_LIFECYCLE_STATUSES]
    escalated_targets = random.sample(approved_candidates, 100)
    escalations: List[dict] = []
    escalation_actor = staff_ids[0]
    for b in escalated_targets:
        start = b.start - timedelta(minutes=20)
        completion = b.end + timedelta(minutes=40)
        escalated_at = b.start - timedelta(minutes=5)
        problem_type, facility_id = choose_problem_and_facility(b.space_code)
        maintenance.append(
            Maintenance(
                maintenance_id=next_mid,
                space_code=b.space_code,
                reporter_id=choose_reporter(),
                facility_id=facility_id,
                problem_type=problem_type,
                description="Generated escalation case: advisory later became out-of-service.",
                start=start,
                completion=completion,
                status="completed",
                result_note="Escalated issue resolved; room returned to service.",
                initial_impact="advisory",
                final_impact="out-of-service",
                escalated_at=escalated_at,
            )
        )
        escalations.append(
            {
                "maintenance_id": next_mid,
                "changed_by": escalation_actor,
                "escalated_at": iso(escalated_at),
                "new_impact_level": "out-of-service",
                "change_reason": "Generated benchmark escalation from advisory to out-of-service.",
            }
        )
        next_mid += 1

    # 3) Out-of-service maintenance outside normal booking hours, so it cannot
    # collide with the generated booking workload.
    for _ in range(500):
        code = random.choice(space_codes)
        day = random_date_between(ACADEMIC_START, ACADEMIC_END)
        start = day + timedelta(hours=19)
        duration_hours = random.choice([2, 3, 4])
        completion = start + timedelta(hours=duration_hours)
        status = "completed" if random.random() < 0.92 else "cancelled"
        result_note = (
            "Out-of-service maintenance completed successfully."
            if status == "completed"
            else "Maintenance request cancelled after reassessment."
        )
        problem_type, facility_id = choose_problem_and_facility(code)
        maintenance.append(
            Maintenance(
                maintenance_id=next_mid,
                space_code=code,
                reporter_id=choose_reporter(),
                facility_id=facility_id,
                problem_type=problem_type,
                description="Generated out-of-service maintenance outside normal booking hours.",
                start=start,
                completion=completion,
                status=status,
                result_note=result_note,
                initial_impact="out-of-service",
                final_impact="out-of-service",
            )
        )
        next_mid += 1

    # 4) Open advisories near the end of the generated period. Advisory records do
    # not make the room unavailable but create acknowledgement workload.
    open_start_min = datetime(2025, 8, 1, 8, 0, 0)
    open_start_max = datetime(2025, 8, 20, 16, 0, 0)
    for _ in range(100):
        code = random.choice(space_codes)
        span_minutes = int((open_start_max - open_start_min).total_seconds() // 60)
        start = open_start_min + timedelta(minutes=random.randint(0, span_minutes))
        start = start.replace(minute=0, second=0)
        problem_type, facility_id = choose_problem_and_facility(code)
        maintenance.append(
            Maintenance(
                maintenance_id=next_mid,
                space_code=code,
                reporter_id=choose_reporter(),
                facility_id=facility_id,
                problem_type=problem_type,
                description="Generated active advisory for late academic-year room-finder testing.",
                start=start,
                completion=None,
                status="in progress",
                result_note=None,
                initial_impact="advisory",
                final_impact="advisory",
            )
        )
        next_mid += 1

    # Assign one primary staff member to every maintenance record.
    assignments: List[dict] = []
    for m in maintenance:
        assigned_at = m.start + timedelta(minutes=random.randint(5, 60))
        if m.completion is not None:
            unassigned_at = m.completion
        else:
            unassigned_at = None
        assignments.append(
            {
                "maintenance_id": m.maintenance_id,
                "staff_id": random.choice(staff_ids),
                "assigned_at": iso(assigned_at),
                "unassigned_at": iso(unassigned_at),
                "assignment_role": "primary",
            }
        )

    # Acknowledgements are required for every generated booking interval that
    # overlaps a maintenance record whose initial impact was advisory. The target
    # schema stores only the acknowledgement timestamp, so we set it to booking
    # creation time to represent acknowledgement at submission.
    ack_pairs: Dict[Tuple[int, int], dict] = {}
    advisory_maintenance = [m for m in maintenance if m.initial_impact == "advisory"]
    for m in advisory_maintenance:
        m_end = m.completion or datetime(9999, 12, 31, 23, 59, 59)
        for b in by_space[m.space_code]:
            # Arrays are sorted, so once bookings start after a bounded advisory,
            # no later booking can overlap it.
            if m.completion is not None and b.start >= m_end:
                break
            if b.end <= m.start:
                continue
            if intervals_overlap(b.start, b.end, m.start, m_end):
                key = (b.booking_id, m.maintenance_id)
                ack_pairs[key] = {
                    "booking_id": b.booking_id,
                    "maintenance_id": m.maintenance_id,
                    "acknowledged_at": iso(b.created_at),
                }

    return maintenance, assignments, escalations, list(ack_pairs.values())


def validate(
    bookings: Sequence[Booking],
    maintenance: Sequence[Maintenance],
    acknowledgements: Sequence[dict],
) -> dict:
    status_counts = Counter(b.final_status for b in bookings)

    # Verify non-overlap among all bookings that entered the approved lifecycle,
    # including completed and no-show history.
    by_space: Dict[str, List[Booking]] = defaultdict(list)
    for b in bookings:
        if b.final_status in APPROVED_LIFECYCLE_STATUSES:
            by_space[b.space_code].append(b)

    overlap_errors: List[Tuple[int, int]] = []
    for arr in by_space.values():
        arr.sort(key=lambda x: x.start)
        prev: Optional[Booking] = None
        for b in arr:
            if prev is not None and b.start < prev.end:
                overlap_errors.append((prev.booking_id, b.booking_id))
                if len(overlap_errors) >= 10:
                    break
            if prev is None or b.end > prev.end:
                prev = b
        if overlap_errors:
            break

    if overlap_errors:
        raise AssertionError(f"Approved booking overlap detected: {overlap_errors[:3]}")

    # Normal out-of-service maintenance must not overlap approved-lifecycle rows.
    # Escalated records are the intentional exception required to exercise the
    # affected-bookings report.
    approved_by_space = by_space
    unintended_oos_overlaps = []
    intentional_escalation_overlaps = 0
    for m in maintenance:
        if m.final_impact != "out-of-service":
            continue
        m_end = m.completion or datetime(9999, 12, 31, 23, 59, 59)
        for b in approved_by_space[m.space_code]:
            if b.start >= m_end:
                break
            if b.end <= m.start:
                continue
            if intervals_overlap(b.start, b.end, m.start, m_end):
                if m.initial_impact == "advisory":
                    intentional_escalation_overlaps += 1
                else:
                    unintended_oos_overlaps.append((m.maintenance_id, b.booking_id))
                    if len(unintended_oos_overlaps) >= 10:
                        break
        if unintended_oos_overlaps:
            break

    if unintended_oos_overlaps:
        raise AssertionError(
            "Unexpected approved booking/out-of-service maintenance overlap: "
            f"{unintended_oos_overlaps[:3]}"
        )

    ack_set = {(int(a["booking_id"]), int(a["maintenance_id"])) for a in acknowledgements}
    missing_ack = []
    all_bookings_by_space: Dict[str, List[Booking]] = defaultdict(list)
    for b in bookings:
        all_bookings_by_space[b.space_code].append(b)
    for arr in all_bookings_by_space.values():
        arr.sort(key=lambda x: x.start)

    for m in maintenance:
        if m.initial_impact != "advisory":
            continue
        m_end = m.completion or datetime(9999, 12, 31, 23, 59, 59)
        for b in all_bookings_by_space[m.space_code]:
            if m.completion is not None and b.start >= m_end:
                break
            if b.end <= m.start:
                continue
            if intervals_overlap(b.start, b.end, m.start, m_end):
                if (b.booking_id, m.maintenance_id) not in ack_set:
                    missing_ack.append((b.booking_id, m.maintenance_id))
                    if len(missing_ack) >= 10:
                        break
        if missing_ack:
            break

    if missing_ack:
        raise AssertionError(f"Missing advisory acknowledgement(s): {missing_ack[:3]}")

    return {
        "booking_count": len(bookings),
        "status_counts": dict(sorted(status_counts.items())),
        "approved_lifecycle_count": sum(status_counts[s] for s in APPROVED_LIFECYCLE_STATUSES if s in status_counts),
        "approved_overlap_pairs": 0,
        "unintended_oos_overlap_pairs": 0,
        "intentional_escalation_overlap_pairs": intentional_escalation_overlaps,
        "acknowledgement_count": len(acknowledgements),
    }


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate deterministic CS486 G10 Phase 2 benchmark data.")
    parser.add_argument("--bookings", type=int, default=DEFAULT_BOOKINGS, help="Number of booking rows (default: 100000).")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "generated",
        help="Output directory for CSV files.",
    )
    args = parser.parse_args()

    if args.bookings < 100_000:
        raise SystemExit("Phase 2 requires at least 100,000 booking records. Use --bookings >= 100000.")

    random.seed(SEED)
    out = args.output_dir.resolve()
    ensure_dir(out)

    user_rows, requester_ids, staff_ids = generate_users()
    space_rows, spaces = generate_spaces(60)
    facility_rows, facility_ids_by_space_and_type = generate_facility_instances(spaces)
    bookings = generate_bookings(args.bookings, spaces, requester_ids)
    approval_rows = generate_approvals(bookings, staff_ids, spaces)
    usage_rows = generate_usage_sessions(bookings, staff_ids)
    maintenance, assignment_rows, escalation_rows, ack_rows = generate_maintenance(
        bookings, spaces, requester_ids, staff_ids, facility_ids_by_space_and_type
    )

    validation = validate(bookings, maintenance, ack_rows)

    approval_method_counts = Counter(row["decision_method"] for row in approval_rows)
    automatic_booking_ids = {int(row["booking_id"]) for row in approval_rows if row["decision_method"] == "automatic"}
    booking_by_id = {b.booking_id: b for b in bookings}
    space_type_by_code = {s.code: s.space_type for s in spaces}
    invalid_automatic = [
        booking_id
        for booking_id in automatic_booking_ids
        if booking_by_id[booking_id].final_status not in {"approved", "completed", "no-show"}
        or space_type_by_code[booking_by_id[booking_id].space_code] != "meeting room"
    ]
    if invalid_automatic:
        raise AssertionError(f"Invalid automatic approval rows: {invalid_automatic[:3]}")
    validation["approval_method_counts"] = dict(sorted(approval_method_counts.items()))
    validation["invalid_automatic_approvals"] = 0

    files: Dict[str, int] = {}
    files["users.csv"] = write_csv(
        out / "users.csv",
        ["user_id", "full_name", "email", "phone_number", "role", "department", "account_status"],
        user_rows,
    )
    files["spaces.csv"] = write_csv(
        out / "spaces.csv",
        ["space_code", "space_name", "space_type", "building", "floor", "room_number", "capacity", "current_status", "usage_policy"],
        space_rows,
    )
    files["facility_instances.csv"] = write_csv(
        out / "facility_instances.csv",
        ["facility_id", "facility_type_name", "space_code", "asset_tag", "instance_status", "condition_note", "installed_at"],
        facility_rows,
    )
    files["booking_requests.csv"] = write_csv(
        out / "booking_requests.csv",
        ["booking_id", "requester_id", "space_code", "requested_start_time", "requested_end_time", "purpose_of_use", "expected_participants", "final_booking_status", "created_at"],
        (
            {
                "booking_id": b.booking_id,
                "requester_id": b.requester_id,
                "space_code": b.space_code,
                "requested_start_time": iso(b.start),
                "requested_end_time": iso(b.end),
                "purpose_of_use": b.purpose,
                "expected_participants": b.participants,
                "final_booking_status": b.final_status,
                "created_at": iso(b.created_at),
            }
            for b in bookings
        ),
    )
    files["approvals.csv"] = write_csv(
        out / "approvals.csv",
        ["booking_id", "staff_id", "decision", "decision_time", "decision_note", "rejection_reason", "decision_method"],
        approval_rows,
    )
    files["usage_sessions.csv"] = write_csv(
        out / "usage_sessions.csv",
        ["booking_id", "actual_start_time", "checked_in_by", "initial_condition", "actual_end_time", "final_condition", "usage_notes"],
        usage_rows,
    )
    files["maintenance_records.csv"] = write_csv(
        out / "maintenance_records.csv",
        ["maintenance_id", "space_code", "reporter_id", "facility_id", "problem_type", "problem_description", "start_time", "completion_time", "maintenance_status", "result_note", "initial_impact_level", "final_impact_level"],
        (
            {
                "maintenance_id": m.maintenance_id,
                "space_code": m.space_code,
                "reporter_id": m.reporter_id,
                "facility_id": "" if m.facility_id is None else m.facility_id,
                "problem_type": m.problem_type,
                "problem_description": m.description,
                "start_time": iso(m.start),
                "completion_time": iso(m.completion),
                "maintenance_status": m.status,
                "result_note": m.result_note or "",
                "initial_impact_level": m.initial_impact,
                "final_impact_level": m.final_impact,
            }
            for m in maintenance
        ),
    )
    files["maintenance_assignments.csv"] = write_csv(
        out / "maintenance_assignments.csv",
        ["maintenance_id", "staff_id", "assigned_at", "unassigned_at", "assignment_role"],
        assignment_rows,
    )
    files["maintenance_escalations.csv"] = write_csv(
        out / "maintenance_escalations.csv",
        ["maintenance_id", "changed_by", "escalated_at", "new_impact_level", "change_reason"],
        escalation_rows,
    )
    files["booking_advisory_acknowledgements.csv"] = write_csv(
        out / "booking_advisory_acknowledgements.csv",
        ["booking_id", "maintenance_id", "acknowledged_at"],
        ack_rows,
    )

    manifest = {
        "generator": "CS486 G10 Phase 2 data generator",
        "seed": SEED,
        "academic_years": ["2022-2023", "2023-2024", "2024-2025"],
        "date_range": {
            "start": iso(ACADEMIC_START),
            "end": iso(ACADEMIC_END),
        },
        "requested_booking_count": args.bookings,
        "files": files,
        "validation": validation,
        "notes": [
            "Approved/completed/no-show bookings never overlap one another in the same space.",
            "Normal out-of-service maintenance is placed outside booking hours.",
            "100 advisory-to-out-of-service escalations deliberately overlap already-approved bookings so the affected-bookings report has test data.",
            "Every generated booking overlapping an initially advisory maintenance interval has an acknowledgement row.",
            "Automatic approvals are generated only for approved-lifecycle meeting-room bookings; automatic rows have no staff actor.",
            "Equipment-specific maintenance rows reference a facility instance of the matching equipment type.",
        ],
    }
    manifest["sha256"] = {name: sha256(out / name) for name in files}

    with (out / "manifest.json").open("w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

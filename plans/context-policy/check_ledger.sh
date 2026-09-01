#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$repo_root" <<'PY'
from collections import Counter
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
ledger = root / "plans/context-policy/ledger.md"
call_re = re.compile(r"(?:Canada\.Can\.)?can\?\s*\([^)]*\)")

actual = []
for path in sorted((root / "lib/philomena_web").rglob("*")):
    if path.suffix not in {".ex", ".slime"}:
        continue
    relative = path.relative_to(root)
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        actual.extend(
            (f"{relative}:{line_number}", match.group())
            for match in call_re.finditer(line)
        )

rows = []
for line in ledger.read_text().splitlines():
    if not re.match(r"^\|\s*\d{3}\s*\|", line):
        continue
    fields = [field.strip() for field in line.split("|")]
    if len(fields) != 8:
        raise SystemExit(f"malformed ledger row: {line}")
    rows.append((fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]))

if len(actual) != 112:
    raise SystemExit(f"expected 112 can?/3 occurrences, found {len(actual)}")
if len(rows) != len(actual):
    raise SystemExit(f"ledger has {len(rows)} rows for {len(actual)} occurrences")
if [row[0] for row in rows] != [f"{n:03d}" for n in range(1, len(rows) + 1)]:
    raise SystemExit("ledger row numbers are not sequential")

types = {"access", "disclosure", "affordance", "presentation"}
if any(row[4] not in types for row in rows):
    raise SystemExit("ledger contains an invalid policy type")
if any(not row[3] or not row[5] for row in rows):
    raise SystemExit("ledger has an empty adjacent-predicate or target field")

expected = Counter(actual)
listed = Counter((row[1], row[2]) for row in rows)
if expected != listed:
    missing = expected - listed
    extra = listed - expected
    raise SystemExit(f"ledger/source mismatch; missing={dict(missing)} extra={dict(extra)}")

print(f"context-policy ledger OK: {len(rows)} occurrences")
PY

"""Unit tests for the OCI cost report's date window and message.

The script lives inside a ConfigMap (base/configmap-script.yaml), so these tests read it out
of that manifest and import it, rather than testing a copy that could drift from what the
CronJob actually mounts. The Usage API is replaced by a fake that honours the one property
the window logic depends on: timeUsageEnded is exclusive.

Run: python3 kubernetes/apps/oci-cost-report/tests/test_report.py
"""

import datetime as dt
import importlib.util
import pathlib
import sys
import tempfile
import types
from decimal import Decimal

CONFIGMAP = pathlib.Path(__file__).resolve().parent.parent / "base" / "configmap-script.yaml"


def load_report():
    """Import report.py from the ConfigMap's block scalar, with the stdlib only.

    The block is every line after `report.py: |` that is blank or indented by at least the
    block's four spaces, which is exactly how YAML ends a literal block.
    """
    lines = CONFIGMAP.read_text(encoding="utf-8").splitlines()
    body = []
    for line in lines[lines.index("  report.py: |") + 1 :]:
        if line.strip() and not line.startswith("    "):
            break
        body.append(line[4:])
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "report.py"
        path.write_text("\n".join(body) + "\n", encoding="utf-8")
        spec = importlib.util.spec_from_file_location("report", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


report = load_report()
FAILURES = []


def check(label, got, want):
    if got != want:
        FAILURES.append(f"{label}\n     got:  {got!r}\n     want: {want!r}")
    print(f"  {'ok  ' if got == want else 'FAIL'} {label}")


def usage_api(daily: dict[str, dict[str, str]]):
    """A stand-in for query_usage over {date: {service: amount}}. Records every window asked for."""
    calls = []

    def query_usage(_tenancy, start, end, query_type):
        calls.append((start, end, query_type))
        return [
            {
                "service": service,
                "timeUsageStarted": f"{date}T00:00:00.000Z",
                "computedAmount": amount,
                "currency": "EUR",
            }
            for date, per_service in sorted(daily.items())
            # Exclusive end, as the live API behaves.
            if start.isoformat() <= date < end.isoformat()
            for service, amount in per_service.items()
        ]

    return query_usage, calls


def tenancy(name="firefly", warn="5.00", alert="15.00"):
    return types.SimpleNamespace(name=name, warn=Decimal(warn), alert=Decimal(alert))


def run(today: dt.date, daily: dict, tenancies=None, failures=()):
    """collect() every tenancy against the fake API, then build the message."""
    report.query_usage, calls = usage_api(daily)
    results = [report.collect(t, today) for t in (tenancies or [tenancy()])]
    title, message = report.build_message(results, list(failures), today)
    return calls, results, title, message


# September: 7 cents a day of Object Storage, then 43 cents on the 30th. The 1st of October
# posted "€0.43 yesterday · €0.00 MTD" for exactly this month.
SEPT = {f"2026-09-{d:02d}": {"Object Storage": "0.07"} for d in range(1, 30)}
SEPT["2026-09-30"] = {"Object Storage": "0.43"}
OCT = {"2026-10-01": {"Object Storage": "0.08"}}


print("\nreport_window — anchored to the reported day, not to today")
check("a normal day: the 1st up to yesterday", report.report_window(dt.date(2026, 9, 30)), (dt.date(2026, 9, 1), dt.date(2026, 9, 29)))
check("the 2nd: one day so far", report.report_window(dt.date(2026, 10, 2)), (dt.date(2026, 10, 1), dt.date(2026, 10, 1)))
check("the 1st: the whole previous month", report.report_window(dt.date(2026, 10, 1)), (dt.date(2026, 9, 1), dt.date(2026, 9, 30)))
check("1 January: December of the previous year", report.report_window(dt.date(2027, 1, 1)), (dt.date(2026, 12, 1), dt.date(2026, 12, 31)))
check("range label", report._span(dt.date(2026, 9, 1), dt.date(2026, 9, 29)), "1–29 Sep 2026")
check("one-day label", report._span(dt.date(2026, 10, 1), dt.date(2026, 10, 1)), "1 Oct 2026")

print("\na normal day")
calls, results, title, message = run(dt.date(2026, 9, 30), SEPT)
check("asks for the month so far, ending with yesterday", calls, [(dt.date(2026, 9, 1), dt.date(2026, 9, 30), "COST")])
check("yesterday", results[0]["day"], {"Object Storage": Decimal("0.07")})
check("month-to-date runs from the 1st", results[0]["mtd"], {"Object Storage": Decimal("2.03")})
check("title names the day", title, ":moneybag: OCI daily cost — 2026-09-29")
# Was "(1–30 Sep 2026)": a report about the 29th, labelled as running to the 30th.
check("label ends on the reported day", "€0.07 yesterday · €2.03 month-to-date (1–29 Sep 2026)" in message, True)
check("tenancy line is unchanged", "€0.07 yesterday · €2.03 MTD" in message, True)

print("\nthe 1st closes the previous month")
calls, results, title, message = run(dt.date(2026, 10, 1), {**SEPT, **OCT})
check("asks for the whole previous month", calls, [(dt.date(2026, 9, 1), dt.date(2026, 10, 1), "COST")])
check("the last day is still read", results[0]["day"], {"Object Storage": Decimal("0.43")})
check("month-to-date is all of September", results[0]["mtd"], {"Object Storage": Decimal("2.46")})
check("title names the month", title, ":moneybag: OCI cost: September 2026, full month")
check(
    "fleet total is the month, with its last day once",
    "*Fleet total* — €2.46 for September 2026 (1–30 Sep 2026) · €0.43 on 2026-09-30" in message,
    True,
)
check("tenancy shows its month", "€2.46 for the month" in message, True)
check("services show their month", "• Object Storage — €2.46" in message, True)
check("no daily columns on the close", ("yesterday" in message, "MTD" in message), (False, False))
check("the empty-month line that shipped is gone", "€0.00" in message, False)

many = {f"2026-09-{i + 1:02d}": {f"Svc{i}": str(Decimal("0.01") * (i + 1))} for i in range(9)}
_, _, _, message = run(dt.date(2026, 10, 1), many)
check("the overflow line on the close is the month's", "• _+1 more — €0.01_" in message, True)
_, _, _, message = run(dt.date(2026, 9, 30), many)
check("and stays month-to-date on a normal day", "• _+1 more — €0.01 MTD_" in message, True)

print("\n1 January closes December of the previous year")
DEC = {"2026-12-01": {"Object Storage": "0.10"}, "2026-12-31": {"Object Storage": "0.20"}}
calls, results, title, message = run(dt.date(2027, 1, 1), DEC)
check("asks for December", calls, [(dt.date(2026, 12, 1), dt.date(2027, 1, 1), "COST")])
check("title names December 2026", title, ":moneybag: OCI cost: December 2026, full month")
check("labelled as December", "€0.30 for December 2026 (1–31 Dec 2026)" in message, True)

print("\nthe 2nd is a daily report again")
calls, results, title, message = run(dt.date(2026, 10, 2), {**SEPT, **OCT})
check("asks for the 1st only", calls, [(dt.date(2026, 10, 1), dt.date(2026, 10, 2), "COST")])
check("September is not in October's month-to-date", results[0]["mtd"], {"Object Storage": Decimal("0.08")})
check("the month so far is one day long", "€0.08 month-to-date (1 Oct 2026)" in message, True)

print("\nthresholds and gaps on the 1st")
_, _, title, message = run(dt.date(2026, 10, 1), SEPT, tenancies=[tenancy(warn="0.50", alert="1.00")])
check("the alert meets the full month", title, ":rotating_light: OCI cost: September 2026, full month, unexpected spend in firefly")
_, _, title, _ = run(dt.date(2026, 9, 30), SEPT, tenancies=[tenancy(warn="0.50", alert="1.00")])
check("the daily alert title is unchanged", title, ":rotating_light: OCI daily cost — unexpected spend in firefly")
_, _, title, _ = run(dt.date(2026, 10, 1), SEPT, failures=[("cloudworkers", "no config mounted")])
check("a missing tenancy is named on the close too", title, ":warning: OCI cost: September 2026, full month (1 tenancy unavailable)")
late = {d: s for d, s in SEPT.items() if d != "2026-09-30"}
_, results, _, message = run(dt.date(2026, 10, 1), late)
check("a last day OCI has not written yet is flagged", results[0]["has_yesterday"], False)
check("as a month total that can still rise", "no rows for 30 Sep yet: OCI usage data lags, so this month total can still rise" in message, True)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILURE(S):")
    for f in FAILURES:
        print("  - " + f)
    sys.exit(1)
print("all assertions passed")

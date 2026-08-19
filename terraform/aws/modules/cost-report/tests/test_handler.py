"""Unit tests for the cost report's CUR parser and formatter.

WHY THESE EXIST AT ALL. The Cost Explorer version of this function could be pointed at the
real account and eyeballed. The CUR version cannot: AWS writes the first export up to 24
hours after it is created, so the parsing had to be written before any real file existed to
read. Everything below is the substitute for that — a synthetic export in the documented
CUR 2.0 shape, plus the specific ways a cost report goes wrong QUIETLY rather than loudly.

Run: python3 tests/test_handler.py
"""

import datetime as dt
import gzip
import io
import pathlib
import sys
from decimal import Decimal

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "src"))

from handler import (  # noqa: E402
    _data_prefix,
    _money,
    _qty,
    _service_matches,
    _usage_matches,
    build_freetier_report,
    build_report,
    read_cur,
)

FAILURES = []


def check(label, got, want):
    if got != want:
        FAILURES.append(f"{label}\n     got:  {got!r}\n     want: {want!r}")
    print(f"  {'ok  ' if got == want else 'FAIL'} {label}")


class FakeS3:
    """Minimal stand-in for the two S3 calls read_cur makes."""

    def __init__(self, objects: dict[str, bytes]):
        self.objects = objects

    def get_paginator(self, _op):
        outer = self

        class P:
            def paginate(self, Bucket, Prefix):  # noqa: N803 - boto3 kwarg names
                yield {
                    "Contents": [
                        {"Key": k} for k in sorted(outer.objects) if k.startswith(Prefix)
                    ]
                }

        return P()

    def get_object(self, Bucket, Key):  # noqa: N803 - boto3 kwarg names
        return {"Body": io.BytesIO(self.objects[Key])}


def cur_gz(header: list[str], rows: list[list[str]]) -> bytes:
    buf = io.BytesIO()
    with gzip.open(buf, "wt", newline="") as fh:
        fh.write(",".join(header) + "\n")
        for r in rows:
            fh.write(",".join(r) + "\n")
    return buf.getvalue()


HEADER = [
    "line_item_usage_account_id",
    "line_item_usage_start_date",
    "line_item_product_code",
    "line_item_unblended_cost",
    "line_item_usage_type",
    "line_item_usage_amount",
]
NAMES = {"857256953358": "Root", "666802049426": "prd-nievah"}


print("\n_money — the whole reason this report is legible")
check("zero", _money(Decimal("0")), "$0.00")
check("sub-cent keeps 3 sig figs", _money(Decimal("0.0000396003")), "$0.0000396")
check("very small", _money(Decimal("0.0000000801")), "$0.0000000801")
check("cent boundary", _money(Decimal("0.01")), "$0.01")
check("just under a cent", _money(Decimal("0.0099")), "$0.00990")
check("thousands", _money(Decimal("1234.567")), "$1,234.57")
check("credit sign outside symbol", _money(Decimal("-0.00004")), "-$0.0000400")

print("\n_data_prefix — must match the layout AWS writes")
check(
    "with prefix",
    _data_prefix("cur", "mm-cost-report", dt.date(2026, 8, 18)),
    "cur/mm-cost-report/data/BILLING_PERIOD=2026-08/",
)
check(
    "empty prefix does not produce a leading slash",
    _data_prefix("", "mm-cost-report", dt.date(2026, 8, 18)),
    "mm-cost-report/data/BILLING_PERIOD=2026-08/",
)

print("\nread_cur")
prefix = _data_prefix("cur", "exp", dt.date(2026, 8, 18))
s3 = FakeS3(
    {
        prefix + "exp-00001.csv.gz": cur_gz(
            HEADER,
            [
                ["666802049426", "2026-08-17T00:00:00.000Z", "AmazonS3", "0.0000000801", "EUW1-Requests-Tier1", "12"],
                ["666802049426", "2026-08-17T00:00:00.000Z", "AmazonS3", "0.0000000199", "EUW1-Requests-Tier1", "3"],
                ["857256953358", "2026-08-16T00:00:00.000Z", "AWSGlue", "0.000005", "Global-Catalog-Request", "54"],
                ["666802049426", "2026-08-17T00:00:00.000Z", "AWSGlue", "0", "Global-Catalog-Request", "8"],
            ],
        ),
        # Must be ignored: only .csv.gz is data. A manifest read as CSV would inject garbage.
        prefix + "exp-Manifest.json": b'{"not":"data"}',
    }
)
rows, usage, objects = read_cur(s3, "b", prefix)
check(
    "line items on the same day+service are summed",
    rows[("2026-08-17", "666802049426", "AmazonS3")],
    Decimal("0.0000000801") + Decimal("0.0000000199"),
)
check("other days retained separately", rows[("2026-08-16", "857256953358", "AWSGlue")], Decimal("0.000005"))
check("exact-zero rows dropped", ("2026-08-17", "666802049426", "AWSGlue") in rows, False)
check("non-csv.gz keys skipped", len(rows), 2)
check("object count returned for the delivered flag", objects, 1)

print("\nread_cur — reordered columns (CUR order is not contractual)")
shuffled = [HEADER[3], HEADER[1], HEADER[0], HEADER[2], HEADER[5], HEADER[4]]
s3b = FakeS3(
    {
        prefix + "a.csv.gz": cur_gz(
            shuffled,
            [["0.25", "2026-08-17T00:00:00.000Z", "666802049426", "AmazonS3", "9", "EUW1-Requests-Tier1"]],
        )
    }
)
check(
    "read by name, not position",
    read_cur(s3b, "b", prefix)[0][("2026-08-17", "666802049426", "AmazonS3")],
    Decimal("0.25"),
)

print("\nread_cur — a malformed row must not lose the file")
s3c = FakeS3(
    {
        prefix + "a.csv.gz": cur_gz(
            HEADER,
            [
                ["666802049426", "2026-08-17T00:00:00.000Z", "AmazonS3", "not-a-number", "EUW1-Requests-Tier1", "1"],
                ["666802049426", "2026-08-17T00:00:00.000Z", "AmazonS3", "0.5", "EUW1-Requests-Tier1", "1"],
            ],
        )
    }
)
check("good row still counted", read_cur(s3c, "b", prefix)[0][("2026-08-17", "666802049426", "AmazonS3")], Decimal("0.5"))

print("\nbuild_report")
today = dt.date(2026, 8, 18)
data = {
    ("2026-08-17", "666802049426", "AmazonS3"): Decimal("0.0000000801"),
    ("2026-08-05", "666802049426", "AmazonS3"): Decimal("0.0000396"),
    ("2026-08-04", "857256953358", "AWSGlue"): Decimal("0.000005"),
}
title, desc = build_report(data, NAMES, today, delivered=True)
check("title names the day covered", title, ":moneybag: AWS daily cost — 2026-08-17")
check("org yesterday total", "$0.0000000801 on 2026-08-17" in desc, True)
# 0.0000000801 + 0.0000396 + 0.000005 = 0.0000446801, which is $0.0000447 at three
# significant figures. Written out because an off-by-one in the last digit here is
# exactly the kind of rounding error this formatter exists to get right.
check("org MTD sums the month", "$0.0000447 month-to-date" in desc, True)
check("bigger spender first", desc.index("prd-nievah") < desc.index("Root"), True)
check("account with no spend yesterday shows $0.00", "$0.00 yesterday · $0.00000500 MTD" in desc, True)
check("within Chatbot's 8000-char envelope", len(desc) <= 8000, True)

print("\nbuild_report — an account that spent nothing still appears")
title2, desc2 = build_report({}, NAMES, today, delivered=True)
check("silent account is listed, not omitted", desc2.count("_no charges_"), 2)

print("\nbuild_report — before the first export lands")
title3, desc3 = build_report({}, NAMES, today, delivered=False)
check("distinguishable from a quiet day", "awaiting first export" in title3, True)
check("does not claim $0.00", "$0.00" not in desc3, True)

print("\nbuild_report — credits render as credits")
_, desc4 = build_report(
    {("2026-08-17", "857256953358", "AWSGlue"): Decimal("-0.0001")}, NAMES, today, delivered=True
)
check("negative shows as -$", "-$0.000100" in desc4, True)

print("\nread_cur — usage quantities, including on $0.00 line items")
check(
    "zero-cost rows still contribute usage (the whole point for free tier)",
    usage[("AWSGlue", "Global-Catalog-Request")]["666802049426"],
    Decimal("8"),
)
check(
    "usage summed per account",
    usage[("AmazonS3", "EUW1-Requests-Tier1")]["666802049426"],
    Decimal("15"),
)

print("\n_usage_matches — the two APIs do not agree on the string")
check("region prefix tolerated", _usage_matches("Catalog-Request", "EU-Catalog-Request"), True)
check("other region prefix too", _usage_matches("Catalog-Request", "EUC1-Catalog-Request"), True)
check("exact match", _usage_matches("CW:Requests", "CW:Requests"), True)
# The suffixes the first implementation missed, which made nearly every line report
# "per-account split unavailable" against real data.
check("variant SUFFIX tolerated (arm64 lambda)", _usage_matches("Request", "EU-Request-ARM"), True)
check("and the GB-second variant", _usage_matches("Lambda-GB-Second", "EU-Lambda-GB-Second-ARM"), True)
check("and a FIFO queue tier", _usage_matches("Requests", "EU-Requests-FIFO-Tier1"), True)
# THE COLLISION A SUBSTRING TEST WOULD MAKE: "requests-tier1" contains "request", so a
# naive match files every S3 and SNS request count under Lambda's Request allowance.
check("singular does not swallow plural", _usage_matches("Request", "EU-Requests-Tier1"), False)

print("\n_service_matches — the check that stops the rest of the collisions")
check("vendor prefix differences", _service_matches("AWS Glue", "AWSGlue"), True)
check("wholly different naming", _service_matches("Amazon Simple Queue Service", "AWSQueueService"), True)
check("identical", _service_matches("AmazonCloudWatch", "AmazonCloudWatch"), True)
# S3, SNS and SQS all publish EU-Requests-Tier1; only one of them is SQS.
check("S3 is not SQS", _service_matches("Amazon Simple Queue Service", "AmazonS3"), False)
check("SNS is not SQS", _service_matches("Amazon Simple Queue Service", "AmazonSNS"), False)

print("\n_qty")
check("counts render as integers", _qty(Decimal("1000000")), "1,000,000")
check("float forecasts are cut to two places", _qty(Decimal("3.444444444444444")), "3.44")

print("\nbuild_freetier_report")
FT = [
    {"service": "AWS Glue", "usageType": "Catalog-Request", "actualUsageAmount": 54.0,
     "forecastedUsageAmount": 93.0, "limit": 1000000.0, "unit": "Request", "freeTierType": "Always Free"},
    {"service": "Amazon Simple Queue Service", "usageType": "Requests", "actualUsageAmount": 2.0,
     "forecastedUsageAmount": 3.44, "limit": 1000000.0, "unit": "Requests", "freeTierType": "Always Free"},
]
ft_title, ft_body = build_freetier_report(
    FT,
    {
        ("AWSGlue", "EU-Catalog-Request"): {"666802049426": Decimal("40")},
        # A second CUR usage type under the SAME allowance must be SUMMED in, not picked
        # between — one allowance routinely spans regional and tier variants.
        ("AWSGlue", "EUC1-Catalog-Request"): {"857256953358": Decimal("14")},
        # Must NOT count against SQS's Requests allowance: right usage type, wrong service.
        ("AmazonS3", "EU-Requests-Tier1"): {"666802049426": Decimal("99999")},
    },
    NAMES,
    today,
)
check("calm title when everything is inside its allowance", ft_title.startswith(":free:"), True)
check("limit shown with thousands separators", "54 of 1,000,000 Request used" in ft_body, True)
check("per-account split present when CUR matched", "prd-nievah — 40" in ft_body, True)
check("variants of one allowance are summed across CUR types", "Root — 14" in ft_body, True)
check("wrong-service usage is not absorbed", "99,999" not in ft_body, True)
check("biggest consumer of that allowance first", ft_body.index("prd-nievah — 40") < ft_body.index("Root — 14"), True)
check("unmatched usage type says so rather than implying zero", "_per-account split unavailable for this usage type_" in ft_body, True)
check("states that the allowance is org-wide", "organisation as a whole" in ft_body, True)
check("within Chatbot's envelope", len(ft_body) <= 8000, True)

print("\nbuild_freetier_report — the case that costs money")
BREACH = [{"service": "Amazon S3", "usageType": "Requests-Tier1", "actualUsageAmount": 1900.0,
           "forecastedUsageAmount": 2600.0, "limit": 2000.0, "unit": "Requests", "freeTierType": "12 Month Free"}]
b_title, b_body = build_freetier_report(BREACH, {}, NAMES, today)
check("breach is shouted in the title", "EXCEEDED" in b_title, True)
check("breach flagged inline", ":rotating_light:" in b_body, True)
check("percentage over 100 shown", "130.0% of the allowance" in b_body, True)
check("tiny share shown as a bound, not rounded to 0.0%", "<0.1% of the allowance" in ft_body, True)

print("\nbuild_freetier_report — ordering is by forecast share, not by service name")
MIX = [
    {"service": "A-quiet", "usageType": "q", "actualUsageAmount": 1.0, "forecastedUsageAmount": 1.0, "limit": 1000.0, "unit": "u", "freeTierType": "Always Free"},
    {"service": "Z-busy", "usageType": "z", "actualUsageAmount": 900.0, "forecastedUsageAmount": 950.0, "limit": 1000.0, "unit": "u", "freeTierType": "Always Free"},
]
_, mix_body = build_freetier_report(MIX, {}, NAMES, today)
check("closest to its limit is read first", mix_body.index("Z-busy") < mix_body.index("A-quiet"), True)
check("above 80% is warned", ":warning:" in mix_body, True)

print("\nbuild_freetier_report — nothing consumed")
n_title, n_body = build_freetier_report([], {}, NAMES, today)
check("does not render an empty table", "nothing consumed yet" in n_title, True)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILURE(S):")
    for f in FAILURES:
        print("  - " + f)
    sys.exit(1)
print("all assertions passed")

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
import json
import logging
import os
import pathlib
import sys
import types
from decimal import Decimal

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "src"))

try:
    import boto3  # noqa: F401 - the Lambda runtime ships it; a workstation often does not
except ModuleNotFoundError:
    # Nothing under test calls boto3 (run() takes its clients as an argument), so a bare
    # module is enough for the handler to import.
    sys.modules["boto3"] = types.ModuleType("boto3")

from handler import (  # noqa: E402
    _data_prefix,
    _money,
    _qty,
    _service_matches,
    _span,
    _usage_matches,
    build_freetier_close,
    build_freetier_report,
    build_report,
    load_freetier_snapshot,
    read_cur,
    report_window,
    run,
)

FAILURES = []


def check(label, got, want):
    if got != want:
        FAILURES.append(f"{label}\n     got:  {got!r}\n     want: {want!r}")
    print(f"  {'ok  ' if got == want else 'FAIL'} {label}")


class NoSuchKey(Exception):
    """What a real S3 client raises from get_object for a key that does not exist."""


class FakeS3:
    """Minimal stand-in for the S3 calls the handler makes. Records every prefix listed."""

    exceptions = types.SimpleNamespace(NoSuchKey=NoSuchKey)

    def __init__(self, objects: dict[str, bytes]):
        self.objects = objects
        self.listed: list[str] = []

    def get_paginator(self, _op):
        outer = self

        class P:
            def paginate(self, Bucket, Prefix):  # noqa: N803 - boto3 kwarg names
                outer.listed.append(Prefix)
                yield {
                    "Contents": [
                        {"Key": k} for k in sorted(outer.objects) if k.startswith(Prefix)
                    ]
                }

        return P()

    def get_object(self, Bucket, Key):  # noqa: N803 - boto3 kwarg names
        if Key not in self.objects:
            raise NoSuchKey(Key)
        return {"Body": io.BytesIO(self.objects[Key])}

    def put_object(self, Bucket, Key, Body, ContentType=None):  # noqa: N803 - boto3 kwarg names
        self.objects[Key] = Body


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

print("\nreport_window — anchored to the reported day, not to today")
check("a normal day: the 1st up to yesterday", report_window(dt.date(2026, 9, 30)), (dt.date(2026, 9, 1), dt.date(2026, 9, 29)))
check("the 2nd: one day so far", report_window(dt.date(2026, 10, 2)), (dt.date(2026, 10, 1), dt.date(2026, 10, 1)))
check("the 1st: the whole previous month", report_window(dt.date(2026, 10, 1)), (dt.date(2026, 9, 1), dt.date(2026, 9, 30)))
check("1 January: December of the previous year", report_window(dt.date(2027, 1, 1)), (dt.date(2026, 12, 1), dt.date(2026, 12, 31)))
check("1 March after a leap February", report_window(dt.date(2028, 3, 1)), (dt.date(2028, 2, 1), dt.date(2028, 2, 29)))
check("range label", _span(dt.date(2026, 9, 1), dt.date(2026, 9, 29)), "1–29 Sep 2026")
check("one-day label", _span(dt.date(2026, 10, 1), dt.date(2026, 10, 1)), "1 Oct 2026")

print("\nbuild_report — the window ends on the day it reports")
bounded = dict(data)
bounded[("2026-08-18", "666802049426", "AmazonS3")] = Decimal("5")  # today, still being billed
bounded[("2026-07-31", "666802049426", "AmazonS3")] = Decimal("7")  # last month
_, bdesc = build_report(bounded, NAMES, today, delivered=True)
# Was "(1–18 Aug 2026)": a report about the 17th, labelled as running to the 18th.
check("label ends on the reported day, not today", "month-to-date (1–17 Aug 2026)" in bdesc, True)
check("rows for today and for last month are not month-to-date", "$0.0000447 month-to-date" in bdesc, True)

print("\nbuild_report — the 1st closes the previous month")
SEPT = {
    ("2026-09-01", "666802049426", "AmazonS3"): Decimal("0.50"),
    ("2026-09-15", "666802049426", "AWSLambda"): Decimal("0.25"),
    ("2026-09-29", "857256953358", "AWSGlue"): Decimal("0.27"),
    ("2026-09-30", "666802049426", "AmazonS3"): Decimal("0.06"),
    # Today's first rows, if a refresh already carries them, belong to October's report.
    ("2026-10-01", "666802049426", "AmazonS3"): Decimal("9.99"),
}
c_title, c_desc = build_report(SEPT, NAMES, dt.date(2026, 10, 1), delivered=True)
check("title names the month, not a day", c_title, ":moneybag: AWS cost: September 2026, full month")
check("org total is the whole month", "*Org total* — $1.08 for September 2026 (1–30 Sep 2026)" in c_desc, True)
check("the month's last day is still reported once", "· $0.06 on 2026-09-30" in c_desc, True)
check("accounts show their month", "$0.81 for the month" in c_desc, True)
check("services show their month", "• AmazonS3 — $0.56" in c_desc, True)
check("no daily columns on the close", ("yesterday" in c_desc, "MTD" in c_desc), (False, False))
check("biggest spender of the month first", c_desc.index("prd-nievah") < c_desc.index("Root"), True)

j_title, j_desc = build_report(
    {
        ("2026-12-01", "857256953358", "AWSGlue"): Decimal("0.01"),
        ("2026-12-31", "857256953358", "AWSGlue"): Decimal("0.02"),
    },
    NAMES,
    dt.date(2027, 1, 1),
    delivered=True,
)
check("1 January closes December of the previous year", j_title, ":moneybag: AWS cost: December 2026, full month")
check("and labels it as December", "$0.03 for December 2026 (1–31 Dec 2026)" in j_desc, True)

many = {(f"2026-09-{i + 1:02d}", "666802049426", f"Svc{i:02d}"): Decimal("0.01") * (i + 1) for i in range(11)}
_, many_close = build_report(many, NAMES, dt.date(2026, 10, 1), delivered=True)
_, many_daily = build_report(many, NAMES, dt.date(2026, 9, 30), delivered=True)
check("the overflow line on the close is the month's", "• _+1 more — $0.01_" in many_close, True)
check("and stays month-to-date on a normal day", "• _+1 more — $0.01 MTD_" in many_daily, True)

print("\nbuild_report — the 2nd is a daily report again")
s_title, s_desc = build_report(
    {("2026-10-01", "666802049426", "AmazonS3"): Decimal("0.0000918")}, NAMES, dt.date(2026, 10, 2), delivered=True
)
check("title is the 1st", s_title, ":moneybag: AWS daily cost — 2026-10-01")
check("and the month so far is one day long", "$0.0000918 month-to-date (1 Oct 2026)" in s_desc, True)

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

print("\nbuild_freetier_close — the 1st: the closed month's final usage against its allowances")
SAVED = "2026-09-30T07:00:04.512301+00:00"
SNAP = {
    "savedAt": SAVED,
    "freeTierUsages": [
        {"service": "AWS Glue", "usageType": "Catalog-Request", "actualUsageAmount": 50.0,
         "forecastedUsageAmount": 52.0, "limit": 1000000.0, "unit": "Request", "freeTierType": "Always Free"},
        {"service": "AWS Lambda", "usageType": "Request", "actualUsageAmount": 1700.0,
         "forecastedUsageAmount": 1750.0, "limit": 1000000.0, "unit": "Request", "freeTierType": "Always Free"},
        {"service": "Amazon Simple Queue Service", "usageType": "Requests", "actualUsageAmount": 2.0,
         "forecastedUsageAmount": 3.44, "limit": 1000000.0, "unit": "Requests", "freeTierType": "Always Free"},
    ],
}
SEPT_USAGE = {
    ("AWSGlue", "EU-Catalog-Request"): {"666802049426": Decimal("40")},
    ("AWSGlue", "EUC1-Catalog-Request"): {"857256953358": Decimal("14")},
    # BELOW AWS's own reading on the 30th (1,700), which can only mean a missed usage type.
    ("AWSLambda", "EU-Request-ARM"): {"666802049426": Decimal("1690")},
    # Right usage type, wrong service: SQS has no match in the export at all.
    ("AmazonS3", "EU-Requests-Tier1"): {"666802049426": Decimal("99999")},
}
f_title, f_body = build_freetier_close(SNAP, SEPT_USAGE, NAMES, dt.date(2026, 9, 30))
check("title names the closed month", f_title, ":free: AWS Free Tier: September 2026, final usage")
check("final usage is the export's total for the month", "54 of 1,000,000 Request used (<0.1% of the allowance)" in f_body, True)
check("never below AWS's own last reading", "1,700 of 1,000,000 Request used" in f_body, True)
check("per-account split still shown", "prd-nievah — 40" in f_body, True)
check(
    "an allowance the export cannot match falls back to AWS's last reading",
    "2 of 1,000,000 Requests used by 30 Sep · forecast 3.44" in f_body,
    True,
)
check("and says it is not the final count", "not the final count" in f_body, True)
check("matched lines carry no forecast", "forecast 52" not in f_body, True)
check("wrong-service usage is not absorbed", "99,999" not in f_body, True)
check("states that the allowance is org-wide", "organisation as a whole" in f_body, True)
check("within Chatbot's envelope", len(f_body) <= 8000, True)

OVER = {
    "savedAt": SAVED,
    "freeTierUsages": [
        {"service": "Amazon S3", "usageType": "Requests-Tier1", "actualUsageAmount": 1900.0,
         "forecastedUsageAmount": 1990.0, "limit": 2000.0, "unit": "Requests", "freeTierType": "12 Months Free"}
    ],
}
o_title, o_body = build_freetier_close(
    OVER, {("AmazonS3", "EU-Requests-Tier1"): {"666802049426": Decimal("2600")}}, NAMES, dt.date(2026, 9, 30)
)
# AWS's forecast on the 30th said 99.5%; the final count says the allowance ran out.
check("a breach only the final count shows is still shouted", o_title, ":rotating_light: AWS Free Tier: September 2026, 1 allowance EXCEEDED")
check("percentage over 100 shown", "130.0% of the allowance" in o_body, True)
check("and said to be billed", "the excess is billed" in o_body, True)

m_title, m_body = build_freetier_close(None, SEPT_USAGE, NAMES, dt.date(2026, 9, 30))
check("no snapshot for the month is said plainly", m_title, ":free: AWS Free Tier: September 2026, final usage unavailable")
check("and claims no usage figure", " of 1,000,000" not in m_body, True)
e_title, _ = build_freetier_close({"savedAt": SAVED, "freeTierUsages": []}, {}, NAMES, dt.date(2026, 9, 30))
check("a month with nothing consumed says so", e_title, ":free: AWS Free Tier: September 2026, nothing consumed")
check("a missing snapshot reads as None", load_freetier_snapshot(FakeS3({}), "b", "freetier", dt.date(2026, 9, 30)), None)

print("\nrun — which billing period each run reads, end to end")
os.environ.update(
    {
        "CUR_BUCKET": "b",
        "CUR_EXPORT_NAME": "exp",
        "CUR_PREFIX": "cur",
        "SNS_TOPIC_ARN": "arn:aws:sns:eu-west-1:000000000000:t",
        "FREETIER_PREFIX": "freetier",
    }
)


class FakeSNS:
    def __init__(self):
        self.published = []

    def publish(self, TopicArn, Subject, Message):  # noqa: N803 - boto3 kwarg names
        self.published.append(json.loads(Message)["content"])


class FakeOrg:
    def get_paginator(self, _op):
        class P:
            def paginate(self):
                yield {"Accounts": [{"Id": k, "Name": v} for k, v in NAMES.items()]}

        return P()


class FakeFreeTier:
    def __init__(self, usages):
        self.usages = usages

    def get_free_tier_usage(self, **_kwargs):
        return {"freeTierUsages": self.usages}


class ReadOnlyS3(FakeS3):
    def put_object(self, **_kwargs):
        raise RuntimeError("AccessDenied")


def invoke(now: dt.datetime, objects: dict, usages: list, s3_class=FakeS3):
    s3, sns = s3_class(dict(objects)), FakeSNS()
    clients = {"s3": s3, "sns": sns, "organizations": FakeOrg(), "freetier": FakeFreeTier(usages)}
    run(now, client=lambda name, **_kwargs: clients[name])
    return s3, sns.published


def period_file(month: str, rows: list[list[str]]) -> tuple[str, bytes]:
    return f"cur/exp/data/BILLING_PERIOD={month}/exp-00001.csv.gz", cur_gz(HEADER, rows)


def at_seven(year: int, month: int, day: int) -> dt.datetime:
    return dt.datetime(year, month, day, 7, 0, 3, tzinfo=dt.timezone.utc)


GLUE = {"service": "AWS Glue", "usageType": "Catalog-Request", "actualUsageAmount": 50.0,
        "forecastedUsageAmount": 52.0, "limit": 1000000.0, "unit": "Request", "freeTierType": "Always Free"}
SEPT_FILE = period_file(
    "2026-09",
    [
        ["666802049426", "2026-09-02T00:00:00.000Z", "AmazonS3", "1.00", "EUW1-Requests-Tier1", "10"],
        ["666802049426", "2026-09-30T00:00:00.000Z", "AmazonS3", "0.06", "EUW1-Requests-Tier1", "2"],
        ["857256953358", "2026-09-30T00:00:00.000Z", "AWSGlue", "0", "EU-Catalog-Request", "58"],
    ],
)
OCT_FILE = period_file("2026-10", [["666802049426", "2026-10-01T00:00:00.000Z", "AmazonS3", "9.99", "EUW1-Requests-Tier1", "1"]])
SEPT_SNAPSHOT = ("freetier/2026-09.json", json.dumps({"savedAt": SAVED, "freeTierUsages": [GLUE]}).encode())

s3_day, posts_day = invoke(at_seven(2026, 9, 30), dict([SEPT_FILE]), [GLUE])
check("a normal day reads its own month", s3_day.listed, ["cur/exp/data/BILLING_PERIOD=2026-09/"])
check("and posts the daily report", posts_day[0]["title"], ":moneybag: AWS daily cost — 2026-09-29")
check("today's rows already in the file stay out of it", "$1.00 month-to-date (1–29 Sep 2026)" in posts_day[0]["description"], True)
check("free tier is the API's own answer", posts_day[1]["title"], ":free: AWS Free Tier usage — September 2026")
check("the day's allowances are kept for the 1st", json.loads(s3_day.objects["freetier/2026-09.json"])["freeTierUsages"], [GLUE])

# OCT_FILE is present here on purpose. It is usually not there yet at 07:00 on the 1st, and
# when it is, its first hours are October's business, not September's close.
s3_1st, posts_1st = invoke(at_seven(2026, 10, 1), dict([SEPT_FILE, OCT_FILE, SEPT_SNAPSHOT]), [])
check("the 1st reads the closed month's file and nothing else", s3_1st.listed, ["cur/exp/data/BILLING_PERIOD=2026-09/"])
check("so it closes September instead of awaiting October", posts_1st[0]["title"], ":moneybag: AWS cost: September 2026, full month")
check("with all of September in it", "$1.06 for September 2026 (1–30 Sep 2026)" in posts_1st[0]["description"], True)
check("free tier: September against September's allowances", posts_1st[1]["title"], ":free: AWS Free Tier: September 2026, final usage")
check("final usage counted from the export", "58 of 1,000,000 Request used" in posts_1st[1]["description"], True)
check(
    "October's allowances are saved beside September's, not over them",
    sorted(k for k in s3_1st.objects if k.startswith("freetier/")),
    ["freetier/2026-09.json", "freetier/2026-10.json"],
)
check("September's snapshot is untouched", json.loads(s3_1st.objects["freetier/2026-09.json"])["savedAt"], SAVED)

DEC_FILE = period_file("2026-12", [["857256953358", "2026-12-31T00:00:00.000Z", "AWSGlue", "0.02", "EU-Catalog-Request", "7"]])
DEC_SNAPSHOT = ("freetier/2026-12.json", json.dumps({"savedAt": "2026-12-31T07:00:02+00:00", "freeTierUsages": [GLUE]}).encode())
s3_jan, posts_jan = invoke(at_seven(2027, 1, 1), dict([DEC_FILE, DEC_SNAPSHOT]), [])
check("1 January reads December of the previous year", s3_jan.listed, ["cur/exp/data/BILLING_PERIOD=2026-12/"])
check("and closes it", posts_jan[0]["title"], ":moneybag: AWS cost: December 2026, full month")
check("against December's allowances", posts_jan[1]["title"], ":free: AWS Free Tier: December 2026, final usage")
check("AWS's December reading is the floor", "50 of 1,000,000 Request used" in posts_jan[1]["description"], True)
check("January's allowances are saved under the new year", "freetier/2027-01.json" in s3_jan.objects, True)

_, posts_nosnap = invoke(at_seven(2026, 10, 1), dict([SEPT_FILE]), [])
check("a month with no snapshot says so on the 1st", posts_nosnap[1]["title"], ":free: AWS Free Tier: September 2026, final usage unavailable")

logging.disable(logging.WARNING)  # the handler logs the failed write with its traceback, by design
_, posts_ro = invoke(at_seven(2026, 9, 30), dict([SEPT_FILE]), [GLUE], s3_class=ReadOnlyS3)
logging.disable(logging.NOTSET)
check("a failed snapshot write costs neither report", [p["title"] for p in posts_ro], [
    ":moneybag: AWS daily cost — 2026-09-29",
    ":free: AWS Free Tier usage — September 2026",
])

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILURE(S):")
    for f in FAILURES:
        print("  - " + f)
    sys.exit(1)
print("all assertions passed")

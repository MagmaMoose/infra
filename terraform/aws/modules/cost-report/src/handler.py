"""Daily per-account AWS cost, posted to Slack #finance.

WHY THIS READS A FILE INSTEAD OF CALLING COST EXPLORER. The obvious implementation is
`ce:GetCostAndUsage`, and the first draft of this function was exactly that. The Cost
Explorer API costs **$0.01 per request** with no free allowance, so a once-a-day report is
$0.30 a month — against an organisation whose entire spend is around $0.00004 a month. The
reporting would have cost roughly seven thousand times the thing it reports on.

The free alternative, CloudWatch's `AWS/Billing` `EstimatedCharges`, was measured against
this account before it was rejected: every datapoint for every service in both accounts
reads exactly `0.0`, because that metric is rounded to whole cents. At this scale it cannot
say anything at all.

So the source is a Data Export (CUR 2.0) — a gzipped CSV that AWS writes to S3 daily at no
charge for the export itself, carrying unrounded per-line-item costs. Only the S3 bytes
bill, which for a few KB a day is a small fraction of a cent a month.

WHY THIS RUNS IN THE MANAGEMENT ACCOUNT. A member account's cost data covers only itself;
the organisation-wide view exists only in the management account (857256953358) or in an
account registered as a billing delegated administrator, and none is registered.

THE AMOUNTS ARE THE POINT. Every figure here rounds to $0.00 at two decimal places, so
`_money` keeps three significant figures on anything below a cent. That is what makes a
fraction-of-a-cent change visible at all, and it is the reason the CUR path was worth the
extra moving parts.
"""

from __future__ import annotations

import collections
import csv
import datetime as dt
import gzip
import io
import json
import logging
import os
import re
from decimal import Decimal, InvalidOperation

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Organizations is a global service reached through us-east-1. Deliberately not the
# function's own region, which would work here and break wherever this is instantiated next.
ORG_REGION = "us-east-1"

# The Free Tier API is single-region and free to call.
FREETIER_REGION = "us-east-1"

# CUR 2.0 column names, as selected by the export's query_statement in export.tf. Changing
# either side without the other silently produces a report of zeros, so they are named here
# in one place rather than inlined at the point of use.
COL_ACCOUNT = "line_item_usage_account_id"
COL_DATE = "line_item_usage_start_date"
COL_SERVICE = "line_item_product_code"
COL_COST = "line_item_unblended_cost"
COL_USAGE_TYPE = "line_item_usage_type"
COL_USAGE_AMOUNT = "line_item_usage_amount"

# A long tail of sub-cent services is noise. Everything past this is folded into one
# "+N more" line so a noisy account cannot push the others out of the 8,000 character
# envelope Chatbot allows for a custom notification.
MAX_SERVICES_PER_ACCOUNT = 10


def report_window(today: dt.date) -> tuple[dt.date, dt.date]:
    """(first day, last day) of the window a run on `today` reports on.

    ANCHORED TO THE REPORTED DAY, NOT TO TODAY. The reported day is yesterday, the last day
    with complete data, and month-to-date is the month that CONTAINS it: from its 1st up to
    and including it. On the 1st that is the whole of the previous month, so the 1st's report
    is that month's close. Anchoring to today instead made the 1st report on an empty new
    month (nothing has been billed in it at 07:00 UTC), and labelled every other day's window
    one day past the data it summed.
    """
    day = today - dt.timedelta(days=1)
    return day.replace(day=1), day


def _span(first: dt.date, last: dt.date) -> str:
    """`1–29 Sep 2026`, or `1 Oct 2026` when the window is a single day."""
    if first == last:
        return f"{last.day} {last:%b %Y}"
    return f"{first.day}–{last.day} {last:%b %Y}"


def _money(amount: Decimal) -> str:
    """Format USD so sub-cent amounts stay legible instead of rounding to $0.00."""
    if amount == 0:
        return "$0.00"
    # Sign outside the symbol: credits and refunds are negative, and "$-0.04" reads as a
    # malformed number where "-$0.04" reads as money owed back.
    sign = "-" if amount < 0 else ""
    magnitude = amount.copy_abs()
    if magnitude >= Decimal("0.01"):
        return f"{sign}${magnitude:,.2f}"
    # Three significant figures. `-Decimal(...).adjusted()` is the count of leading zeros
    # after the point, so precision widens exactly as far as the magnitude demands rather
    # than printing a fixed and usually wrong number of decimals.
    places = -magnitude.adjusted() + 2
    return f"{sign}${magnitude:.{places}f}"


def _account_names(org) -> dict[str, str]:
    """Map account id -> name. Degrades to bare ids; never fails the report."""
    names: dict[str, str] = {}
    try:
        for page in org.get_paginator("list_accounts").paginate():
            for acct in page["Accounts"]:
                names[acct["Id"]] = acct["Name"]
    except Exception:  # noqa: BLE001 - a missing friendly name must not cost us the report
        logger.warning("could not list org accounts; falling back to ids", exc_info=True)
    return names


def _norm_service(name: str) -> str:
    """Normalise a service name for comparison across the two APIs.

    GetFreeTierUsage says `Amazon Simple Queue Service`; the CUR calls the same thing
    `AWSQueueService`. Stripping the vendor prefix and all punctuation gets them to
    `simplequeueservice` and `queueservice`, which one-ends-with-the-other resolves.
    """
    flat = re.sub(r"[^a-z0-9]", "", name.lower())
    for prefix in ("amazon", "aws"):
        if flat.startswith(prefix) and len(flat) > len(prefix):
            return flat[len(prefix) :]
    return flat


def _service_matches(free_tier_service: str, cur_product_code: str) -> bool:
    a, b = _norm_service(free_tier_service), _norm_service(cur_product_code)
    return bool(a) and bool(b) and (a == b or a.endswith(b) or b.endswith(a))


def _usage_variants(raw: str) -> list[list[str]]:
    """The CUR usage type as token lists, with and without a leading region prefix.

    Rather than enumerate every region code AWS has (and every one it adds), the first
    segment is simply offered as optional — `EU-Request-ARM` is considered both
    `[eu, request, arm]` and `[request, arm]`, and the free-tier side matches whichever fits.
    """
    tokens = raw.strip().lower().split("-")
    variants = [tokens]
    if len(tokens) > 1:
        variants.append(tokens[1:])
    return variants


def _usage_matches(free_tier_type: str, cur_type: str) -> bool:
    """Whether a CUR usage type is an instance of a free-tier usage type.

    TOKEN PREFIX, NOT SUBSTRING, AND THAT DISTINCTION IS THE WHOLE FUNCTION. The CUR appends
    variant suffixes the Free Tier API does not use — `Request` appears as `EU-Request-ARM`
    on an arm64 Lambda, `Requests` as `EU-Requests-FIFO-Tier1` on a FIFO queue. Matching only
    a region PREFIX (the first implementation) missed every one of those, which is why nearly
    every line read "per-account split unavailable" against real data.

    A substring test would absorb the suffixes and then also match `requests-tier1` against
    Lambda's `request`, quietly filing S3 and SNS request counts under Lambda. Comparing whole
    tokens keeps `request` and `requests` distinct, and the caller pairs this with a service
    check so S3's `EU-Requests-Tier1` cannot land under SQS's allowance either.
    """
    wanted = free_tier_type.strip().lower().split("-")
    return any(variant[: len(wanted)] == wanted for variant in _usage_variants(cur_type))


def _data_prefix(prefix: str, export_name: str, month: dt.date) -> str:
    """Where Data Exports writes the CSV for the billing period containing `month`.

    The layout is fixed by AWS: `<prefix>/<export>/data/BILLING_PERIOD=YYYY-MM/`. The export
    is configured OVERWRITE_REPORT, so this directory holds one current copy rather than an
    accumulating pile — which is what keeps the S3 bill at a rounding error.
    """
    root = f"{prefix.strip('/')}/" if prefix.strip("/") else ""
    return f"{root}{export_name}/data/BILLING_PERIOD={month:%Y-%m}/"


def read_cur(s3, bucket: str, prefix: str) -> tuple[dict, dict, int]:
    """Aggregate the export into ({(date, account, service): cost}, {(service, usage_type): {account: qty}}, objects_read).

    Columns are looked up BY NAME through DictReader rather than by position. CUR column
    order is not contractual, and a positional reader would not fail on a reordered export —
    it would silently report the wrong numbers, which is the one outcome a cost report must
    never have.
    """
    totals: dict[tuple[str, str, str], Decimal] = collections.defaultdict(Decimal)
    # Usage QUANTITY, not cost, keyed by normalised usage type -> account. This is what lets
    # the free-tier report attribute an organisation-wide limit back to the account burning
    # it: GetFreeTierUsage reports the org total against the limit and has no account
    # dimension at all, so the split has to come from somewhere, and the CUR file is already
    # being downloaded for the cost report.
    usage: dict[tuple[str, str], dict[str, Decimal]] = collections.defaultdict(
        lambda: collections.defaultdict(Decimal)
    )
    objects = 0

    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if not obj["Key"].endswith(".csv.gz"):
                continue
            objects += 1
            body = s3.get_object(Bucket=bucket, Key=obj["Key"])["Body"].read()
            with gzip.open(io.BytesIO(body), "rt", newline="") as fh:
                for row in csv.DictReader(fh):
                    try:
                        cost = Decimal(row[COL_COST] or "0")
                    except (InvalidOperation, KeyError):
                        # One malformed line must not take the whole report down. It is
                        # logged rather than swallowed so a systematic problem is visible.
                        logger.warning("unparseable cost in %s: %r", obj["Key"], row.get(COL_COST))
                        continue
                    acct = row.get(COL_ACCOUNT) or "unknown"

                    # Usage is accumulated even when the line item cost nothing — which is
                    # the whole point for free-tier tracking, where every row of interest is
                    # by definition $0.00 until the limit is breached.
                    raw_type = row.get(COL_USAGE_TYPE) or ""
                    try:
                        qty = Decimal(row.get(COL_USAGE_AMOUNT) or "0")
                    except InvalidOperation:
                        qty = Decimal(0)
                    if raw_type and qty:
                        # Keyed on the RAW pair. Matching happens at report time against the
                        # free-tier record, which knows the service — without which SQS's
                        # `Requests` allowance would collect S3's and SNS's request counts too.
                        usage[(row.get(COL_SERVICE) or "", raw_type)][acct] += qty

                    if cost == 0:
                        continue
                    totals[((row.get(COL_DATE) or "")[:10], acct, row.get(COL_SERVICE) or "unknown")] += cost

    logger.info("read %d CUR object(s) under %s, %d nonzero rows", objects, prefix, len(totals))
    return dict(totals), {k: dict(v) for k, v in usage.items()}, objects


def build_report(rows: dict, names: dict[str, str], today: dt.date, delivered: bool) -> tuple[str, str]:
    """Return (title, description) in Slack markdown.

    Yesterday is the headline because this is a daily report and yesterday is the last day
    with complete data. Month-to-date rides alongside because a single day at this scale is
    frequently and legitimately zero, and "$0.00 yesterday" alone carries no information
    about whether anything is running at all.

    ON THE 1ST THE REPORT IS THE MONTH'S CLOSE. Yesterday is then the last day of the
    previous month, so month-to-date is that whole month (see report_window), and the
    message leads with the month rather than with one day of it.
    """
    month_start, yesterday = report_window(today)
    closing = today.day == 1
    ystr = yesterday.isoformat()

    if not delivered:
        # Distinguishable from a genuinely quiet day. The export is created and refreshed by
        # AWS on its own cadence and the first delivery can take up to 24 hours, so this is
        # the expected state exactly once — and saying so is better than reporting $0.00 and
        # letting someone conclude the stack is broken, or that it is working.
        return (
            ":hourglass_flowing_sand: AWS daily cost — awaiting first export",
            "The Cost and Usage export has not delivered its first file yet. AWS writes it "
            "within 24 hours of the export being created; this report will fill in by itself "
            "on the next run. No action needed unless it is still saying this tomorrow.",
        )

    day = collections.defaultdict(Decimal)
    mtd = collections.defaultdict(Decimal)
    for (date, acct, svc), cost in rows.items():
        if date == ystr:
            day[(acct, svc)] += cost
        # Bounded at BOTH ends. A refresh can already carry rows for today, which is not
        # over, and a window labelled as ending yesterday must not quietly include them.
        if month_start.isoformat() <= date <= ystr:
            mtd[(acct, svc)] += cost

    # Every account the organisation knows about, not merely those that spent. Silence in
    # this report must mean "spent nothing", never "was not asked about".
    account_ids = set(names) | {k[0] for k in day} | {k[0] for k in mtd}

    def total(bucket: dict, acct: str) -> Decimal:
        return sum((v for k, v in bucket.items() if k[0] == acct), Decimal(0))

    def amounts(on_day: Decimal, in_month: Decimal, label: str = "") -> str:
        # On the 1st the reported day is one figure in the org total; everything below it is
        # the month, because the month is what that report is about.
        if closing:
            return f"{_money(in_month)}{label}"
        return f"{_money(on_day)} yesterday · {_money(in_month)} MTD"

    org_day = _money(sum(day.values(), Decimal(0)))
    org_month = _money(sum(mtd.values(), Decimal(0)))
    window = _span(month_start, yesterday)
    if closing:
        title = f":moneybag: AWS cost: {yesterday:%B %Y}, full month"
        headline = f"*Org total* — {org_month} for {yesterday:%B %Y} ({window}) · {org_day} on {ystr}"
    else:
        title = f":moneybag: AWS daily cost — {ystr}"
        headline = f"*Org total* — {org_day} on {ystr} · {org_month} month-to-date ({window})"
    lines = [headline, ""]

    # Largest spender first, by month-to-date rather than yesterday, so the ordering does not
    # reshuffle every morning on sub-cent noise.
    for acct in sorted(account_ids, key=lambda a: (-total(mtd, a), a)):
        lines.append(
            f"*{names.get(acct, acct)}* · `{acct}`\n"
            f"{amounts(total(day, acct), total(mtd, acct), ' for the month')}"
        )

        # A service earns its line by having spent something in one of the two windows.
        services = {k[1] for k in day if k[0] == acct} | {k[1] for k in mtd if k[0] == acct}
        ranked = sorted(
            services,
            key=lambda s: (-mtd.get((acct, s), Decimal(0)), -day.get((acct, s), Decimal(0)), s),
        )

        if not ranked:
            lines.append("        _no charges_")
        for svc in ranked[:MAX_SERVICES_PER_ACCOUNT]:
            on_day = day.get((acct, svc), Decimal(0))
            in_month = mtd.get((acct, svc), Decimal(0))
            lines.append(f"        • {svc} — {amounts(on_day, in_month)}")
        if len(ranked) > MAX_SERVICES_PER_ACCOUNT:
            hidden = ranked[MAX_SERVICES_PER_ACCOUNT:]
            rest = sum((mtd.get((acct, s), Decimal(0)) for s in hidden), Decimal(0))
            suffix = "" if closing else " MTD"
            lines.append(f"        • _+{len(hidden)} more — {_money(rest)}{suffix}_")
        lines.append("")

    return title, "\n".join(lines).rstrip()


def _qty(amount: Decimal) -> str:
    """Usage quantities, which are counts far more often than fractions.

    Forecasts arrive from the Free Tier API as raw floats — 3.444444444444444 for an SQS
    request count — and printing that verbatim makes a report about round numbers look like
    a debugger dump. Fractions are cut to two places; genuine counts stay exact.
    """
    if amount == amount.to_integral_value():
        return f"{int(amount):,}"
    return f"{amount.quantize(Decimal('0.01')).normalize():,f}"


def build_freetier_report(usages, usage_by_account, names, today) -> tuple[str, str]:
    """Return (title, description) for the free-tier report.

    THE LIMIT IS ORGANISATION-WIDE AND THE API IS NOT. GetFreeTierUsage reports one number
    per service/usage-type for the whole organisation — correctly, because that is how AWS
    applies the allowance — and offers no account dimension. The per-account split beneath
    each limit therefore comes from the CUR file, matched on usage type, and is stated as
    unavailable rather than guessed when the match fails.

    Ordered by proportion of the limit FORECAST to be consumed, so the line most likely to
    start costing money is the first one read.
    """
    if not usages:
        return (
            ":free: AWS Free Tier usage — nothing consumed yet",
            f"No free-tier usage recorded for {today:%B %Y}. Either nothing has run this "
            "month, or none of what ran falls under a tracked free-tier allowance.",
        )

    def share(u) -> float:
        limit = u.get("limit") or 0
        return (u.get("forecastedUsageAmount") or u.get("actualUsageAmount") or 0) / limit if limit else 0.0

    ranked = sorted(usages, key=share, reverse=True)

    # The headline the whole report exists for: anything forecast to run past its allowance
    # is the thing that turns a $0.00 month into a bill.
    breaching = [u for u in ranked if share(u) >= 1.0]
    approaching = [u for u in ranked if 0.8 <= share(u) < 1.0]

    if breaching:
        title = f":rotating_light: AWS Free Tier — {len(breaching)} allowance forecast to be EXCEEDED"
    elif approaching:
        title = f":warning: AWS Free Tier — {len(approaching)} allowance above 80%"
    else:
        title = f":free: AWS Free Tier usage — {today:%B %Y}"

    lines = []
    if breaching:
        lines += [
            "*These will start billing this month unless usage drops:*",
            "",
        ]

    for u in ranked:
        pct = share(u) * 100
        actual = Decimal(str(u.get("actualUsageAmount") or 0))
        limit = Decimal(str(u.get("limit") or 0))
        forecast = Decimal(str(u.get("forecastedUsageAmount") or 0))
        lines.append(
            f"{_allowance_heading(u, pct)}\n"
            f"{_qty(actual)} of {_qty(limit)} {u.get('unit', '')} used · "
            f"forecast {_qty(forecast)} ({_pct_text(pct)} of the allowance)"
        )
        lines += _split_lines(_allowance_split(u, usage_by_account), names)
        lines.append("")

    lines.append("_Free Tier allowances apply to the organisation as a whole, not per account._")
    return title, "\n".join(lines).rstrip()


def _pct_text(pct: float) -> str:
    """A share of an allowance, as text.

    54 requests against a million is 0.0054%, which prints as "0.0%" and reads as "nothing is
    using this" — true here, but the same rounding would hide the last decade of headroom on
    an allowance that mattered. Below a tenth of a percent the number is replaced by a bound
    rather than rounded into a lie.
    """
    return f"{pct:.1f}%" if pct >= 0.1 or pct == 0 else "<0.1%"


def _allowance_heading(u: dict, pct: float) -> str:
    marker = ":rotating_light: " if pct >= 100 else ":warning: " if pct >= 80 else ""
    detail = f"{u['service']}"
    if u.get("usageType"):
        detail += f" · {u['usageType']}"
    return f"{marker}*{detail}* ({u.get('freeTierType', 'Free Tier')})"


def _allowance_split(u: dict, usage_by_account: dict) -> dict[str, Decimal]:
    """The per-account usage, from the CUR, of one free-tier allowance.

    Summed across every CUR usage type that is an instance of the allowance — one allowance
    routinely covers several (SQS `Requests` spans `EU-Requests-Tier1`,
    `EU-Requests-FIFO-Tier1` and the eu-central-1 equivalents).
    """
    split: dict[str, Decimal] = collections.defaultdict(Decimal)
    for (cur_service, cur_type), per_account in usage_by_account.items():
        if _service_matches(u.get("service") or "", cur_service) and _usage_matches(
            u.get("usageType") or "", cur_type
        ):
            for acct, qty in per_account.items():
                split[acct] += qty
    return dict(split)


def _split_lines(split: dict[str, Decimal], names: dict[str, str]) -> list[str]:
    if not split:
        # Said out loud. A silently missing split reads as "one account uses all of it".
        return ["        • _per-account split unavailable for this usage type_"]
    return [
        f"        • {names.get(acct, acct)} — {_qty(qty)}"
        for acct, qty in sorted(split.items(), key=lambda kv: (-kv[1], kv[0]))
    ]


def build_freetier_close(snapshot, usage_by_account, names, month_end: dt.date) -> tuple[str, str]:
    """Return (title, description) for the 1st: the closed month's final usage per allowance.

    GETFREETIERUSAGE CANNOT ANSWER THIS. It takes no period at all (its only inputs are
    filter, maxResults and nextToken) and describes the CURRENT month, so on the 1st it
    reports a month a few hours old, which is usually nothing. The answer is assembled from
    the two sources that still know about the closed month:

      * the allowances (limit, unit, type) from the snapshot that month's last run saved,
        see save_freetier_snapshot;
      * the usage from that month's export, already read for the cost report and matched to
        each allowance exactly as the per-account split is.

    The export's total is never reported below AWS's own last reading. Usage only accrues
    over a month, so AWS's reading is a floor, and a total under it means the matcher missed
    a usage type. Under-reporting is the costly direction for a report whose job is to show a
    breach. When the export matches nothing at all for an allowance, the line says so and
    shows AWS's last reading and forecast instead of a made-up final figure.
    """
    month = f"{month_end:%B %Y}"
    if snapshot is None:
        return (
            f":free: AWS Free Tier: {month}, final usage unavailable",
            f"No free-tier allowances were saved during {month}, so its final usage cannot be "
            "measured against them: the Free Tier API only describes the current month. Every "
            "daily run saves a copy, so next month's close will have one.",
        )
    usages = snapshot.get("freeTierUsages") or []
    if not usages:
        return (
            f":free: AWS Free Tier: {month}, nothing consumed",
            f"No free-tier usage was recorded for {month}.",
        )

    saved = dt.date.fromisoformat(snapshot["savedAt"][:10])
    lines_by_share = []
    for u in usages:
        limit = Decimal(str(u.get("limit") or 0))
        reading = Decimal(str(u.get("actualUsageAmount") or 0))
        forecast = Decimal(str(u.get("forecastedUsageAmount") or 0))
        of_limit = f"of {_qty(limit)} {u.get('unit', '')} used"
        split = _allowance_split(u, usage_by_account)
        if split:
            final = max(sum(split.values(), Decimal(0)), reading)
            share = float(final / limit) if limit else 0.0
            used = f"{_qty(final)} {of_limit} ({_pct_text(share * 100)} of the allowance)"
            below = _split_lines(split, names)
        else:
            share = float(max(reading, forecast) / limit) if limit else 0.0
            used = (
                f"{_qty(reading)} {of_limit} by {saved.day} {saved:%b} · "
                f"forecast {_qty(forecast)} ({_pct_text(share * 100)} of the allowance)"
            )
            below = ["        • _no match in the export, so this is AWS's last reading, not the final count_"]
        lines_by_share.append((share, [f"{_allowance_heading(u, share * 100)}\n{used}", *below, ""]))

    # Same ordering as the daily report: the allowance closest to its limit is read first.
    lines_by_share.sort(key=lambda item: item[0], reverse=True)
    exceeded = sum(1 for share, _ in lines_by_share if share >= 1.0)
    approaching = sum(1 for share, _ in lines_by_share if 0.8 <= share < 1.0)

    if exceeded:
        title = f":rotating_light: AWS Free Tier: {month}, {exceeded} allowance EXCEEDED"
    elif approaching:
        title = f":warning: AWS Free Tier: {month}, {approaching} allowance above 80%"
    else:
        title = f":free: AWS Free Tier: {month}, final usage"

    lines = []
    if exceeded:
        lines += [f"*These ran past their allowance in {month_end:%B}, so the excess is billed:*", ""]
    for _, block in lines_by_share:
        lines += block
    lines.append("_Free Tier allowances apply to the organisation as a whole, not per account._")
    return title, "\n".join(lines).rstrip()


def _snapshot_key(prefix: str, month: dt.date) -> str:
    return f"{prefix.strip('/')}/{month:%Y-%m}.json"


def save_freetier_snapshot(s3, bucket: str, prefix: str, now: dt.datetime, usages: list) -> None:
    """Keep this month's free-tier allowances for the report on the 1st.

    Once a month has closed, AWS no longer says what its allowances were, so the report that
    closes it reads them from here. One object per billing period, overwritten by every run,
    so the copy the 1st reads is the one written by the closed month's last run. Versioning is
    off on this bucket, so overwriting keeps one object rather than thirty, and the lifecycle
    rule that expires the export files expires these too.
    """
    s3.put_object(
        Bucket=bucket,
        Key=_snapshot_key(prefix, now.date()),
        Body=json.dumps({"savedAt": now.isoformat(), "freeTierUsages": usages}).encode(),
        ContentType="application/json",
    )


def load_freetier_snapshot(s3, bucket: str, prefix: str, month: dt.date) -> dict | None:
    """The snapshot saved during `month`'s billing period, or None when no run saved one."""
    try:
        body = s3.get_object(Bucket=bucket, Key=_snapshot_key(prefix, month))["Body"].read()
    except s3.exceptions.NoSuchKey:
        return None
    return json.loads(body)


def _publish(sns, topic_arn: str, title: str, description: str) -> None:
    """One Chatbot custom notification. `client-markdown` is what makes Slack render the
    bold and bullets rather than printing the asterisks literally."""
    sns.publish(
        TopicArn=topic_arn,
        # Chatbot reads Message; Subject is what an email subscriber on the topic would see.
        Subject=title[:100],
        Message=json.dumps(
            {
                "version": "1.0",
                "source": "custom",
                "content": {
                    "textType": "client-markdown",
                    "title": title,
                    "description": description,
                },
            }
        ),
    )


def handler(event, context):  # noqa: ARG001 - Lambda signature
    """EventBridge Scheduler target.

    TWO MESSAGES, ONE INVOCATION. Spend and free-tier headroom answer different questions —
    "what did this cost" against "what is about to start costing" — and at this organisation's
    scale the second is by far the more useful of the two, since everything is $0.00 precisely
    because it sits inside an allowance. They are published separately so each reads as its
    own Slack message rather than one wall of text, but they share a run because they share
    the CUR download, which is the only expensive part of either.
    """
    # Taken here rather than from the event, so a manual re-invoke reproduces today's report
    # rather than whatever the schedule last carried.
    return run(dt.datetime.now(dt.timezone.utc))


def run(now: dt.datetime, client=None) -> dict:
    """One report run as of `now` (UTC). `client` stands in for boto3.client in the tests."""
    client = client or boto3.client
    bucket = os.environ["CUR_BUCKET"]
    export_name = os.environ["CUR_EXPORT_NAME"]
    prefix = os.environ.get("CUR_PREFIX", "")
    topic_arn = os.environ["SNS_TOPIC_ARN"]
    snapshot_prefix = os.environ.get("FREETIER_PREFIX", "freetier")

    today = now.date()
    _, yesterday = report_window(today)

    # Pinned to the bucket's own region rather than the function's. The billing plane lives
    # in us-east-1 while this runs in eu-west-1, and while S3 would redirect a mismatched
    # client, the redirect costs a round trip on every object and fails outright for some
    # request shapes. Naming it is cheaper than relying on the fallback.
    s3 = client("s3", region_name=os.environ.get("CUR_BUCKET_REGION") or None)

    # ONE billing period: the one the reported day belongs to. On the 1st that is the month
    # that has just closed, which is everything the 1st's report is about, and the new month's
    # period is not read at all. At 07:00 on the 1st it usually does not exist yet (AWS starts
    # it with the first refresh after the month begins), and judging delivery from that empty
    # directory is what made the 1st report "awaiting first export" with a full month on disk.
    rows, usage, objects = read_cur(s3, bucket, _data_prefix(prefix, export_name, yesterday))

    names = _account_names(client("organizations", region_name=ORG_REGION))
    sns = client("sns")

    cost_title, cost_body = build_report(rows, names, today, delivered=objects > 0)
    _publish(sns, topic_arn, cost_title, cost_body)

    # Free-tier usage comes from its own API rather than from CUR: the ALLOWANCE and the
    # forecast against it are AWS's numbers, and re-deriving them from line items would be
    # guessing at limits AWS already publishes. GetFreeTierUsage is free to call.
    try:
        ft = client("freetier", region_name=FREETIER_REGION)
        usages, token = [], None
        while True:
            resp = ft.get_free_tier_usage(**{"nextToken": token} if token else {})
            usages += resp.get("freeTierUsages", [])
            token = resp.get("nextToken")
            if not token:
                break

        # Best effort. Only the month's last successful save is ever read, and a month with
        # none at all says so in its closing report, so one failed write must not cost
        # today's report.
        try:
            save_freetier_snapshot(s3, bucket, snapshot_prefix, now, usages)
        except Exception:  # noqa: BLE001
            logger.warning("could not save the free-tier snapshot", exc_info=True)

        if today.day == 1:
            snapshot = load_freetier_snapshot(s3, bucket, snapshot_prefix, yesterday)
            ft_title, ft_body = build_freetier_close(snapshot, usage, names, yesterday)
        else:
            ft_title, ft_body = build_freetier_report(usages, usage, names, today)
        _publish(sns, topic_arn, ft_title, ft_body)
    except Exception:  # noqa: BLE001 - the cost report is already out; do not lose it too
        logger.exception("free-tier report failed; cost report was published")
        raise

    logger.info("published both reports (%d cost rows, %d usage types)", len(rows), len(usage))
    return {"ok": True, "cost_rows": len(rows), "usage_types": len(usage)}

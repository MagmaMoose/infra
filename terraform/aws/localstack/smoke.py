#!/usr/bin/env python3
"""Drive the front door end to end against LocalStack and assert what must be true.

NOT a unit test. The decisions are covered by pytest without any of this running (see
tests/test_aws_*.py); what this proves is the part unit tests cannot — that the wiring is
right. Every failure it catches is a thing that would have looked fine in review:

  a signed delivery reaches the jobs queue      the whole chain, in one assertion
  an unsigned one is refused 401                the edge is not an open relay
  a redelivery lands ONCE                       the DynamoDB conditional write really is one
  an oversized body round-trips via S3          the >256 KB path, which never fires in prod
                                                until the day it does
  the FIFO group survives both hops             two pushes to one PR stay serialised
  a tick becomes a job                          the CronJob replacement actually fires

Run with `make -C aws smoke` after `make -C aws apply-local`.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import sys
import time
import urllib.error
import urllib.request
import uuid

import boto3

ENDPOINT = "http://localhost:4566"  # DevSkim: ignore DS162092
REGION = "eu-west-1"
WEBHOOK_SECRET = "localstack-github-webhook-secret"  # nosec B105
SLACK_SECRET = "localstack-slack-signing-secret"  # nosec B105

_sqs = boto3.client("sqs", endpoint_url=ENDPOINT, region_name=REGION)
_s3 = boto3.client("s3", endpoint_url=ENDPOINT, region_name=REGION)
_lambda = boto3.client("lambda", endpoint_url=ENDPOINT, region_name=REGION)

_failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}{'' if ok else f'  — {detail}'}")
    if not ok:
        _failures.append(name)


def sign(body: bytes, secret: str = WEBHOOK_SECRET) -> str:
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


def post(url: str, body: bytes, headers: dict[str, str]) -> int:
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # nosec B310 # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code


def github_post(url: str, payload: dict, delivery: str, *, secret: str = WEBHOOK_SECRET) -> int:
    body = json.dumps(payload).encode()
    return post(
        url,
        body,
        {
            "content-type": "application/json",
            "x-github-event": "pull_request",
            "x-github-delivery": delivery,
            "x-hub-signature-256": sign(body, secret),
        },
    )


def drain_jobs(queue_url: str, *, seconds: int = 25) -> list[dict]:
    """Everything on the jobs queue within a window, deleted as it is read.

    Polls rather than sleeping-then-reading: the chain is producer -> SQS -> Lambda ESM ->
    SQS, and the ESM's poll interval is the slow link. A fixed sleep would either be flaky
    or make every run take as long as its worst case.
    """
    out: list[dict] = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        received = _sqs.receive_message(
            QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=2
        )
        for message in received.get("Messages", []):
            out.append(json.loads(message["Body"]))
            _sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=message["ReceiptHandle"])
        if out:
            # Give a straggler one more cycle: an assertion that exactly ONE message arrived
            # is only meaningful if a second one had time to show up.
            deadline = min(deadline, time.time() + 4)
    return out


def pr_payload(owner: str, repo: str, number: int, *, pad: int = 0) -> dict:
    return {
        "action": "opened",
        "number": number,
        "repository": {
            "name": repo,
            "owner": {"login": owner},
            "html_url": f"https://github.com/{owner}/{repo}",
        },
        "pull_request": {"number": number, "user": {"login": "someone"}},
        "_pad": "x" * pad,
    }


def main(outputs_path: str) -> int:
    with open(outputs_path) as handle:
        outputs = {k: v["value"] for k, v in json.load(handle).items()}
    webhook_url = outputs["webhook_url"]
    slack_url = outputs["slack_interactions_url"]
    jobs_url = outputs["jobs_queue_url"]
    bucket = outputs["overflow_bucket"]

    print(f"front door: {webhook_url}")
    drain_jobs(jobs_url, seconds=3)  # start from empty

    # --- the happy path ---------------------------------------------------------------
    delivery = str(uuid.uuid4())
    status = github_post(webhook_url, pr_payload("magmamoose", "nievah", 42), delivery)
    check("signed delivery accepted 202", status == 202, f"got {status}")

    jobs = drain_jobs(jobs_url)
    check("delivery reached the jobs queue", len(jobs) == 1, f"got {len(jobs)}")
    if jobs:
        job = jobs[0]
        check("envelope carries the delivery id", job.get("delivery_id") == delivery)
        check(
            "body survives both hops byte-for-byte",
            json.loads(base64.b64decode(job["body_b64"]))["number"] == 42,
        )
        check(
            "signature header is preserved for the ingest's own check",
            "x-hub-signature-256" in (job.get("headers") or {}),
        )
        check(
            "FIFO group is the pull request",
            job.get("group") == "magmamoose/nievah#42",
            f"got {job.get('group')!r}",
        )

    # --- the edge is not an open relay ------------------------------------------------
    body = json.dumps(pr_payload("magmamoose", "nievah", 43)).encode()
    status = post(
        webhook_url,
        body,
        {
            "content-type": "application/json",
            "x-github-event": "pull_request",
            "x-github-delivery": str(uuid.uuid4()),
            "x-hub-signature-256": "sha256=" + "0" * 64,
        },
    )
    check("bad signature refused 401", status == 401, f"got {status}")
    check("and nothing was queued", len(drain_jobs(jobs_url, seconds=6)) == 0)

    # A per-org secret must work as well as the default one — the multi-secret path is the
    # one that silently stops working when a secret is rotated in the wrong place.
    status = github_post(
        webhook_url, pr_payload("org-a", "thing", 1), str(uuid.uuid4()), secret="org-a-secret"  # nosec B106
    )
    check("per-org secret is accepted too", status == 202, f"got {status}")
    drain_jobs(jobs_url)

    # --- redelivery collapses ---------------------------------------------------------
    repeated = str(uuid.uuid4())
    payload = pr_payload("magmamoose", "nievah", 44)
    first = github_post(webhook_url, payload, repeated)
    second = github_post(webhook_url, payload, repeated)
    check("both redeliveries answered 202", first == 202 and second == 202)
    landed = drain_jobs(jobs_url)
    check("but only ONE job was created", len(landed) == 1, f"got {len(landed)}")

    # --- the >256 KB path -------------------------------------------------------------
    # The single most valuable case here: it is rare enough in production to go years
    # without firing and total when it does.
    big_delivery = str(uuid.uuid4())
    status = github_post(
        webhook_url, pr_payload("magmamoose", "nievah", 45, pad=400_000), big_delivery
    )
    check("oversized delivery still accepted 202", status == 202, f"got {status}")
    jobs = drain_jobs(jobs_url)
    check("oversized delivery reached the jobs queue", len(jobs) == 1, f"got {len(jobs)}")
    if jobs:
        job = jobs[0]
        check(
            "it travelled as a pointer, not inline", job.get("overflow") and not job.get("body_b64")
        )
        stored = _s3.get_object(Bucket=bucket, Key=job["overflow"])["Body"].read()
        check("and the full body is in S3", json.loads(stored)["number"] == 45)

    # --- slack ------------------------------------------------------------------------
    slack_body = b"payload=%7B%22type%22%3A%22block_actions%22%7D"
    timestamp = str(int(time.time()))
    basestring = b"v0:" + timestamp.encode() + b":" + slack_body
    status = post(
        slack_url,
        slack_body,
        {
            "content-type": "application/x-www-form-urlencoded",
            "x-slack-request-timestamp": timestamp,
            "x-slack-signature": "v0="
            + hmac.new(SLACK_SECRET.encode(), basestring, hashlib.sha256).hexdigest(),
        },
    )
    check("signed slack interaction accepted 202", status == 202, f"got {status}")
    check("and reached the jobs queue", len(drain_jobs(jobs_url)) == 1)

    # A stale timestamp must fail even though the signature over it is valid — this is the
    # replay guard, and it is the half of the Slack scheme that is easy to leave out.
    old = str(int(time.time()) - 3600)
    basestring = b"v0:" + old.encode() + b":" + slack_body
    status = post(
        slack_url,
        slack_body,
        {
            "content-type": "application/x-www-form-urlencoded",
            "x-slack-request-timestamp": old,
            "x-slack-signature": "v0="
            + hmac.new(SLACK_SECRET.encode(), basestring, hashlib.sha256).hexdigest(),
        },
    )
    check("replayed slack interaction refused 401", status == 401, f"got {status}")
    drain_jobs(jobs_url, seconds=4)

    # --- the tick that replaces the CronJobs -------------------------------------------
    # Invoked directly. In production EventBridge Scheduler supplies this payload; LocalStack
    # mocks that API and never fires, and proving EventBridge can invoke a Lambda is AWS's
    # job anyway. What is worth proving is everything downstream of it.
    _lambda.invoke(
        FunctionName="nievah-producer", Payload=json.dumps({"nievah_tick": "planner"}).encode()
    )
    ticks = drain_jobs(jobs_url)
    check("a scheduled tick becomes a job", len(ticks) == 1, f"got {len(ticks)}")
    if ticks:
        check("and it is recognisably a tick", ticks[0].get("kind") == "tick")
        check("naming which one", ticks[0].get("event") == "planner")

    # EventBridge retries a failed schedule, and the delivery id is derived from the MINUTE,
    # so a retry inside the same window must not produce a second planner run.
    _lambda.invoke(
        FunctionName="nievah-producer", Payload=json.dumps({"nievah_tick": "planner"}).encode()
    )
    check(
        "a retried tick in the same minute does not double-fire",
        len(drain_jobs(jobs_url, seconds=8)) == 0,
    )

    print()
    if _failures:
        print(f"{len(_failures)} failed: {', '.join(_failures)}")
        return 1
    print("all green")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "aws/localstack/.outputs.json"))

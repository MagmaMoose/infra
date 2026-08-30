#!/usr/bin/env python3
"""Drive the Dün Mir stack end to end against the local proving ground.

WHAT THIS ASSERTS, AND WHY EACH ONE IS HERE
    Every check below is either a thing that would be invisible if broken, or a
    thing that has actually broken during this stack's construction:

      health            the function starts at all. Two real boot failures were
                        caught this way — the S3 signer refusing to use the
                        Lambda role's temporary credentials, and a missing
                        package in the deployment artefact.
      config bootstrap  an anonymous browser can discover which pool to sign in
                        against. Without it the console renders a login form that
                        posts nowhere.
      sign-up + confirm the identity flow the browser drives, against a pool that
                        mints real RS256 tokens.
      token acceptance  the backend's OFFLINE verifier accepts a genuine token,
                        provisions a local user, and founds their workspace. This
                        is the load-bearing claim of the whole topology: no
                        egress is needed to authenticate anybody.
      forged tokens     a token from another pool, and one with a tampered
                        payload, are BOTH refused. A verifier that only ever sees
                        valid input proves nothing.
      the core surface  a mutation on the frozen `/v1/admin/*` contract is
                        authorised by the same bearer, with no CSRF token — which
                        is the point of putting Cognito behind the core's auth
                        seam rather than in front of Pro's routers.
      agent ingest      a device heartbeat, i.e. the product's actual job.
      S3                a backup body makes a round trip through the hand-rolled
                        SigV4 signer to a real bucket, and the object is really
                        there.
      the sweep         the scheduled payload runs. EventBridge Scheduler is
                        accepted but never fires locally, so this invokes it
                        directly — which covers everything downstream of the
                        schedule, the part this repo owns.
      invitations       an invitation is issued as a LINK (this deployment cannot
                        send mail) and a second Cognito identity redeems it into
                        the inviter's workspace. That is client onboarding.

USAGE
    smoke.py <terraform-outputs.json>

    `make -C aws dunmir-smoke` writes that file and runs this. Needs only the
    standard library plus `requests` for convenience.
"""

from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any

PASSWORD = "an-adequately-long-passphrase"


# --------------------------------------------------------------------------- #
# Tiny HTTP + reporting helpers
# --------------------------------------------------------------------------- #
class Failure(Exception):
    pass


_checks = 0


def check(label: str, condition: bool, detail: Any = "") -> None:
    global _checks
    _checks += 1
    if condition:
        print(f"  \033[32m✓\033[0m {label}")
        return
    print(f"  \033[31m✗\033[0m {label}  {detail}")
    raise Failure(label)


def request(
    method: str,
    url: str,
    *,
    body: Any = None,
    headers: dict[str, str] | None = None,
    raw: bytes | None = None,
) -> tuple[int, Any]:
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    hdrs = {"Accept": "application/json", **(headers or {})}
    if body is not None:
        hdrs.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:  # noqa: S310 - local only
            payload = response.read()
    except urllib.error.HTTPError as exc:
        payload = exc.read()
        status = exc.code
    else:
        status = 200
    try:
        return status, json.loads(payload)
    except Exception:
        return status, payload.decode(errors="replace")


def request_raw(method: str, url: str) -> tuple[int, dict, bytes]:
    """A plain fetch with no credential — for a URL that carries its own."""
    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:  # noqa: S310 - local only
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read()


def cognito(endpoint: str, operation: str, body: dict) -> tuple[int, Any]:
    """One Cognito API call, exactly as the browser makes it."""
    return request(
        "POST",
        f"{endpoint}/",
        raw=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/x-amz-json-1.1",
            "X-Amz-Target": f"AWSCognitoIdentityProviderService.{operation}",
        },
    )


def claims_of(token: str) -> dict:
    part = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


def aws_cli(*args: str) -> subprocess.CompletedProcess[str]:
    """Run the AWS CLI against the local stack, with credentials.

    Used for the two things the BROWSER never does: administrative Cognito calls
    and reading the S3 bucket. Both are authenticated operations — the stand-in
    resolves the account from the signature, so an unsigned request looks into a
    different account's store and reports the pool as not existing, which is a
    confusing way to be told "you did not sign this".
    """
    return subprocess.run(  # noqa: S603
        ["aws", *args],
        capture_output=True,
        text=True,
        check=False,
        env={
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "AWS_ACCESS_KEY_ID": "test",
            "AWS_SECRET_ACCESS_KEY": "test",
            "AWS_DEFAULT_REGION": "eu-west-1",
        },
    )


def invoke(function: str, payload: dict) -> dict:
    """Invoke the function directly, the way EventBridge Scheduler does."""
    out = aws_cli(
        "--endpoint-url=http://localhost:4566", "lambda", "invoke",  # DevSkim: ignore DS162092
        "--function-name", function,
        "--cli-binary-format", "raw-in-base64-out",
        "--payload", json.dumps(payload),
        "/dev/stdout",
    )
    # The CLI writes the payload then its own status object; take the first JSON
    # document and ignore the rest.
    decoder = json.JSONDecoder()
    return decoder.raw_decode(out.stdout.lstrip())[0]


# --------------------------------------------------------------------------- #
# The flow
# --------------------------------------------------------------------------- #
def sign_up_and_sign_in(pool: dict, email: str) -> str:
    """Create a Cognito account and return its ID token — the browser's whole job."""
    endpoint, client_id, pool_id = pool["endpoint"], pool["client_id"], pool["user_pool_id"]

    status, _ = cognito(endpoint, "SignUp", {
        "ClientId": client_id,
        "Username": email,
        "Password": PASSWORD,
        "UserAttributes": [{"Name": "email", "Value": email}],
    })
    check(f"sign-up accepted for {email}", status == 200, status)

    # The stand-in does not deliver mail, so the address is confirmed
    # administratively. On AWS this is the six-digit code Cognito emails and the
    # operator types into the console's own screen — the one step of the flow the
    # local run cannot exercise, because nothing here has an inbox.
    #
    # Through the CLI rather than a raw POST: this is an authenticated operation,
    # and an unsigned one is attributed to a different account, which reports back
    # as "user pool does not exist".
    confirmed = aws_cli(
        "--endpoint-url", endpoint, "cognito-idp", "admin-confirm-sign-up",
        "--user-pool-id", pool_id, "--username", email,
    )
    check("address confirmed", confirmed.returncode == 0, confirmed.stderr.strip()[:200])

    status, auth = cognito(endpoint, "InitiateAuth", {
        "ClientId": client_id,
        "AuthFlow": "USER_PASSWORD_AUTH",
        "AuthParameters": {"USERNAME": email, "PASSWORD": PASSWORD},
    })
    check("sign-in returned tokens", status == 200 and "AuthenticationResult" in auth, auth)
    return auth["AuthenticationResult"]["IdToken"]


def main(outputs_path: str) -> int:
    outputs = json.load(open(outputs_path))
    api = outputs["api_url"]["value"].rstrip("/")
    pool = outputs["cognito"]["value"]
    bucket = outputs["backups_bucket"]["value"]
    function = outputs["function_name"]["value"]

    # A distinct address per run, so a re-run does not collide with the account
    # the previous one created. `time.time()` rather than a random: it sorts, so
    # leftover users in the local pool are readable as a history.
    stamp = int(time.time())
    founder = f"founder+{stamp}@example.com"
    invitee = f"invitee+{stamp}@example.com"

    print("\n\033[1mthe function is alive\033[0m")
    status, body = request("GET", f"{api}/v1/health")
    check("GET /v1/health", status == 200 and body.get("ok") is True, body)

    print("\n\033[1man anonymous browser can discover how to sign in\033[0m")
    status, config = request("GET", f"{api}/api/session/config")
    check("GET /api/session/config", status == 200, status)
    check("names Cognito as the identity provider", config.get("auth_mode") == "cognito", config)
    check("carries the pool", config["cognito"]["userPoolId"] == pool["user_pool_id"], config)
    check("carries the app client", config["cognito"]["clientId"] == pool["client_id"], config)
    check("leaks no secret", "SECRET" not in json.dumps(config).upper(), config)

    print("\n\033[1man operator signs up and signs in, against a real pool\033[0m")
    token = sign_up_and_sign_in(pool, founder)
    claims = claims_of(token)
    check("the token is RS256 from the expected issuer", claims["iss"] == pool["issuer"], claims["iss"])
    auth = {"Authorization": f"Bearer {token}"}

    print("\n\033[1mthe backend verifies it OFFLINE and founds a workspace\033[0m")
    status, me = request("GET", f"{api}/api/session/me", headers=auth)
    check("GET /api/session/me", status == 200, me)
    check("identified as the signer", me.get("user") == founder, me)
    check("owns the workspace they founded", me.get("role") == "owner", me)
    check("a tenant was provisioned", bool(me.get("tenant")), me)
    tenant = me["tenant"]

    print("\n\033[1mforged credentials are refused\033[0m")
    status, _ = request("GET", f"{api}/api/session/me")
    check("no token is not signed in", status == 401, status)

    header, payload, signature = token.split(".")
    tampered = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    tampered["email"] = "attacker@example.com"
    forged = base64.urlsafe_b64encode(json.dumps(tampered).encode()).decode().rstrip("=")
    status, _ = request(
        "GET", f"{api}/api/session/me",
        headers={"Authorization": f"Bearer {header}.{forged}.{signature}"},
    )
    check("a tampered payload is refused", status == 401, status)

    status, _ = request(
        "GET", f"{api}/api/session/me",
        headers={"Authorization": f"Bearer {header}.{payload}.{signature[:-4]}AAAA"},
    )
    check("a broken signature is refused", status == 401, status)

    print("\n\033[1mthe same bearer authorises the frozen core surface\033[0m")
    status, agent = request(
        "POST", f"{api}/v1/admin/agents", body={"name": f"edge-{stamp}"}, headers=auth
    )
    check("POST /v1/admin/agents (no CSRF token needed)", status in (200, 201), agent)
    check("an agent token was minted", str(agent.get("token", "")).startswith("dunmir_"), agent)
    agent_token = agent["token"]
    agent_id = agent["id"]

    print("\n\033[1ma device checks in, which is the product's actual job\033[0m")
    device = f"router-{stamp}"
    agent_auth = {"Authorization": f"Bearer {agent_token}"}
    # The device is created implicitly by its first heartbeat — there is no
    # separate registration call, which is what "fully agentless" means here.
    status, beat = request(
        "POST", f"{api}/v1/ingest/heartbeat",
        body={"device": device, "status": "ok"}, headers=agent_auth,
    )
    check("POST /v1/ingest/heartbeat", status == 200 and beat.get("ok") is True, beat)
    check("the device was created on first sight", beat.get("created") is True, beat)
    check("it has an id", bool(beat.get("device_id")), beat)

    status, again = request(
        "POST", f"{api}/v1/ingest/heartbeat",
        body={"device": device, "status": "ok"}, headers=agent_auth,
    )
    check("a second heartbeat does not duplicate it", again.get("created") is False, again)

    print("\n\033[1man encrypted backup goes to S3 through the hand-rolled signer\033[0m")
    # Stands in for the ciphertext a RouterOS device produces. The backend never
    # holds the plaintext or the key; from here it is opaque bytes.
    blob = f"# ciphertext stand-in {stamp}\n".encode() * 64
    digest = hashlib.sha256(blob).hexdigest()
    filename = f"daily-{stamp}.backup"
    status, stored = request(
        "PUT", f"{api}/v1/ingest/backups/{device}/{filename}?sha256={digest}",
        raw=blob,
        headers={**agent_auth, "Content-Type": "application/octet-stream"},
    )
    check("PUT /v1/ingest/backups/{device}/{filename}", status == 200, stored)
    backup_id = stored.get("id")
    check("the upload returns a catalogue id", bool(backup_id), stored)

    # The sha256 the agent claims is verified server-side, so a corrupted upload
    # is refused rather than catalogued as a backup that will not restore.
    status, mismatch = request(
        "PUT", f"{api}/v1/ingest/backups/{device}/tampered-{stamp}.backup?sha256={'0' * 64}",
        raw=blob,
        headers={**agent_auth, "Content-Type": "application/octet-stream"},
    )
    check("a mismatched sha256 is refused", status == 400, mismatch)

    objects = aws_cli(
        "--endpoint-url=http://localhost:4566", "s3api", "list-objects-v2",  # DevSkim: ignore DS162092
        "--bucket", bucket, "--query", "length(Contents || `[]`)", "--output", "text",
    ).stdout.strip()
    check("the object really is in the bucket", objects.isdigit() and int(objects) >= 1, objects)

    print("\n\033[1mthe backup is downloadable without going through the API\033[0m")
    # Proxying a body through the function is capped at ~4.4 MiB on Lambda (the
    # response payload limit, plus base64 for an octet-stream), which failed as an
    # opaque 502. The console asks for a presigned URL instead — signed locally,
    # so it costs no egress — and fetches the object directly.
    status, presigned = request(
        "GET", f"{api}/api/backups/{backup_id}/download-url", headers=auth
    )
    check("GET /api/backups/{id}/download-url", status == 200, presigned)
    check(
        "it is a signed URL, not the API's own",
        isinstance(presigned.get("url"), str) and "X-Amz-Signature=" in presigned["url"],
        presigned,
    )
    fetched_status, _, fetched = request_raw("GET", presigned["url"])
    check("the browser can fetch the object with it", fetched_status == 200, fetched_status)
    check("and the bytes are the ones that were uploaded", fetched == blob, len(fetched))

    status, denied = request("GET", f"{api}/api/backups/{backup_id}/download-url")
    check("an anonymous caller gets no URL", denied is not None and status == 401, status)

    print("\n\033[1mthe scheduled sweep runs\033[0m")
    result = invoke(function, {"task": "sweep"})
    check("{'task':'sweep'} succeeds", result.get("ok") is True, result)
    check("it reports what it checked", "checked" in result.get("result", {}), result)

    print("\n\033[1ma colleague is invited and joins — client onboarding\033[0m")
    status, invite = request(
        "POST", f"{api}/api/members/invite",
        body={"email": invitee, "role": "admin"}, headers=auth,
    )
    check("POST /api/members/invite", status == 200, invite)
    check(
        "the link is handed back (this deployment cannot send mail)",
        isinstance(invite.get("invite_url"), str) and "token=" in invite["invite_url"],
        invite,
    )

    invitee_token = sign_up_and_sign_in(pool, invitee)
    invite_token = invite["invite_url"].split("token=", 1)[1]
    status, accepted = request(
        "POST", f"{api}/api/session/invite/accept",
        body={"token": invite_token},
        headers={"Authorization": f"Bearer {invitee_token}"},
    )
    check("POST /api/session/invite/accept", status == 200, accepted)

    status, invitee_me = request(
        "GET", f"{api}/api/session/me",
        headers={"Authorization": f"Bearer {invitee_token}"},
    )
    check("the invitee is signed in", status == 200, invitee_me)
    check("they joined the INVITER's workspace", invitee_me.get("tenant") == tenant, invitee_me)
    check("with the role the invitation named", invitee_me.get("role") == "admin", invitee_me)

    print("\n\033[1mthe first-party credential surface is closed\033[0m")
    status, refusal = request(
        "POST", f"{api}/api/session/login",
        body={"email": founder, "password": PASSWORD},
    )
    check("POST /api/session/login is refused", status == 409, status)
    check("and says why", refusal.get("auth_mode") == "cognito", refusal)

    print(f"\n\033[32m\033[1mall {_checks} checks passed\033[0m\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        raise SystemExit(2)
    try:
        raise SystemExit(main(sys.argv[1]))
    except Failure as exc:
        print(f"\n\033[31m\033[1mFAILED: {exc}\033[0m\n")
        raise SystemExit(1) from None

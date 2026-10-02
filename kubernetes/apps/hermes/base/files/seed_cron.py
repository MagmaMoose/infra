"""Upsert the git-managed cron jobs into Hermes's job store, matched by name.

Runs in the initContainer on every boot, before the gateway starts, so nothing else holds
the jobs lock. Copying jobs.json over from git (as config.yaml is) would wipe run history
and every job created from chat, so only the fields git owns are written: prompt, schedule,
delivery and the pre-run script. Removing a job from JOBS here does not delete it from Hermes.

The daily brief's script (daily_brief_context.py, copied to $HERMES_HOME/scripts by the
initContainer) tells it when the previous brief ran, so it can report only what is new. That
is deliberately NOT `context_from` on the job's own id: Hermes injects the first 8,000
characters of the newest output file, which holds the whole prompt before the answer, so a job
reading itself nests its prompts and loses the previous answer from the second run on.
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, "/opt/hermes")

from cron import jobs

FILES = pathlib.Path(__file__).resolve().parent

JOBS = [
    {
        "name": "daily-brief",
        # 07:30 in config.yaml's `timezone`.
        "schedule": "30 7 * * *",
        # The Slack home channel (SLACK_HOME_CHANNEL).
        "deliver": "slack",
        "prompt": (FILES / "daily-brief.md").read_text(encoding="utf-8").strip(),
        # Relative to $HERMES_HOME/scripts, the only place Hermes runs a cron script from.
        "script": "daily_brief_context.py",
    },
]


def main() -> None:
    existing = {job.get("name"): job for job in jobs.list_jobs(include_disabled=True)}
    for want in JOBS:
        have = existing.get(want["name"])
        if have is None:
            jobs.create_job(
                prompt=want["prompt"],
                schedule=want["schedule"],
                name=want["name"],
                deliver=want["deliver"],
                script=want["script"],
            )
            print(f"[seed-cron] created {want['name']}")
            continue
        updates = {}
        if have.get("prompt") != want["prompt"]:
            updates["prompt"] = want["prompt"]
        if have.get("deliver") != want["deliver"]:
            updates["deliver"] = want["deliver"]
        if (have.get("schedule") or {}).get("expr") != want["schedule"]:
            updates["schedule"] = want["schedule"]
        if have.get("script") != want["script"]:
            updates["script"] = want["script"]
        if updates:
            job_id = have.get("id")
            if not job_id:
                print(f"[seed-cron] {want['name']}: no id, skipping update")
                continue
            jobs.update_job(job_id, updates)
            print(f"[seed-cron] updated {want['name']}: {', '.join(sorted(updates))}")
        else:
            print(f"[seed-cron] {want['name']} unchanged")


if __name__ == "__main__":
    main()

"""Pre-run script for the daily brief: when the previous brief ran, so it can say what is new.

Hermes runs a cron job's `script` before the agent and puts what it prints in front of the
prompt. This prints one line, `previous_brief_at: <ISO-8601 time>` or `previous_brief_at: none`,
and the brief passes the time to Nievah's `needs_you` as `new_since`: an item that started
needing the owner after it is new, anything older was in an earlier brief.

Why not `context_from` pointing at the job's own id: Hermes saves each run's WHOLE prompt in
that run's output file and injects only the first 8,000 characters of the newest one. With the
job reading itself, every prompt carries the previous output, so from the second day on the
previous answer sits past the cut and the brief would be reading old prompts instead.

The time is the newest good run's output file, less a margin for how long a run takes, so
nothing that turned up while that run was working is missed. A run that failed or answered
nothing does not count. A previous brief in an older format (one that never called needs_you)
leaves nothing to compare with, so everything is new once.

It always prints a line: Hermes skips the agent altogether when a script prints nothing.
"""

from __future__ import annotations

import os
import pathlib
from datetime import datetime, timedelta

JOB_NAME = "daily-brief"
FORMAT_MARKER = "needs_you"
MARGIN = timedelta(minutes=15)


def previous_brief_at(home: pathlib.Path) -> str:
    header = f"# Cron Job: {JOB_NAME}\n"
    outputs = sorted(
        (home / "cron" / "output").glob("*/*.md"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for path in outputs:
        text = path.read_text(encoding="utf-8", errors="replace")
        # Another job's output, or a failed run (its header ends "(FAILED)").
        if not text.startswith(header):
            continue
        prompt, found, response = text.rpartition("\n## Response\n")
        if not found or response.strip() in ("", "(No response generated)"):
            continue
        if FORMAT_MARKER not in prompt:
            return "none"
        ran = datetime.fromtimestamp(path.stat().st_mtime).astimezone() - MARGIN
        return ran.isoformat(timespec="seconds")
    return "none"


def main() -> None:
    home = pathlib.Path(os.environ.get("HERMES_HOME") or pathlib.Path(__file__).parents[1])
    try:
        answer = previous_brief_at(home)
    except Exception:  # never fail the brief over this: no anchor only means everything is new
        answer = "none"
    print(f"previous_brief_at: {answer}")


if __name__ == "__main__":
    main()

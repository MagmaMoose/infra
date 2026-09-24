"""Shared memory for the house agents: a small MCP server over the self-hosted mem0 REST API.

mem0 (kubernetes/apps/mem0) is one memory store meant for every agent (ADR 2026-07-23,
fleet shared memory). Hermes's own mem0 memory provider only talks to the hosted Mem0
platform, so this bridges the gap over stdio.

Every agent WRITES with its own agent_id, so a memory's source is always known, and READS
across all of them under one user_id, which is what makes the memory shared. Hermes runs it
from $HERMES_HOME/mcp (copied there by the initContainer). Claude Code can run the same file:

    MEM0_BASE_URL=https://mem0.sargeant.co MEM0_API_KEY=... MEM0_AGENT_ID=claude-code \
        uv run --with mcp --with httpx mem0_mcp.py

Memories are shared data, not instructions: whatever one agent stored, another reads back.
"""

from __future__ import annotations

import os
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

BASE_URL = os.environ["MEM0_BASE_URL"].rstrip("/")
API_KEY = os.environ["MEM0_API_KEY"]
USER_ID = os.environ.get("MEM0_USER_ID", "owner")
AGENT_ID = os.environ.get("MEM0_AGENT_ID", "unknown")
TIMEOUT_SECONDS = 60.0
MAX_RESULTS = 20

mcp = FastMCP("mem0")


def _call(method: str, path: str, **kwargs: Any) -> Any:
    with httpx.Client(
        timeout=TIMEOUT_SECONDS, headers={"X-API-Key": API_KEY}
    ) as client:
        response = client.request(method, f"{BASE_URL}{path}", **kwargs)
    response.raise_for_status()
    return response.json() if response.content else {}


def _memories(data: Any) -> list[dict[str, Any]]:
    """The memory records out of any of mem0's response shapes, trimmed to what matters."""
    items = (
        data.get("results", data.get("memories", []))
        if isinstance(data, dict)
        else data
    )
    keep = ("id", "memory", "event", "agent_id", "score", "created_at", "updated_at")
    return [
        {k: item[k] for k in keep if item.get(k) is not None} for item in items or []
    ]


def _safely(action: str, fn: Any) -> dict[str, Any]:
    try:
        return fn()
    except httpx.HTTPStatusError as exc:
        return {
            "error": f"{action} failed: mem0 answered HTTP {exc.response.status_code}"
        }
    except httpx.HTTPError as exc:
        return {
            "error": f"{action} failed: mem0 unreachable ({exc.__class__.__name__})"
        }


@mcp.tool()
def remember(fact: str) -> dict[str, Any]:
    """Store a fact worth keeping across conversations and agents: a preference, a decision,
    how something is set up. One self-contained fact per call. mem0 merges it with what it
    already holds, so the result may be an update rather than a new memory."""
    body = {
        "messages": [{"role": "user", "content": fact}],
        "user_id": USER_ID,
        "agent_id": AGENT_ID,
    }
    return _safely(
        "remember", lambda: {"stored": _memories(_call("POST", "/memories", json=body))}
    )


@mcp.tool()
def recall(query: str, limit: int = 5) -> dict[str, Any]:
    """Search the shared memory, written by every agent, for facts relevant to a question.
    Use it before asking the owner something they may have told an agent already."""
    body = {
        "query": query,
        "user_id": USER_ID,
        "top_k": max(1, min(limit, MAX_RESULTS)),
    }
    return _safely(
        "recall", lambda: {"results": _memories(_call("POST", "/search", json=body))}
    )


@mcp.tool()
def list_memories(limit: int = MAX_RESULTS) -> dict[str, Any]:
    """List stored memories, most relevant first, across every agent."""
    params = {"user_id": USER_ID, "top_k": max(1, min(limit, 100))}
    return _safely(
        "list_memories",
        lambda: {"memories": _memories(_call("GET", "/memories", params=params))},
    )


@mcp.tool()
def forget(memory_id: str) -> dict[str, Any]:
    """Delete one memory by id, for a fact that is wrong or no longer true."""

    def delete() -> dict[str, Any]:
        _call("DELETE", f"/memories/{memory_id}")
        return {"deleted": memory_id}

    return _safely("forget", delete)


if __name__ == "__main__":
    mcp.run()

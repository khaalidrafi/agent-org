#!/usr/bin/env python3
"""Fake ACP agent for headless agent-org-batch.el E2E testing.

Speaks the ACP wire protocol (newline-delimited JSON-RPC 2.0 over
stdio) with the minimum surface agent-org drives in a batch send:
initialize, session/new, session/prompt (one agent_message_chunk
notification, then the stopReason response).  No model, no API key, no
network — the harness landing gate can run the E2E on every push.

Usage: python3 fake-acp-agent.py [--reply TEXT] [--load] [--load-fail]
Exit: 0 on EOF.  Unknown methods are answered with an empty result so
the client never stalls; client->agent requests (fs/...) get an error
result the protocol allows.

--load      advertise loadSession and answer `session/load' with a
            replay chunk + the same session id (resume happy path).
--load-fail advertise loadSession but ERROR on `session/load' —
            exercises the batch resume's degrade-to-fresh-session path.

R1 exercise surface (FAKE_ACP_STATE=<file>): a PERSISTENT per-cwd
session store in that file, so `session/new' registers and
`session/list' answers across PROCESS restarts — what the interactive
`agent-org-start' `latest' strategy and `agent-org-resume-session'
drive against a real agent's session store.
"""
import json
import os
import sys
import time


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


REPLY = "BATCH-E2E-OK: the fake agent heard you."
if "--reply" in sys.argv:
    REPLY = sys.argv[sys.argv.index("--reply") + 1]

CAN_LOAD = "--load" in sys.argv or "--load-fail" in sys.argv
LOAD_FAILS = "--load-fail" in sys.argv
STATE = os.environ.get("FAKE_ACP_STATE")


def store_load():
    if not STATE or not os.path.exists(STATE):
        return []
    out = []
    with open(STATE) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def store_add(session_id, cwd):
    if not STATE:
        return
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "a") as f:
        f.write(json.dumps({"sessionId": session_id, "cwd": cwd,
                            "title": "fake session",
                            "updatedAt": int(time.time() * 1000)}) + "\n")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": msg_id,
                  "result": {"protocolVersion": 1,
                             "agentCapabilities": {"loadSession": CAN_LOAD},
                             "authMethods": []}})
        elif method == "session/new":
            sid = "sid-fake-e2e-%d" % int(time.time() * 1000)
            store_add(sid, params.get("cwd", os.getcwd()))
            send({"jsonrpc": "2.0", "id": msg_id,
                  "result": {"sessionId": sid}})
        elif method == "session/list":
            cwd = params.get("cwd")
            rows = store_load()
            if cwd:
                rows = [s for s in rows if s.get("cwd") == cwd]
            send({"jsonrpc": "2.0", "id": msg_id,
                  "result": {"sessions": rows}})
        elif method == "session/load":
            sid = params.get("sessionId", "sid-fake-e2e")
            if LOAD_FAILS:
                send({"jsonrpc": "2.0", "id": msg_id,
                      "error": {"code": -32603,
                                "message": "fake agent: session gone"}})
            else:
                send({"jsonrpc": "2.0", "method": "session/update",
                      "params": {"sessionId": sid,
                                 "update": {"sessionUpdate":
                                            "agent_message_chunk",
                                            "content": {"type": "text",
                                                        "text": "replayed"}}}})
                send({"jsonrpc": "2.0", "id": msg_id,
                      "result": {"sessionId": sid}})
        elif method == "session/prompt":
            sid = params.get("sessionId", "sid-fake-e2e")
            send({"jsonrpc": "2.0", "method": "session/update",
                  "params": {"sessionId": sid,
                             "update": {"sessionUpdate":
                                        "agent_message_chunk",
                                        "content": {"type": "text",
                                                    "text": REPLY}}}})
            send({"jsonrpc": "2.0", "id": msg_id,
                  "result": {"stopReason": "endTurn"}})
        elif msg_id is not None:
            send({"jsonrpc": "2.0", "id": msg_id, "result": {}})
    return 0


if __name__ == "__main__":
    sys.exit(main())

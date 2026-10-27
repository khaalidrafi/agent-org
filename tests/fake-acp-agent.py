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
"""
import json
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


REPLY = "BATCH-E2E-OK: the fake agent heard you."
if "--reply" in sys.argv:
    REPLY = sys.argv[sys.argv.index("--reply") + 1]

CAN_LOAD = "--load" in sys.argv or "--load-fail" in sys.argv
LOAD_FAILS = "--load-fail" in sys.argv


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
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": msg_id,
                  "result": {"protocolVersion": 1,
                             "agentCapabilities": {"loadSession": CAN_LOAD},
                             "authMethods": []}})
        elif method == "session/load":
            params = msg.get("params") or {}
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
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": msg_id,
                  "result": {"sessionId": "sid-fake-e2e"}})
        elif method == "session/prompt":
            params = msg.get("params") or {}
            sid = params.get("sessionId", "sid-fake-e2e")
            send({"jsonrpc": "2.0", "method": "session/update",
                  "params": {"sessionId": sid,
                             "update": {"sessionUpdate": "agent_message_chunk",
                                        "content": {"type": "text",
                                                    "text": REPLY}}}})
            send({"jsonrpc": "2.0", "id": msg_id,
                  "result": {"stopReason": "endTurn"}})
        elif msg_id is not None:
            send({"jsonrpc": "2.0", "id": msg_id, "result": {}})
    return 0


if __name__ == "__main__":
    sys.exit(main())

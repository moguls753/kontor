"""Phase-1 live gate — drive a real pairing + balance through the sidecar.

Runs INSIDE the tr-scraper container, so it reaches the sidecar at 127.0.0.1
with SIDECAR_TOKEN already in the environment. Two steps (the 2FA code arrives
between them):

  start                  read phone + PIN from stdin (two lines), POST
                         /pairing/start, print the pairing_id + countdown.
                         Trade Republic then pushes a code to the phone.
  finish PAIRING_ID CODE  POST /pairing/finish, then /balance; print the total.

Secrets handling: the PIN is read only from stdin and sent to the local
sidecar — never printed, never in argv. The phone is stashed in the container's
tmpfs between the two steps (not argv). The session blob is never printed.
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8000"
TOKEN = os.environ["SIDECAR_TOKEN"]
PHONE_STASH = "/tmp/tr_gate_phone"


def _post(path: str, payload: dict) -> tuple[int, dict]:
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-Sidecar-Token": TOKEN},
        method="POST",
    )
    # Local call — force-disable any proxy so it never leaves the container.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=150) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def _start() -> None:
    phone = sys.stdin.readline().strip()
    pin = sys.stdin.readline().strip()
    with open(PHONE_STASH, "w") as f:
        f.write(phone)
    os.chmod(PHONE_STASH, 0o600)
    status, body = _post("/pairing/start", {"phone_no": phone, "pin": pin})
    print(json.dumps({
        "step": "start",
        "status": status,
        "pairing_id": body.get("pairing_id"),
        "countdown_seconds": body.get("countdown_seconds"),
        "channel": body.get("channel"),
        "error": body.get("error"),
        "message": body.get("message"),
    }, indent=2))


def _finish(pairing_id: str, code: str) -> None:
    status, body = _post("/pairing/finish", {"pairing_id": pairing_id, "code": code})
    if status != 200:
        print(json.dumps({"step": "finish", "status": status,
                          "error": body.get("error"), "message": body.get("message")}, indent=2))
        return
    blob = body["session_blob"]
    with open(PHONE_STASH) as f:
        phone = f.read().strip()
    bstatus, bbody = _post("/balance", {"phone_no": phone, "session_blob": blob})
    try:
        os.remove(PHONE_STASH)
    except OSError:
        pass
    out = {
        "step": "balance",
        "status": bstatus,
        "total": bbody.get("total"),
        "currency": bbody.get("currency"),
        "warnings": bbody.get("warnings"),
        "as_of": bbody.get("as_of"),
        "error": bbody.get("error"),
        "message": bbody.get("message"),
        # Confirm the blob round-trips and refreshes, without revealing it.
        "session_blob_in_len": len(blob),
        "session_blob_out_len": len(bbody.get("session_blob", "")),
    }
    print(json.dumps(out, indent=2))


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "start":
        _start()
    elif cmd == "finish" and len(sys.argv) == 4:
        _finish(sys.argv[2], sys.argv[3])
    else:
        print("usage: live_balance.py start   |   live_balance.py finish PAIRING_ID CODE", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()

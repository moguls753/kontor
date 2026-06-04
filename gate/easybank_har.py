#!/usr/bin/env python3
"""
easybank_har.py — extract a REDACTED API map from a banking.easybank.de HAR.

Reads a HAR file captured in browser DevTools (Network tab → "Save all as HAR")
and prints, per request to the banking host, the endpoint + method + the *shape*
(keys only) of the request and response JSON.

ALL VALUES ARE REDACTED. Field/header NAMES are shown; passwords, tokens,
cookies, account numbers, balances, IBANs and amounts are replaced by a type
token (<str>/<int>/…). Header VALUES are never printed — only the presence of a
curated allowlist of header names. URL query VALUES are dropped; only the query
keys are shown.

Usage:
    python3 gate/easybank_har.py path/to/banking.easybank.de.har

NOTE: the raw .har contains your real data AND a live session cookie — keep it
local and delete it after. Only the redacted output of THIS script is safe to
paste/share. Run it, eyeball it, then share the output.
"""

import base64
import json
import sys
from urllib.parse import urlsplit, parse_qsl

# The banking API host(s). Everything else (telemetry, Braze, crash/fraud SDKs)
# is noise — summarised at the end, not detailed, so nothing is silently hidden.
KEEP_HOST_SUFFIXES = ("banking.easybank.de", "veripark.com")

# Header NAMES worth knowing the *presence* of. Values are never shown.
INTERESTING_HEADERS = (
    "x-xsrf-token", "authorization", "cookie", "content-type",
    "x-requested-with", "__requestverificationtoken", "x-request-url",
)


def shape(value, _depth=0):
    """Values-redacted skeleton of a JSON value: keys kept, scalars replaced by
    a type token, arrays collapsed to their first element's shape."""
    if isinstance(value, dict):
        if _depth > 12:
            return "<dict…>"
        return {k: shape(v, _depth + 1) for k, v in value.items()}
    if isinstance(value, list):
        if not value:
            return []
        # Dedupe by structural shape — VeriChannel arrays like
        # InitialCallResponses are heterogeneous, so don't assume "same shape".
        distinct, seen = [], set()
        for elem in value:
            s = shape(elem, _depth + 1)
            key = json.dumps(s, sort_keys=True, ensure_ascii=False)
            if key not in seen:
                seen.add(key)
                distinct.append(s)
            if len(distinct) >= 8:
                break
        if len(distinct) == 1:
            out = [distinct[0]]
            if len(value) > 1:
                out.append(f"<+{len(value) - 1} more, same shape>")
            return out
        return [f"<list of {len(value)} — {len(distinct)} distinct shapes:>"] + distinct
    if isinstance(value, bool):
        return "<bool>"
    if isinstance(value, int):
        return "<int>"
    if isinstance(value, float):
        return "<float>"
    if value is None:
        return "<null>"
    return "<str>"


def parse_json(text, encoding=None):
    if text is None:
        return None
    raw = text
    if encoding == "base64":
        try:
            raw = base64.b64decode(text).decode("utf-8", "replace")
        except Exception:
            return None
    raw = raw.strip()
    if not raw or raw[0] not in "{[":
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def host_kept(host):
    return any(host == s or host.endswith("." + s) for s in KEEP_HOST_SUFFIXES)


def block(label, obj):
    body = json.dumps(shape(obj), indent=2, ensure_ascii=False)
    print(f"   {label}:")
    print("     " + body.replace("\n", "\n     "))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)

    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
        har = json.load(fh)

    entries = har.get("log", {}).get("entries", [])
    kept, dropped = [], {}
    for e in entries:
        host = urlsplit(e.get("request", {}).get("url", "")).netloc.lower()
        if host_kept(host):
            kept.append(e)
        else:
            dropped[host] = dropped.get(host, 0) + 1

    print(f"# easybank HAR API map — {len(kept)} banking request(s), all values redacted\n")

    for e in kept:
        req, res = e.get("request", {}), e.get("response", {})
        method = req.get("method", "?")
        parts = urlsplit(req.get("url", ""))
        qkeys = sorted({k for k, _ in parse_qsl(parts.query)})
        path = parts.path + (f"?[{', '.join(qkeys)}]" if qkeys else "")
        print(f"== {method} {parts.netloc}{path}  -> {res.get('status', '?')}")

        names = {h.get("name", "").lower() for h in req.get("headers", [])}
        present = [h for h in INTERESTING_HEADERS if h in names]
        if present:
            print(f"   req headers present: {', '.join(present)}")

        post = req.get("postData", {})
        rbody = parse_json(post.get("text"))
        if rbody is not None:
            block("request JSON keys", rbody)
        elif post.get("params"):
            print(f"   request form fields: {sorted({p.get('name', '?') for p in post['params']})}")
        elif post.get("mimeType"):
            print(f"   request body: {post.get('mimeType')} (non-JSON, not shown)")

        content = res.get("content", {})
        sbody = parse_json(content.get("text"), content.get("encoding"))
        if sbody is not None:
            block("response JSON keys", sbody)
        else:
            print(f"   response: {content.get('mimeType') or 'no captured body'} (not JSON / not shown)")
        print()

    if dropped:
        print("# Dropped (non-banking) hosts → request counts:")
        for h, n in sorted(dropped.items(), key=lambda x: -x[1]):
            print(f"#   {h or '(none)'}: {n}")


if __name__ == "__main__":
    main()

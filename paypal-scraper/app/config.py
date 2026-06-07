"""Runtime configuration, read entirely from the environment.

Nothing sensitive is baked into the image. The sidecar fails closed: it refuses
to start without a shared-secret token AND without a pinned browser fingerprint.
Mirrors easybank-scraper/app/config.py.
"""

import os


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} must be set")
    return value


def _bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


# Shared secret expected in the X-Sidecar-Token header on every request.
SIDECAR_TOKEN = _require("SIDECAR_TOKEN")

# CloakBrowser randomizes its --fingerprint per launch (config.get_default_
# stealth_args), so each login would look like a NEW device and re-trip PayPal's
# device step-up / push. We pin a per-install seed so PayPal sees ONE stable
# device across syncs. Required, fail-closed (no default): a missing seed would
# silently revert to per-launch randomization and break the whole approach.
PP_FINGERPRINT = _require("PP_FINGERPRINT")

# CloakBrowser's persistent context dir — this IS the warmed/trusted-device
# profile, so (unlike a tmpfs scratch) it MUST survive restarts on a real rw
# volume, or every login would face a fresh-device push step-up + raise the
# captcha risk. See compose.paypal.yml.
PROFILE_DIR = os.environ.get("PROFILE_DIR", "/profile")

# Run Chromium headless. Default true: the other two sidecars run headless in
# prod and the live spike proved CloakBrowser hides the headless fingerprint
# fine; the captcha we saw was behavioral (velocity + no humanize), addressed by
# HUMANIZE + ~1/day rate-limiting in Rails, not by going headed. Set false only
# for local debugging on a desktop.
HEADLESS = _bool("HEADLESS", True)

# Drive CloakBrowser's human-like mouse curves + typing delays. Default true: the
# spike's captcha was velocity-induced with humanize OFF; turning it on (plus
# mouse-to-element before clicking) is the primary captcha-avoidance lever. It is
# a launch_persistent_context kwarg, not a per-call param.
HUMANIZE = _bool("HUMANIZE", True)

# Optional egress proxy. In compose this points at the paypal egress-proxy so the
# browser's ONLY route off the box is the squid CONNECT allowlist. Empty =>
# direct (e.g. local live-validation on the user's own machine).
PROXY_URL = os.environ.get("PROXY_URL") or None

# Hard cap on "Mehr" (show-more) pagination clicks during a sync. A safety valve
# so a long window can't loop forever. Hitting the cap is FAIL-LOUD: we raise a
# TransientError rather than return a truncated history as success. Default 60 to
# match compose.yml (compose is the source of truth): the full-year window of a
# busy personal account can exceed the old 25-page cap.
PAGE_CAP = int(os.environ.get("PAGE_CAP", "60"))

# How long we block, inside the ONE /sync request, polling for the user to
# approve the PayPal-app device push on their phone. The push wait is bounded by a
# REMAINING-TIME deadline derived from this (not an additive 150s after login):
# the whole /sync call stays under SYNC_DEADLINE_S, which is below the Rails read
# timeout, which is below Thruster's write/idle timeouts (PAYPAL_SCRAPER_PLAN.md
# §10.7). On expiry => PushTimeout (409), NOT a transient.
PUSH_DEADLINE_S = float(os.environ.get("PUSH_DEADLINE_S", "150"))

# Sidecar-side ceiling on the WHOLE blocking /sync call (login + push + scrape).
# Must be ≥ NAV(login outcome) + PUSH_DEADLINE_S + scrape, or a slow-but-legit
# push approval would be cut by this transient deadline (503) before the push
# wait could raise PushTimeout (409) — inverting the error taxonomy and skipping
# the circuit breaker. So this is NOT 165 (< 150 push + ~90 login): it is sized
# above NAV + PUSH + scrape. Chain: PUSH_DEADLINE_S(150) < SYNC_DEADLINE_S(450)
# < Rails READ_TIMEOUT(480) < Thruster idle/write(510).
SYNC_DEADLINE_S = float(os.environ.get("SYNC_DEADLINE_S", "450"))

# Time (s) reserved out of SYNC_DEADLINE_S for the post-login scrape (navigation +
# pagination + normalize). The push wait is capped at the remaining budget after
# this reserve so the scrape that follows a just-approved push can still finish
# before the sidecar's own SYNC_DEADLINE_S.
SCRAPE_RESERVE_S = float(os.environ.get("SCRAPE_RESERVE_S", "240"))

# Per-action Playwright timeout (ms) for locator fills/clicks/waits.
ACTION_TIMEOUT_MS = int(os.environ.get("ACTION_TIMEOUT_MS", "15000"))
# How long to wait for a navigation to settle (signin -> dashboard / authflow).
NAV_TIMEOUT_MS = int(os.environ.get("NAV_TIMEOUT_MS", "45000"))

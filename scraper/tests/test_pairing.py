"""Pairing contract: a WAF-mint failure must surface as the retryable
TransientError the Rails ScraperClient expects (NOT a 500 / not an expired
connection), and must leave no scratch cookie jar behind. This locks the
Rails-facing behaviour the whole WAF change exists to preserve. No browser,
no network — waf.mint_waf_token is monkeypatched.
"""

import os

import pytest

from app import config, tr_api, waf  # noqa: E402


def test_pair_start_maps_mint_failure_to_transient_and_cleans_up(monkeypatch):
    def boom(*args, **kwargs):
        raise waf.WafMintError("no token")

    monkeypatch.setattr(waf, "mint_waf_token", boom)

    scratch = config.SESSION_SCRATCH_DIR
    before = set(os.listdir(scratch))

    with pytest.raises(tr_api.TransientError):
        tr_api.pair_start("+490000000000", "0000")

    # The cookie jar created at the top of pair_start must be unlinked on the
    # mint-failure path — no leaked tr-pair- scratch file.
    leaked = [f for f in set(os.listdir(scratch)) - before if f.startswith("tr-pair-")]
    assert leaked == []

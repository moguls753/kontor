# The single post-sync pipeline (§3a/§3b). Runs once per user AFTER every ingest
# path (open-banking, scraped balances, PayPal, manual sync, account-role change,
# connection delete) and re-derives everything that depends on the freshly
# ingested transactions, in a fixed order:
#
#   ① LlmCategorizer  — categorize only the uncategorized rows
#   ② TransferMatcher — pair the two legs of internal transfers (writes transfer_group_id)
#   ③ RecurringDetector — detect/refresh series
#
# Ordering matters: ② writes transfer_group_id, which ③ reads to place a series in the
# Transfers bucket (flow_bucket), so ② must commit before detection runs. ① fills in the
# categories the detected series carry, so it runs first too.
#
# Fault isolation: a failure in any one step must NOT block the others — a missing
# LLM credential or a categorizer error still lets the matcher + detector run, and
# a matcher failure still lets the detector run on whatever is already matched.
#
# Idempotent: every step is a no-op on already-processed rows, so re-running is
# safe. Debounced per user via Solid Queue's concurrency control: at most one job
# per user, and concurrent enqueues collapse (on_conflict: :discard) instead of
# fanning out into N redundant pipeline runs when several connections finish
# around the same time.
class ProcessAccountDataJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(user_id) { user_id }, on_conflict: :discard

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    categorize(user)
    match_transfers(user)
    detect_recurring(user)
  end

  private

  # ① Categorize only uncategorized rows. categorize_uncategorized raises when no
  # LLM credential is configured (and may raise on a transient LLM error) — that
  # must never block the matcher/detector, so swallow-and-log here.
  def categorize(user)
    LlmCategorizer.new(user).categorize_uncategorized
  rescue => e
    Rails.logger.warn("ProcessAccountDataJob: categorize skipped for user ##{user.id} (#{e.class}: #{e.message})")
  end

  # ② Pair internal-transfer legs. Isolated so a matcher failure still lets the
  # detector run on whatever is already matched.
  def match_transfers(user)
    TransferMatcher.new(user).match
  rescue => e
    Rails.logger.error("ProcessAccountDataJob: transfer matching failed for user ##{user.id} (#{e.class}: #{e.message})")
  end

  # ③ Detect recurring series (reads transfer_group_id for the Transfers bucket).
  def detect_recurring(user)
    RecurringDetector.new(user).detect
  rescue => e
    Rails.logger.error("ProcessAccountDataJob: recurring detection failed for user ##{user.id} (#{e.class}: #{e.message})")
  end
end

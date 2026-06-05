module EnableBanking
  # Persists a batch of Enable Banking transactions onto one account, using EB's
  # officially recommended matching strategy rather than a content hash.
  #
  # WHY not a content hash: PSD2 does not mandate a stable per-transaction id.
  # The live ASPSP (Tomorrow) returns transaction_id=null for 100% of rows and
  # entry_reference for only a fraction of them. The remaining fields (remittance,
  # value_date, creditor details) MUTATE between a pending and a booked fetch, so
  # hashing them produces a *different* id every sync and inserts duplicates.
  # EB explicitly advises against hashing; we instead match on transaction
  # identity, falling back to the fundamentals that are immutable once booked.
  # See: https://enablebanking.com/blog/2024/10/29/how-to-sync-account-transactions-from-open-banking-apis-without-unique-transaction-ids
  #
  # The service receives the FULL list of fetched tx hashes (all pages collected
  # first) because fundamental matching needs the whole batch to claim-track:
  # two identical incoming rows must map to two distinct stored rows.
  #
  # Each incoming tx hash has symbol keys (as the EnableBanking::Client returns).
  # Idempotent: re-syncing an overlapping window converges to the same rows.
  #
  # NOTE (accepted trade-off): a booked row that LOSES its entry_reference between
  # syncs (the rare reverse flip) is NOT auto-reconciled. Fundamental candidates
  # are SURROGATE-SCOPED on purpose — widening them to entry_reference-keyed rows
  # would let an id-less tx merge with a *different* same-fundamentals tx, a worse
  # bug than the unreconciled reverse flip.
  class TransactionIngest
    # Surrogate transaction_ids we mint for rows that arrive with no id and no
    # entry_reference get this prefix, so fundamental matching can find ONLY our
    # own generated rows as candidates (never an id- or entry_reference-keyed one).
    SURROGATE_PREFIX = "eb-gen-".freeze

    # Booked statuses. A blank/nil status ALSO counts as booked (some ASPSPs omit
    # it); everything else — PDNG/pending, RJCT, INFO, FUTR, OTHR — is skipped, so
    # only genuinely booked rows pollute the `booked` scope/dashboards.
    BOOKED_STATUSES = %w[book booked].freeze

    def self.call(account, transactions)
      new(account, transactions).call
    end

    def initialize(account, transactions)
      @account = account
      @transactions = transactions || []
      # PRIMARY KEYS of stored rows already matched/created in THIS run, so a
      # second incoming tx can't claim a row already used this run. Tracked for
      # BOTH the explicit-id path and the surrogate path; populated AFTER save.
      @claimed = Set.new
    end

    def call
      skipped = 0
      booked_transactions.each do |tx|
        upsert(tx)
      rescue StandardError => e
        # One malformed row must never abort the batch — that would leave a
        # partial, hard-to-recover import. Skip it; never log amounts or PII.
        skipped += 1
        Rails.logger.warn("EnableBanking::TransactionIngest skipped a transaction (#{e.class})")
      end
      Rails.logger.warn("EnableBanking::TransactionIngest skipped #{skipped} transaction(s)") if skipped.positive?

      @account
    end

    private

    # BOOKED-ONLY. Pending rows are volatile (amount/date/remittance change before
    # they book) and would churn; non-booked terminal states (RJCT/INFO/...) aren't
    # real money movements. We ingest a row once it settles, like GoCardless.
    def booked_transactions
      @transactions.select { |tx| booked?(tx) }
    end

    def booked?(tx)
      status = tx[:status].to_s.strip.downcase
      status.empty? || BOOKED_STATUSES.include?(status)
    end

    def upsert(tx)
      record = find_existing(tx)
      if record
        # A matched surrogate row whose tx now carries an explicit id is upgraded
        # in place (fixes the nil -> entry_reference forward flip): same row, no dupe.
        adopt_explicit_id(record, tx)
      else
        record = @account.transaction_records.new(transaction_id: id_for_new(tx))
      end
      assign_attributes(record, tx)
      record.save!
      @claimed << record.id
    end

    # Dedup is ALWAYS by transaction identity:
    #   1. a real transaction_id naming an existing row NOT yet claimed; else
    #   2. an entry_reference naming an existing row whose FUNDAMENTALS also match
    #      (see below); else
    #   3. fundamental matching among OUR OWN surrogate rows only.
    #
    # Why (2) is fundamentals-guarded: a real transaction_id is per-transaction and
    # stable, so reusing its row is always correct. But PSD2 EntryReference is
    # per-STATEMENT, not per-transaction — two genuinely different booked txs can
    # share one. When this tx has NO transaction_id and we key on entry_reference,
    # the row we find may belong to a DIFFERENT same-reference tx ingested in an
    # earlier sync (and absent from this batch, so claim-tracking can't protect it).
    # Reusing it would overwrite and destroy that unrelated row — net data loss.
    # So we only reuse an entry_reference-keyed row when its booking_date + signed
    # amount match this tx; otherwise we fall through and mint a surrogate.
    def find_existing(tx)
      if tx[:transaction_id].present?
        row = @account.transaction_records.find_by(transaction_id: tx[:transaction_id])
        return row if row && @claimed.exclude?(row.id)
      elsif (ref = tx[:entry_reference].presence)
        row = @account.transaction_records.find_by(transaction_id: ref)
        return row if row && @claimed.exclude?(row.id) && fundamentals_match?(row, tx)
      end

      match_on_fundamentals(tx)
    end

    def fundamentals_match?(row, tx)
      row.booking_date == parse_date(tx[:booking_date]) && row.amount == signed_amount(tx)
    end

    def parse_date(value)
      value.is_a?(String) ? Date.parse(value) : value
    rescue ArgumentError, TypeError
      nil
    end

    # Fundamentals are immutable once a transaction is booked: its booking_date and
    # its signed amount (the sign encodes debit/credit direction). We only ever
    # rematch our OWN surrogate rows (eb-gen- prefix) and never one already claimed
    # in this run. If several candidates share the fundamentals, disambiguate on
    # the more volatile fields to narrow them.
    def match_on_fundamentals(tx)
      candidates = surrogate_candidates(tx)
      candidates = disambiguate(candidates, tx) if candidates.size > 1
      candidates.first
    end

    def surrogate_candidates(tx)
      @account.transaction_records
        .where(booking_date: tx[:booking_date], amount: signed_amount(tx))
        .where("transaction_id LIKE ?", "#{SURROGATE_PREFIX}%")
        .reject { |r| @claimed.include?(r.id) }
    end

    # Narrow ambiguous fundamental matches using progressively more specific (but
    # mutable) fields. Each filter only applies if it actually narrows the set, so
    # a field that changed between syncs can't drop the genuine match to zero.
    def disambiguate(candidates, tx)
      [
        ->(r) { r.remittance == remittance(tx) },
        ->(r) { r.creditor_name == tx.dig(:creditor, :name) },
        ->(r) { r.creditor_iban == tx.dig(:creditor_account, :iban) },
        ->(r) { r.debtor_name == tx.dig(:debtor, :name) },
        ->(r) { r.debtor_iban == tx.dig(:debtor_account, :iban) },
        ->(r) { r.value_date&.iso8601 == tx[:value_date] }
      ].each do |predicate|
        break if candidates.size <= 1

        narrowed = candidates.select(&predicate)
        candidates = narrowed if narrowed.any?
      end
      candidates
    end

    # New-row id: the explicit id ONLY if present AND not already used by an
    # existing row on this account; else a surrogate. This is what stops a repeated
    # entry_reference within one batch from overwriting its sibling — the second
    # row sees the id taken and gets its own surrogate.
    def id_for_new(tx)
      explicit = explicit_id(tx)
      return explicit if explicit && @account.transaction_records.where(transaction_id: explicit).none?

      SURROGATE_PREFIX + SecureRandom.uuid
    end

    # Upgrade a matched surrogate row to a real id once the ASPSP supplies one
    # (the forward flip nil -> entry_reference). Only when the surrogate currently
    # has no real id AND that id is free, so we never collide with another row.
    def adopt_explicit_id(record, tx)
      explicit = explicit_id(tx)
      return unless explicit
      return unless record.transaction_id.to_s.start_with?(SURROGATE_PREFIX)
      return if @account.transaction_records.where(transaction_id: explicit).where.not(id: record.id).exists?

      record.transaction_id = explicit
    end

    def explicit_id(tx)
      tx[:transaction_id].presence || tx[:entry_reference].presence
    end

    def assign_attributes(record, tx)
      record.assign_attributes(
        amount: signed_amount(tx),
        currency: tx.dig(:transaction_amount, :currency),
        booking_date: tx[:booking_date],
        value_date: tx[:value_date],
        # Normalize to the canonical 'booked' the model's `booked` scope queries —
        # EB may send 'BOOK'/'booked'/blank, all of which mean booked here.
        status: "booked",
        remittance: remittance(tx),
        creditor_name: tx.dig(:creditor, :name),
        creditor_iban: tx.dig(:creditor_account, :iban),
        debtor_name: tx.dig(:debtor, :name),
        debtor_iban: tx.dig(:debtor_account, :iban),
        entry_reference: tx[:entry_reference].presence
      )
    end

    # SIGNED amount: a debit is stored negative so the sign alone encodes direction.
    def signed_amount(tx)
      amount = BigDecimal(tx.dig(:transaction_amount, :amount))
      tx[:credit_debit_indicator] == "DBIT" ? -amount : amount
    end

    def remittance(tx)
      Array(tx[:remittance_information]).join(" ")
    end
  end
end

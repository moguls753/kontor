module EnableBankingHelpers
  def eb_aspsps_response
    {
      aspsps: [
        { name: "Sparkasse Berlin", country: "DE", logo: "https://example.com/logo.png" },
        { name: "Deutsche Bank", country: "DE", logo: "https://example.com/db.png" }
      ]
    }
  end

  def eb_auth_response
    {
      url: "https://bank.example.com/authorize?state=abc123",
      authorization_id: "auth-uuid-1234"
    }
  end

  def eb_session_response
    {
      session_id: "session-uuid-5678",
      accounts: [
        { uid: "account-uid-1", identification_hash: "hash1", iban: "DE89370400440532013000" },
        { uid: "account-uid-2", identification_hash: "hash2", iban: "DE27100777770209299700" }
      ],
      access: { valid_until: "2026-08-01T00:00:00Z" }
    }
  end

  def eb_balances_response
    {
      balances: [
        { balance_amount: { amount: "1234.56", currency: "EUR" }, balance_type: "closingBooked" }
      ]
    }
  end

  def eb_transactions_response(continuation_key: nil)
    {
      transactions: [
        {
          transaction_id: "tx-001",
          transaction_amount: { amount: "42.50", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-01-15",
          value_date: "2026-01-15",
          status: "booked",
          remittance_information: [ "REWE Markt", "Freiburg" ],
          creditor: { name: "REWE Markt GmbH" },
          creditor_account: { iban: "DE123456789" },
          debtor: nil,
          debtor_account: nil,
          entry_reference: "ref-001"
        },
        {
          transaction_id: "tx-002",
          transaction_amount: { amount: "2500.00", currency: "EUR" },
          credit_debit_indicator: "CRDT",
          booking_date: "2026-01-14",
          value_date: "2026-01-14",
          status: "booked",
          remittance_information: [ "Gehalt Januar" ],
          creditor: nil,
          creditor_account: nil,
          debtor: { name: "Arbeitgeber GmbH" },
          debtor_account: { iban: "DE987654321" },
          entry_reference: "ref-002"
        }
      ],
      continuation_key: continuation_key
    }
  end

  # Some ASPSPs (e.g. Tomorrow) never send transaction_id and often leave
  # entry_reference blank — the importer must fall back to EB's fundamental
  # matching (booking_date + signed amount), NOT a content hash.
  def eb_transactions_response_without_ids
    {
      transactions: [
        {
          transaction_id: nil,
          transaction_amount: { amount: "31.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-03",
          value_date: "2026-06-03",
          status: "booked",
          remittance_information: [ "PayPal" ],
          creditor: { name: "PayPal Europe" },
          creditor_account: { iban: "LU89751000135104200E" },
          debtor: nil,
          debtor_account: nil,
          entry_reference: ""
        },
        {
          transaction_id: nil,
          transaction_amount: { amount: "428.00", currency: "EUR" },
          credit_debit_indicator: "CRDT",
          booking_date: "2026-06-01",
          value_date: "2026-06-01",
          status: "booked",
          remittance_information: [ "Erstattung" ],
          creditor: nil,
          creditor_account: nil,
          debtor: { name: "Max Mustermann" },
          debtor_account: { iban: "DE98110101002865167" },
          entry_reference: nil
        }
      ],
      continuation_key: nil
    }
  end

  # A booked id-less row whose MUTABLE fields (remittance, value_date) drift
  # between syncs while its fundamentals (booking_date + signed amount) stay put.
  # Fundamental matching must update the existing row in place, not insert a dupe.
  def eb_transactions_response_without_ids_mutated
    {
      transactions: [
        {
          transaction_id: nil,
          transaction_amount: { amount: "31.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-03",
          value_date: "2026-06-04",
          status: "booked",
          remittance_information: [ "PayPal", "settled" ],
          creditor: { name: "PayPal Europe" },
          creditor_account: { iban: "LU89751000135104200E" },
          debtor: nil,
          debtor_account: nil,
          entry_reference: ""
        },
        {
          transaction_id: nil,
          transaction_amount: { amount: "428.00", currency: "EUR" },
          credit_debit_indicator: "CRDT",
          booking_date: "2026-06-01",
          value_date: "2026-06-01",
          status: "booked",
          remittance_information: [ "Erstattung" ],
          creditor: nil,
          creditor_account: nil,
          debtor: { name: "Max Mustermann" },
          debtor_account: { iban: "DE98110101002865167" },
          entry_reference: nil
        }
      ],
      continuation_key: nil
    }
  end

  # Two genuinely distinct, id-less, same-day same-(signed)-amount booked
  # transactions distinguished only by remittance — must become TWO rows.
  def eb_transactions_response_same_day_pair
    {
      transactions: [
        {
          transaction_id: nil,
          transaction_amount: { amount: "9.99", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-02",
          value_date: "2026-06-02",
          status: "booked",
          remittance_information: [ "Spotify" ],
          creditor: { name: "Spotify" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: ""
        },
        {
          transaction_id: nil,
          transaction_amount: { amount: "9.99", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-02",
          value_date: "2026-06-02",
          status: "booked",
          remittance_information: [ "Netflix" ],
          creditor: { name: "Netflix" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: nil
        }
      ],
      continuation_key: nil
    }
  end

  # Two id-less rows identical in EVERY field (two genuine same-day same-amount
  # purchases that even share remittance/merchant). Disambiguation cannot tell
  # them apart, so they must become — and STAY — two rows across re-syncs.
  def eb_transactions_response_identical_pair
    row = {
      transaction_id: nil,
      transaction_amount: { amount: "4.50", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      booking_date: "2026-06-02",
      value_date: "2026-06-02",
      status: "booked",
      remittance_information: [ "Cafe Central" ],
      creditor: { name: "Cafe Central" },
      creditor_account: nil,
      debtor: nil,
      debtor_account: nil,
      entry_reference: ""
    }
    { transactions: [ row, row.dup ], continuation_key: nil }
  end

  # A booked row with NO transaction_id but a non-blank entry_reference — EB's
  # second-best key, present on ~78% of the live giro account. The importer must
  # key on entry_reference (NOT mint an eb-gen- surrogate, NOT fall through to
  # fundamental matching) so re-syncs stay idempotent on that reference.
  def eb_transactions_response_entry_reference_only
    {
      transactions: [
        {
          transaction_id: nil,
          transaction_amount: { amount: "73.40", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-04",
          value_date: "2026-06-04",
          status: "booked",
          remittance_information: [ "Stadtwerke" ],
          creditor: { name: "Stadtwerke" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "entryref-9001"
        }
      ],
      continuation_key: nil
    }
  end

  # The SAME booked id-less row twice: first WITHOUT an entry_reference (stored as
  # an eb-gen- surrogate), then WITH one. The forward flip must UPGRADE the
  # surrogate in place to that entry_reference — one row, not a duplicate.
  def eb_transactions_response_forward_flip_before
    {
      transactions: [
        {
          transaction_id: nil,
          transaction_amount: { amount: "19.90", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-03",
          value_date: "2026-06-03",
          status: "booked",
          remittance_information: [ "Telekom" ],
          creditor: { name: "Telekom" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: nil
        }
      ],
      continuation_key: nil
    }
  end

  def eb_transactions_response_forward_flip_after
    response = eb_transactions_response_forward_flip_before
    response[:transactions].first[:entry_reference] = "flip-ref-7001"
    response
  end

  # ONE batch of two DIFFERENT booked txs (distinct amounts) that share the SAME
  # entry_reference. PSD2 EntryReference is per-statement, not per-transaction, so
  # this is legal — both rows must survive (the second falls back to a surrogate).
  def eb_transactions_response_shared_entry_reference
    {
      transactions: [
        {
          transaction_id: nil,
          transaction_amount: { amount: "10.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-02",
          value_date: "2026-06-02",
          status: "booked",
          remittance_information: [ "Kiosk" ],
          creditor: { name: "Kiosk" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "stmt-ref-555"
        },
        {
          transaction_id: nil,
          transaction_amount: { amount: "20.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-02",
          value_date: "2026-06-02",
          status: "booked",
          remittance_information: [ "Tankstelle" ],
          creditor: { name: "Tankstelle" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "stmt-ref-555"
        }
      ],
      continuation_key: nil
    }
  end

  # ONE booked id-less tx keyed by entry_reference, ingested in an EARLIER sync.
  # A LATER sync brings a DIFFERENT booked tx (other amount + booking_date) that
  # happens to reuse the SAME per-statement entry_reference, with the first tx no
  # longer in the batch. The later tx must NOT overwrite the earlier row — it must
  # become its own (surrogate) row. (Cross-sync per-statement collision guard.)
  def eb_transactions_response_shared_entry_reference_earlier
    {
      transactions: [
        {
          transaction_id: nil,
          transaction_amount: { amount: "99.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-01",
          value_date: "2026-06-01",
          status: "booked",
          remittance_information: [ "Rent B" ],
          creditor: { name: "Landlord" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "stmt-0001"
        }
      ],
      continuation_key: nil
    }
  end

  def eb_transactions_response_shared_entry_reference_later
    {
      transactions: [
        {
          transaction_id: nil,
          transaction_amount: { amount: "12.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-25",
          value_date: "2026-06-25",
          status: "booked",
          remittance_information: [ "Coffee A" ],
          creditor: { name: "Cafe" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "stmt-0001"
        }
      ],
      continuation_key: nil
    }
  end

  # A booked row plus a rejected (RJCT) one. Non-booked terminal states must be
  # skipped entirely — never stored as status:'booked'.
  def eb_transactions_response_with_rejected
    {
      transactions: [
        {
          transaction_id: "tx-booked-ok",
          transaction_amount: { amount: "30.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-05",
          value_date: "2026-06-05",
          status: "booked",
          remittance_information: [ "Groceries" ],
          creditor: { name: "Market" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "ok-1"
        },
        {
          transaction_id: "tx-rejected",
          transaction_amount: { amount: "99.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-05",
          value_date: "2026-06-05",
          status: "RJCT",
          remittance_information: [ "Failed transfer" ],
          creditor: { name: "Recipient" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "rjct-1"
        }
      ],
      continuation_key: nil
    }
  end

  # A booked row (uppercase 'BOOK' code) plus a pending one (PDNG). Only the
  # booked row may be ingested, and its stored status must normalize to 'booked'.
  def eb_transactions_response_with_pending
    {
      transactions: [
        {
          transaction_id: "tx-booked-1",
          transaction_amount: { amount: "12.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-05",
          value_date: "2026-06-05",
          status: "BOOK",
          remittance_information: [ "Bakery" ],
          creditor: { name: "Bakery" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "bk-1"
        },
        {
          transaction_id: "tx-pending-1",
          transaction_amount: { amount: "55.00", currency: "EUR" },
          credit_debit_indicator: "DBIT",
          booking_date: "2026-06-05",
          value_date: "2026-06-05",
          status: "PDNG",
          remittance_information: [ "Hotel hold" ],
          creditor: { name: "Hotel" },
          creditor_account: nil,
          debtor: nil,
          debtor_account: nil,
          entry_reference: "pd-1"
        }
      ],
      continuation_key: nil
    }
  end
end

RSpec.configure do |config|
  config.include EnableBankingHelpers
end

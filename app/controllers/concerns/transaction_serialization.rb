# Single source of truth for the JSON shape of a transaction row (frontend
# `Transaction` type). Shared by the transactions list and any other endpoint
# that returns transaction rows (e.g. the statistics "variable flows" modal), so
# the frontend can reuse the same row components and helpers.
module TransactionSerialization
  def transaction_json(tx)
    {
      id: tx.id,
      transaction_id: tx.transaction_id,
      amount: tx.amount,
      currency: tx.currency,
      booking_date: tx.booking_date,
      value_date: tx.value_date,
      status: tx.status,
      remittance: tx.remittance,
      creditor_name: tx.creditor_name,
      creditor_iban: tx.creditor_iban,
      debtor_name: tx.debtor_name,
      debtor_iban: tx.debtor_iban,
      bank_transaction_code: tx.bank_transaction_code,
      category: tx.category ? { id: tx.category.id, name: tx.category.name } : nil,
      account_id: tx.account_id,
      account_name: tx.account.name
    }
  end
end

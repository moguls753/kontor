class AddFxFieldsToTransactionRecords < ActiveRecord::Migration[8.1]
  def change
    # Foreign-currency card transactions (easybank Kreditkarte) carry the original
    # charge before conversion plus the rate the bank applied. mcc is the card
    # scheme's merchant category code — a strong categorization signal. All
    # nullable: only FX card lines populate them; SEPA/open-banking rows leave them
    # blank. exchange_rate gets wider scale (rates run to 6+ decimals).
    add_column :transaction_records, :original_amount, :decimal, precision: 15, scale: 2
    add_column :transaction_records, :original_currency, :string, limit: 3
    add_column :transaction_records, :exchange_rate, :decimal, precision: 18, scale: 8
    add_column :transaction_records, :mcc, :string
  end
end

class AddRecurringSeriesToTransactionRecords < ActiveRecord::Migration[8.1]
  def change
    add_reference :transaction_records, :recurring_series, foreign_key: { on_delete: :nullify }, index: true
  end
end

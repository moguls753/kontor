class AddTransferMatchingToTransactionRecords < ActiveRecord::Migration[8.1]
  def change
    # Both legs of a matched internal transfer share this id (SecureRandom.uuid).
    add_column :transaction_records, :transfer_group_id, :string

    # Account of the other leg, denormalized so the scope filter (§4) is plain SQL
    # without a self-join. FK with on_delete: :nullify: when the counterpart account
    # is deleted the column goes NULL → TransferMatcher un-matches the surviving leg
    # (no stale match that counts as a flow forever). add_reference adds the index.
    add_reference :transaction_records, :transfer_counterpart_account,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }

    add_index :transaction_records, :transfer_group_id
  end
end

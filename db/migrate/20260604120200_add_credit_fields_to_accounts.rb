class AddCreditFieldsToAccounts < ActiveRecord::Migration[8.1]
  def change
    # Credit-card accounts (easybank Kreditkarte) expose a credit line and the
    # remaining headroom alongside the regular balance. Nullable: only credit
    # products populate them; current/savings accounts leave them blank.
    add_column :accounts, :credit_limit, :decimal, precision: 15, scale: 2
    add_column :accounts, :available_credit, :decimal, precision: 15, scale: 2
  end
end

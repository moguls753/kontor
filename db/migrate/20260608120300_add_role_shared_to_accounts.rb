class AddRoleSharedToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :role, :string
    add_column :accounts, :shared, :boolean, null: false, default: false
    add_column :accounts, :role_locked, :boolean, null: false, default: false
  end
end

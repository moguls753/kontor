# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_08_120400) do
  create_table "accounts", force: :cascade do |t|
    t.string "account_type"
    t.string "account_uid", null: false
    t.decimal "available_credit", precision: 15, scale: 2
    t.decimal "balance_amount", precision: 15, scale: 2
    t.string "balance_type"
    t.datetime "balance_updated_at"
    t.integer "bank_connection_id", null: false
    t.datetime "created_at", null: false
    t.decimal "credit_limit", precision: 15, scale: 2
    t.string "currency", limit: 3, default: "EUR"
    t.string "iban"
    t.string "identification_hash"
    t.datetime "last_synced_at"
    t.string "name"
    t.string "role"
    t.boolean "role_locked", default: false, null: false
    t.boolean "shared", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["account_uid"], name: "index_accounts_on_account_uid"
    t.index ["bank_connection_id"], name: "index_accounts_on_bank_connection_id"
    t.index ["identification_hash"], name: "index_accounts_on_identification_hash"
  end

  create_table "bank_connections", force: :cascade do |t|
    t.string "authorization_id"
    t.integer "consecutive_failures", default: 0, null: false
    t.string "country_code", limit: 2
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "institution_id", null: false
    t.string "institution_name"
    t.datetime "last_login_attempt_at"
    t.datetime "last_synced_at"
    t.string "link"
    t.string "provider", default: "enable_banking", null: false
    t.string "requisition_id"
    t.string "session_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.datetime "valid_until"
    t.index ["session_id"], name: "index_bank_connections_on_session_id", unique: true
    t.index ["user_id", "institution_id"], name: "index_bank_connections_on_user_id_and_institution_id"
    t.index ["user_id"], name: "index_bank_connections_on_user_id"
  end

  create_table "categories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "name"], name: "index_categories_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_categories_on_user_id"
  end

  create_table "easybank_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_paired_at"
    t.text "password"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.text "username"
    t.index ["user_id"], name: "index_easybank_credentials_on_user_id", unique: true
  end

  create_table "enable_banking_credentials", force: :cascade do |t|
    t.string "app_id", null: false
    t.datetime "created_at", null: false
    t.text "private_key_pem", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_enable_banking_credentials_on_user_id", unique: true
  end

  create_table "go_cardless_credentials", force: :cascade do |t|
    t.datetime "access_expires_at"
    t.text "access_token"
    t.datetime "created_at", null: false
    t.datetime "refresh_expires_at"
    t.text "refresh_token"
    t.string "secret_id", null: false
    t.string "secret_key", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_go_cardless_credentials_on_user_id", unique: true
  end

  create_table "llm_credentials", force: :cascade do |t|
    t.text "api_key"
    t.string "base_url", null: false
    t.datetime "created_at", null: false
    t.string "llm_model", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_llm_credentials_on_user_id", unique: true
  end

  create_table "merchant_aliases", force: :cascade do |t|
    t.string "canonical_name", null: false
    t.datetime "created_at", null: false
    t.string "merchant_type"
    t.string "raw_key", null: false
    t.string "source", default: "llm", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["canonical_name"], name: "index_merchant_aliases_on_canonical_name"
    t.index ["user_id", "raw_key"], name: "index_merchant_aliases_on_user_id_and_raw_key", unique: true
    t.index ["user_id"], name: "index_merchant_aliases_on_user_id"
  end

  create_table "paypal_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "password"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.text "username"
    t.index ["user_id"], name: "index_paypal_credentials_on_user_id", unique: true
  end

  create_table "recurring_series", force: :cascade do |t|
    t.decimal "amount_max", precision: 15, scale: 2
    t.decimal "amount_min", precision: 15, scale: 2
    t.boolean "amount_variable", default: false, null: false
    t.string "cadence", null: false
    t.integer "cadence_days"
    t.string "canonical_name", null: false
    t.integer "category_id"
    t.decimal "confidence", precision: 4, scale: 3, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.string "currency", limit: 3, null: false
    t.string "direction", null: false
    t.decimal "expected_amount", precision: 15, scale: 2
    t.string "fingerprint", null: false
    t.date "first_seen_on"
    t.date "last_seen_on"
    t.string "merchant_type"
    t.date "next_expected_on"
    t.integer "occurrences_count", default: 0, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.boolean "user_confirmed", default: false, null: false
    t.integer "user_id", null: false
    t.index ["category_id"], name: "index_recurring_series_on_category_id"
    t.index ["user_id", "fingerprint"], name: "index_recurring_series_on_user_id_and_fingerprint"
    t.index ["user_id", "status"], name: "index_recurring_series_on_user_id_and_status"
    t.index ["user_id"], name: "index_recurring_series_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "trade_republic_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_paired_at"
    t.text "phone_number"
    t.text "pin"
    t.text "session_blob"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_trade_republic_credentials_on_user_id", unique: true
  end

  create_table "transaction_records", force: :cascade do |t|
    t.integer "account_id", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "bank_transaction_code"
    t.date "booking_date", null: false
    t.integer "category_id"
    t.datetime "created_at", null: false
    t.string "creditor_iban"
    t.string "creditor_name"
    t.string "currency", limit: 3, null: false
    t.string "debtor_iban"
    t.string "debtor_name"
    t.string "entry_reference"
    t.decimal "exchange_rate", precision: 18, scale: 8
    t.string "mcc"
    t.decimal "original_amount", precision: 15, scale: 2
    t.string "original_currency", limit: 3
    t.integer "recurring_series_id"
    t.text "remittance"
    t.string "status", default: "booked"
    t.string "transaction_id", null: false
    t.integer "transfer_counterpart_account_id"
    t.string "transfer_group_id"
    t.datetime "updated_at", null: false
    t.date "value_date"
    t.index ["account_id", "transaction_id"], name: "index_transaction_records_on_account_id_and_transaction_id", unique: true
    t.index ["account_id"], name: "index_transaction_records_on_account_id"
    t.index ["booking_date"], name: "index_transaction_records_on_booking_date"
    t.index ["category_id"], name: "index_transaction_records_on_category_id"
    t.index ["recurring_series_id"], name: "index_transaction_records_on_recurring_series_id"
    t.index ["transfer_counterpart_account_id"], name: "index_transaction_records_on_transfer_counterpart_account_id"
    t.index ["transfer_group_id"], name: "index_transaction_records_on_transfer_group_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "accounts", "bank_connections"
  add_foreign_key "bank_connections", "users"
  add_foreign_key "categories", "users"
  add_foreign_key "easybank_credentials", "users"
  add_foreign_key "enable_banking_credentials", "users"
  add_foreign_key "go_cardless_credentials", "users"
  add_foreign_key "llm_credentials", "users"
  add_foreign_key "merchant_aliases", "users"
  add_foreign_key "paypal_credentials", "users"
  add_foreign_key "recurring_series", "categories"
  add_foreign_key "recurring_series", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "trade_republic_credentials", "users"
  add_foreign_key "transaction_records", "accounts"
  add_foreign_key "transaction_records", "accounts", column: "transfer_counterpart_account_id", on_delete: :nullify
  add_foreign_key "transaction_records", "categories"
  add_foreign_key "transaction_records", "recurring_series", on_delete: :nullify
end

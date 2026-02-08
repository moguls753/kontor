# == Schema Information
#
# Table name: users
#
#  id              :integer          not null, primary key
#  email_address   :string           not null
#  password_digest :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_users_on_email_address  (email_address) UNIQUE
#
class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_one :enable_banking_credential, dependent: :destroy
  has_one :go_cardless_credential, dependent: :destroy
  has_one :llm_credential, dependent: :destroy
  has_many :bank_connections, dependent: :destroy
  has_many :accounts, through: :bank_connections
  has_many :transaction_records, through: :accounts
  has_many :categories, dependent: :destroy

  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  DEFAULT_CATEGORIES = {
    en: [
      "Groceries & Drinks", "Restaurants & Cafés", "Transport", "Shopping & Clothing",
      "Entertainment", "Housing & Rent", "Utilities & Energy", "Internet",
      "Phone", "Health & Pharmacy", "Education", "Travel",
      "Income & Salary", "Transfers", "Savings", "Cash & ATM", "Other"
    ],
    de: [
      "Lebensmittel & Getränke", "Restaurants & Cafés", "Transport & Verkehr", "Shopping & Kleidung",
      "Unterhaltung", "Wohnen & Miete", "Strom & Energie", "Internet",
      "Telefon", "Gesundheit & Apotheke", "Bildung", "Reisen",
      "Einkommen & Gehalt", "Überweisungen", "Sparen", "Bargeld & ATM", "Sonstiges"
    ]
  }.freeze

  def create_default_categories!(locale: :de)
    names = DEFAULT_CATEGORIES.fetch(locale.to_sym, DEFAULT_CATEGORIES[:en])
    names.each { |name| categories.find_or_create_by!(name: name) }
  end
end

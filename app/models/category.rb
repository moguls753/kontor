# == Schema Information
#
# Table name: categories
#
#  id         :integer          not null, primary key
#  name       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :integer          not null
#
# Indexes
#
#  index_categories_on_user_id           (user_id)
#  index_categories_on_user_id_and_name  (user_id,name) UNIQUE
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
class Category < ApplicationRecord
  belongs_to :user
  has_many :transaction_records, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :user_id }

  normalizes :name, with: ->(n) { n.strip }
end

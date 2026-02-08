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
require "rails_helper"

RSpec.describe Category, type: :model do
  it "is valid with a user and name" do
    expect(build(:category)).to be_valid
  end

  it "requires a name" do
    expect(build(:category, name: nil)).not_to be_valid
  end

  it "requires unique name per user" do
    user = create(:user)
    create(:category, user: user, name: "Groceries")
    expect(build(:category, user: user, name: "Groceries")).not_to be_valid
  end

  it "allows same name for different users" do
    create(:category, name: "Groceries")
    expect(build(:category, name: "Groceries")).to be_valid
  end

  it "strips whitespace from name" do
    category = create(:category, name: "  Groceries  ")
    expect(category.name).to eq("Groceries")
  end

  it "nullifies transaction_records on destroy" do
    category = create(:category)
    transaction = create(:transaction_record, category: category)
    category.destroy!
    expect(transaction.reload.category_id).to be_nil
  end
end

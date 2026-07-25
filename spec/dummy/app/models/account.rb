# frozen_string_literal: true

class Account < ApplicationRecord
  has_many :widgets, dependent: :destroy

  def tenant_key = "account:#{id}"
end

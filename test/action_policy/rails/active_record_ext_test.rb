# frozen_string_literal: true

require "test_helper"
require_relative "active_record_helper"

require_relative "dummy/config/environment"

class TestActiveRecordPolicyCacheKey < Minitest::Test
  def setup
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    @user = AR::User.create!(name: "Jack")
  end

  def teardown
    ActiveRecord::Base.connection.rollback_transaction
  end

  attr_reader :user

  def test_same_row_shares_the_key
    assert_equal user.policy_cache_key, AR::User.find(user.id).policy_cache_key
  end

  def test_update_changes_the_key
    key = user.policy_cache_key
    user.update!(name: "John", updated_at: user.updated_at + 1)

    refute_equal key, user.policy_cache_key
  end

  class PartialUserPolicy < ActionPolicy::Base
    authorize :user

    def show? = true
  end

  class UsersController < ActionController::Base
    authorize :user, through: :current_user

    def current_user = AR::User.first
  end

  def test_partially_selected_record
    partial_user = AR::User.select(:id, :name).find(user.id)

    assert UsersController.new.allowed_to?(:show?, partial_user, with: PartialUserPolicy)
  end

  def test_new_records_are_distinct
    refute_equal AR::User.new.policy_cache_key, AR::User.new.policy_cache_key
  end
end

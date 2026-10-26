# frozen_string_literal: true

#
# Measures the per-request cost of authorizing ActiveRecord models
# from a controller, with the extensions the Railtie installs by default.
#
#   $ bundle exec ruby benchmarks/authorization_hot_path.rb
#   $ INSTRUMENTATION=0 bundle exec ruby benchmarks/authorization_hot_path.rb
#

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "active_record"
require "action_policy"
require "action_policy/rails/controller"
require "action_policy/rails/scope_matchers/active_record"
require "action_policy/rails/ext/active_record"
require "benchmark/ips"

unless ENV["INSTRUMENTATION"] == "0"
  require "action_policy/rails/policy/instrumentation"
  require "action_policy/rails/authorizer"
  ActionPolicy::Base.prepend ActionPolicy::Policy::Rails::Instrumentation
  ActionPolicy::Authorizer.singleton_class.prepend ActionPolicy::Rails::Authorizer
end

ActionPolicy::PerThreadCache.enabled = true
ActionPolicy::LookupChain.namespace_cache_enabled = true

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:posts) { |t| t.timestamps }
end

class Post < ActiveRecord::Base; end

User = Struct.new(:admin) do
  def admin? = admin
end

class ApplicationPolicy < ActionPolicy::Base
  authorize :user

  def show? = true
  def update? = user.admin?
  def destroy? = user.admin?

  relation_scope { |relation| relation }
end

class PostPolicy < ApplicationPolicy; end

module Admin
  class PostsController
    include ActionPolicy::Controller

    authorize :user, through: :current_user

    def current_user = USER
    def action_name = "show"
  end
end

USER = User.new(true)
50.times { Post.create! }
POSTS = Post.order(:id).to_a
POST = POSTS.first

def new_request
  ActionPolicy::PerThreadCache.clear_all
  Admin::PostsController.new
end

SCENARIOS = {
  "authorize! one record" => -> { new_request.authorize!(POST, to: :show?) },
  "allowed_to? 50 records x 2 rules" => -> {
    controller = new_request
    POSTS.each do |post|
      controller.allowed_to?(:update?, post)
      controller.allowed_to?(:destroy?, post)
    end
  },
  "authorized_scope relation" => -> { new_request.authorized_scope(Post.all) }
}

def allocations_per_call(&block)
  10.times { block.call }
  before = GC.stat(:total_allocated_objects)
  100.times { block.call }
  (GC.stat(:total_allocated_objects) - before) / 100
end

SCENARIOS.each do |name, scenario|
  puts "#{name}: #{allocations_per_call(&scenario)} objects allocated"
end

Benchmark.ips do |x|
  SCENARIOS.each { |name, scenario| x.report(name, &scenario) }
end

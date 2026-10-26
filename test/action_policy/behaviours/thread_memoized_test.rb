# frozen_string_literal: true

require "test_helper"

class TestThreadMemoized < Minitest::Test
  class UserPolicy < ::UserPolicy
    MUTEX = Mutex.new

    class << self
      def policies
        @policies ||= []
      end

      def reset
        @policies = []
      end
    end

    def initialize(record = nil, **params)
      super
      MUTEX.synchronize do
        self.class.policies << self
      end
    end
  end

  class User < ::User; end

  class CustomPolicy < UserPolicy; end

  class CacheableUser < User
    def policy_class
      UserPolicy
    end

    def cache_key
      "user/#{name}"
    end
  end

  class ChatChannel
    include ActionPolicy::Behaviour
    include ActionPolicy::Behaviours::ThreadMemoized

    attr_reader :user

    authorize :user

    def initialize(name)
      @user = CacheableUser.new(name)
    end

    def talk(user)
      authorize! user, to: :update?
      "OK"
    end

    def speak(user)
      authorize! user, to: :update?, with: CustomPolicy
      "OK"
    end

    def talk?(user)
      allowed_to?(:talk?, user)
    end

    def talk_as?(user, current_user)
      allowed_to?(:talk?, user, context: {user: current_user})
    end
  end

  def setup
    ActionPolicy::PerThreadCache.enabled = true
  end

  def teardown
    ActionPolicy::PerThreadCache.clear_all
    ActionPolicy::PerThreadCache.enabled = false
    UserPolicy.reset
    CustomPolicy.reset
  end

  def test_same_thread
    user = User.new("guest")

    channel = ChatChannel.new("admin")
    channel.talk(user)

    channel_2 = ChatChannel.new("admin")
    channel_2.talk(user)

    assert_equal 1, UserPolicy.policies.size
  end

  def test_disabled
    ActionPolicy::PerThreadCache.enabled = false

    user = User.new("guest")

    channel = ChatChannel.new("admin")
    channel.talk(user)

    channel_2 = ChatChannel.new("admin")
    channel_2.talk(user)

    assert_equal 2, UserPolicy.policies.size
  end

  def test_same_thread_with_different_context
    user = User.new("guest")

    channel = ChatChannel.new("admin")
    assert channel.talk?(user)

    channel_2 = ChatChannel.new("guest")
    refute channel_2.talk?(user)

    assert_equal 2, UserPolicy.policies.size
  end

  def test_different_threads
    user = User.new("guest")

    channel = ChatChannel.new("admin")
    channel_2 = ChatChannel.new("guest")
    channel_3 = ChatChannel.new("guest")

    threads = []

    threads << Thread.new do
      assert channel.talk?(user)
    end

    threads << Thread.new do
      refute channel_2.talk?(user)
      refute channel_3.talk?(user)
    end

    threads.map(&:join)

    assert_equal 2, UserPolicy.policies.size
  end

  def test_with_different_policies
    channel = ChatChannel.new("admin")
    user = User.new("guest")

    channel.talk(user)
    assert_equal 1, UserPolicy.policies.size
    assert_equal 0, CustomPolicy.policies.size

    channel.speak(user)
    assert_equal 1, UserPolicy.policies.size
    assert_equal 1, CustomPolicy.policies.size
  end

  def test_without_cache_key
    channel = ChatChannel.new("admin")

    channel.talk(User.new("guest"))
    assert_equal 1, UserPolicy.policies.size

    channel.talk(User.new("guest"))
    assert_equal 2, UserPolicy.policies.size
  end

  def test_with_cache_key
    channel = ChatChannel.new("admin")

    channel.talk(CacheableUser.new("guest"))
    assert_equal 1, UserPolicy.policies.size

    channel.talk(CacheableUser.new("guest"))
    assert_equal 1, UserPolicy.policies.size
  end

  def test_instance_cache_with_context
    channel = ChatChannel.new("admin")
    user = User.new("guest")

    assert channel.talk?(user)
    assert_equal 1, UserPolicy.policies.size

    refute channel.talk_as?(user, user)
    assert_equal 2, UserPolicy.policies.size

    refute channel.talk_as?(user, user)
    assert_equal 2, UserPolicy.policies.size

    # Make sure explicit and implicit context are
    # treated as the same context for policies
    assert channel.talk_as?(user, channel.user)
    assert_equal 2, UserPolicy.policies.size
  end

  module CountingCacheKeys
    attr_reader :cache_keys_count

    def policy_for_cache_key(**)
      @cache_keys_count = cache_keys_count.to_i + 1
      super
    end
  end

  class UnmemoizedChatChannel
    include ActionPolicy::Behaviour

    attr_reader :user

    authorize :user

    def initialize(name)
      @user = CacheableUser.new(name)
    end

    def talk?(user)
      allowed_to?(:talk?, user)
    end
  end

  class BothMemoizedChatChannel < UnmemoizedChatChannel
    include ActionPolicy::Behaviours::ThreadMemoized
    include ActionPolicy::Behaviours::Memoized
    include CountingCacheKeys
  end

  class MemoizedFirstChatChannel < UnmemoizedChatChannel
    include ActionPolicy::Behaviours::Memoized
    include ActionPolicy::Behaviours::ThreadMemoized
  end

  class MemoizedSubChatChannel < ChatChannel
    include ActionPolicy::Behaviours::Memoized
  end

  class MemoizedChatChannel < UnmemoizedChatChannel
    include ActionPolicy::Behaviours::Memoized
  end

  class ThreadMemoizedSubChatChannel < MemoizedChatChannel
    include ActionPolicy::Behaviours::ThreadMemoized
  end

  module ThreadMemoizedConcern
    include ActionPolicy::Behaviours::ThreadMemoized
  end

  module MemoizedConcern
    include ActionPolicy::Behaviours::Memoized
  end

  class ThreadMemoizedThroughConcernChatChannel < UnmemoizedChatChannel
    include ActionPolicy::Behaviours::Memoized
    include ThreadMemoizedConcern
  end

  class MemoizedThroughConcernChatChannel < UnmemoizedChatChannel
    include ActionPolicy::Behaviours::ThreadMemoized
    include MemoizedConcern
  end

  def test_cache_key_built_once_with_both_memoizations
    channel = BothMemoizedChatChannel.new("admin")
    user = User.new("guest")

    assert channel.talk?(user)
    assert channel.talk?(user)

    assert_equal 2, channel.cache_keys_count
    assert_equal 1, UserPolicy.policies.size
  end

  def test_thread_cache_shared_with_both_memoizations
    user = User.new("guest")

    assert BothMemoizedChatChannel.new("admin").talk?(user)
    assert BothMemoizedChatChannel.new("admin").talk?(user)

    assert_equal 1, UserPolicy.policies.size
  end

  def test_memoizations_included_in_any_order
    channel = MemoizedFirstChatChannel.new("admin")

    assert channel.talk?(User.new("guest"))
    refute channel.talk?(User.new("admin"))
    assert_equal 2, UserPolicy.policies.size
  end

  def test_thread_cache_shared_when_subclass_includes_memoized
    user = User.new("guest")

    assert MemoizedSubChatChannel.new("admin").talk?(user)
    assert MemoizedSubChatChannel.new("admin").talk?(user)

    assert_equal 1, UserPolicy.policies.size
  end

  def test_instance_cache_kept_when_subclass_includes_thread_memoized
    ActionPolicy::PerThreadCache.enabled = false
    channel = ThreadMemoizedSubChatChannel.new("admin")
    user = User.new("guest")

    assert channel.talk?(user)
    assert channel.talk?(user)

    assert_equal 1, UserPolicy.policies.size
  end

  def test_thread_cache_shared_when_included_through_a_module
    user = User.new("guest")

    assert ThreadMemoizedThroughConcernChatChannel.new("admin").talk?(user)
    assert ThreadMemoizedThroughConcernChatChannel.new("admin").talk?(user)

    assert_equal 1, UserPolicy.policies.size
  end

  def test_instance_cache_kept_when_included_through_a_module
    ActionPolicy::PerThreadCache.enabled = false
    channel = MemoizedThroughConcernChatChannel.new("admin")
    user = User.new("guest")

    assert channel.talk?(user)
    assert channel.talk?(user)

    assert_equal 1, UserPolicy.policies.size
  end
end

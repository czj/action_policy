# frozen_string_literal: true

module ActionPolicy
  module Behaviours
    # Builds the policy cache key once and passes it down the chain of
    # memoization layers (Memoized, ThreadMemoized), each of them calling
    # `super` on a cache miss.
    module PolicyMemoization # :nodoc:
      def policy_for(record:, **opts)
        __policy_memoize__(policy_for_cache_key(record: record, **opts)) { super }
      end
    end

    # Per-instance memoization for policies.
    #
    # Used by `policy_for` to re-use policy object for records.
    #
    # Example:
    #
    #   include ActionPolicy::Behaviour
    #   include ActionPolicy::Memoized
    #
    #   record = User.first
    #   policy = policy_for(record)
    #   policy2 = policy_for(record)
    #
    #   policy.equal?(policy) #=> true
    #
    #   policy.equal?(policy_for(record, with: CustomPolicy)) #=> false
    module Memoized
      class << self
        def prepended(base)
          base.prepend PolicyMemoization
          base.prepend InstanceMethods
        end

        alias_method :included, :prepended
      end

      module InstanceMethods # :nodoc:
        def __policy_memoize__(cache_key)
          __policies_cache__.fetch(cache_key) { __policies_cache__[cache_key] = super }
        end
      end

      def __policies_cache__
        @__policies_cache__ ||= {}
      end
    end
  end
end

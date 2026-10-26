# frozen_string_literal: true

# Add explicit #policy_cache_key to Relation to
# avoid calling #cache_key.
# See https://github.com/palkan/action_policy/issues/55
ActiveRecord::Relation.include(Module.new do
  def policy_cache_key
    object_id
  end

  # Explicitly define the policy_class method to avoid
  # making Relation immutable (by initializing `arel` in `#respond_to_missing?).
  # See https://github.com/palkan/action_policy/issues/101
  def policy_class
    nil
  end
end)

# Ensure non-persistent models are not cached as a single entry
ActiveRecord::Base.include(Module.new do
  # Unlike cache_key_with_version, does not format updated_at on every lookup
  def policy_cache_key
    return object_id.to_s unless persisted?

    updated_at = self["updated_at"] if has_attribute?("updated_at")
    "#{self.class.name}/#{id}-#{updated_at&.to_f}"
  end
end)

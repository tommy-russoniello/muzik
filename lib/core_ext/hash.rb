# https://github.com/rails/rails/blob/main/activesupport/lib/active_support/core_ext/hash/except.rb
class Hash
  def except(*keys)
    dup.except!(*keys)
  end

  def except!(*keys)
    keys.each { |key| delete(key) }
    self
  end
end

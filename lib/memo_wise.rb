# frozen_string_literal: true

require "set"

require "memo_wise/internal_api"
require "memo_wise/version"

# MemoWise is the wise choice for memoization in Ruby.
#
# - **Q:** What is *memoization*?
# - **A:** [via Wikipedia](https://en.wikipedia.org/wiki/Memoization):
#
#          [Memoization is] an optimization technique used primarily to speed up
#          computer programs by storing the results of expensive function
#          calls and returning the cached result when the same inputs occur
#          again.
#
# To start using MemoWise in a class or module:
#
#   1. Add `prepend MemoWise` to the top of the class or module
#   2. Call {.memo_wise} to implement memoization for a given method
#
# **See Also:**
#
#   - {.memo_wise} for API and usage examples.
#   - {file:README.md} for general project information.
#
module MemoWise
  # Constructor to set up memoization state before
  # [calling the original](https://medium.com/@jeremy_96642/ruby-method-auditing-using-module-prepend-4f4e69aacd95)
  # constructor.
  #
  # - **Q:** Why is [Module#prepend](https://ruby-doc.org/core-3.0.0/Module.html#method-i-prepend)
  #          important here
  #          ([more info](https://medium.com/@leo_hetsch/ruby-modules-include-vs-prepend-vs-extend-f09837a5b073))?
  # - **A:** To set up *mutable state* inside the instance, even if the original
  #          constructor will then call
  #          [Object#freeze](https://ruby-doc.org/core-3.0.0/Object.html#method-i-freeze).
  #
  # This approach supports memoization on frozen (immutable) objects -- for
  # example, classes created by the
  # [Values](https://github.com/tcrayford/Values)
  # [gem](https://rubygems.org/gems/values).
  #
  # To support syntax differences with keyword and positional arguments starting
  # with ruby 2.7, we have to set up the initializer with some slightly
  # different syntax for the different versions.  This variance in syntax is not
  # included in coverage reports since the branch chosen will never differ
  # within a single ruby version.  This means it is impossible for us to get
  # 100% coverage of this line within a single CI run.
  #
  # See
  # [this article](https://www.ruby-lang.org/en/news/2019/12/12/separation-of-positional-and-keyword-arguments-in-ruby-3-0/)
  # for more information.
  #
  # :nocov:
  all_args = RUBY_VERSION < "2.7" ? "*" : "..."
  # :nocov:
  class_eval <<~HEREDOC, __FILE__, __LINE__ + 1
    # On Ruby 2.7 or greater:
    #
    # def initialize(...)
    #   MemoWise::InternalAPI.create_memo_wise_state!(self)
    #   super
    # end
    #
    # On Ruby 2.6 or lower:
    #
    # def initialize(*)
    #   MemoWise::InternalAPI.create_memo_wise_state!(self)
    #   super
    # end

    def initialize(#{all_args})
      MemoWise::InternalAPI.create_memo_wise_state!(self)
      super
    end
  HEREDOC

  # @private
  #
  # Private setup method, called automatically by `prepend MemoWise` in a class.
  #
  # @param target [Class]
  #   The `Class` into to prepend the MemoWise methods e.g. `memo_wise`
  #
  # @see https://ruby-doc.org/core-3.0.0/Module.html#method-i-prepended
  #
  # @example
  #   class Example
  #     prepend MemoWise
  #   end
  #
  def self.prepended(target)
    class << target
      # Allocator to set up memoization state before
      # [calling the original](https://medium.com/@jeremy_96642/ruby-method-auditing-using-module-prepend-4f4e69aacd95)
      # allocator.
      #
      # This is necessary in addition to the `#initialize` method definition
      # above because
      # [`Class#allocate`](https://ruby-doc.org/core-3.0.0/Class.html#method-i-allocate)
      # bypasses `#initialize`, and when it's used (e.g.,
      # [in ActiveRecord](https://github.com/rails/rails/blob/a395c3a6af1e079740e7a28994d77c8baadd2a9d/activerecord/lib/active_record/persistence.rb#L411))
      # we still need to be able to access MemoWise's instance variable. Despite
      # Ruby documentation indicating otherwise, `Class#new` does not call
      # `Class#allocate`, so we need to override both.
      #
      def allocate
        MemoWise::InternalAPI.create_memo_wise_state!(super)
      end

      # NOTE: See YARD docs for {.memo_wise} directly below this method!
      def memo_wise(method_name_or_hash)
        klass = self
        case method_name_or_hash
        when Symbol
          method_name = method_name_or_hash

          if klass.singleton_class?
            MemoWise::InternalAPI.create_memo_wise_state!(
              MemoWise::InternalAPI.original_class_from_singleton(klass)
            )
          end

          # Ensures a module extended by another class/module still works
          # e.g. rails `ClassMethods` module
          if klass.is_a?(Module) && !klass.is_a?(Class)
            # Using `extended` without `included` & `prepended`
            # As a call to `create_memo_wise_state!` is already included in
            # `.allocate`/`#initialize`
            #
            # But a module/class extending another module with memo_wise
            # would not call `.allocate`/`#initialize` before calling methods
            #
            # On method call `@_memo_wise` would still be `nil`
            # causing error when fetching cache from `@_memo_wise`
            def klass.extended(base)
              MemoWise::InternalAPI.create_memo_wise_state!(base)
            end
          end
        when Hash
          unless method_name_or_hash.keys == [:self]
            raise ArgumentError,
                  "`:self` is the only key allowed in memo_wise"
          end

          method_name = method_name_or_hash[:self]

          MemoWise::InternalAPI.create_memo_wise_state!(self)

          # In Ruby, "class methods" are implemented as normal instance methods
          # on the "singleton class" of a given Class object, found via
          # {Class#singleton_class}.
          # See: https://medium.com/@leo_hetsch/demystifying-singleton-classes-in-ruby-caf3fa4c9d91
          klass = klass.singleton_class
        end

        if klass.singleton_class?
          # This ensures that a memoized method defined on a parent class can
          # still be used in a child class.
          klass.module_eval <<~HEREDOC, __FILE__, __LINE__ + 1
            def inherited(subclass)
              super
              MemoWise::InternalAPI.create_memo_wise_state!(subclass)
            end
          HEREDOC
        end

        raise ArgumentError, "#{method_name.inspect} must be a Symbol" unless method_name.is_a?(Symbol)

        visibility = MemoWise::InternalAPI.method_visibility(klass, method_name)
        original_memo_wised_name = MemoWise::InternalAPI.original_memo_wised_name(method_name)
        method = klass.instance_method(method_name)

        klass.send(:alias_method, original_memo_wised_name, method_name)
        klass.send(:private, original_memo_wised_name)

        method_arguments = MemoWise::InternalAPI.method_arguments(method)

        case method_arguments
        when MemoWise::InternalAPI::NONE
          # Zero-arg methods can use simpler/more performant logic because the
          # hash key is just the method name.
          klass.send(:define_method, method_name) do # Ruby 2.4's `define_method` is private in some cases
            index = MemoWise::InternalAPI.index(self, method_name)
            klass.module_eval <<~HEREDOC, __FILE__, __LINE__ + 1
              def #{method_name}
                if @_memo_wise_sentinels[#{index}]
                  @_memo_wise[#{index}]
                else
                  ret = @_memo_wise[#{index}] = #{original_memo_wised_name}
                  @_memo_wise_sentinels[#{index}] = true
                  ret
                end
              end
            HEREDOC

            klass.send(visibility, method_name)
            send(method_name)
          end
        when MemoWise::InternalAPI::ONE_REQUIRED_POSITIONAL, MemoWise::InternalAPI::ONE_REQUIRED_KEYWORD
          key = method.parameters.first.last
          # NOTE: Ruby 2.6 and below, and TruffleRuby 3.0, break when we use
          # `define_method(...) do |*args, **kwargs|`. Instead we must use the
          # simpler `|*args|` pattern. We can't just do this always though
          # because Ruby 2.7 and above require `|*args, **kwargs|` to work
          # correctly.
          # See: https://blog.saeloun.com/2019/10/07/ruby-2-7-keyword-arguments-redesign.html#ruby-26
          # :nocov:
          if RUBY_VERSION < "2.7" || RUBY_ENGINE == "truffleruby"
            klass.send(:define_method, method_name) do |*args| # Ruby 2.4's `define_method` is private in some cases
              index = MemoWise::InternalAPI.index(self, method_name)
              klass.module_eval <<~HEREDOC, __FILE__, __LINE__ + 1
                def #{method_name}(#{MemoWise::InternalAPI.args_str(method)})
                  _memo_wise_hash = (@_memo_wise[#{index}] ||= {})
                  _memo_wise_output = _memo_wise_hash[#{key}]
                  if _memo_wise_output || _memo_wise_hash.key?(#{key})
                    _memo_wise_output
                  else
                    _memo_wise_hash[#{key}] = #{original_memo_wised_name}(#{MemoWise::InternalAPI.call_str(method)})
                  end
                end
              HEREDOC

              klass.send(visibility, method_name)
              send(method_name, *args)
            end
            # :nocov:
          else
            klass.define_method(method_name) do |*args, **kwargs|
              index = MemoWise::InternalAPI.index(self, method_name)
              klass.module_eval <<~HEREDOC, __FILE__, __LINE__ + 1
                def #{method_name}(#{MemoWise::InternalAPI.args_str(method)})
                  _memo_wise_hash = (@_memo_wise[#{index}] ||= {})
                  _memo_wise_output = _memo_wise_hash[#{key}]
                  if _memo_wise_output || _memo_wise_hash.key?(#{key})
                    _memo_wise_output
                  else
                    _memo_wise_hash[#{key}] = #{original_memo_wised_name}(#{MemoWise::InternalAPI.call_str(method)})
                  end
                end
              HEREDOC

              klass.send(visibility, method_name)
              send(method_name, *args, **kwargs)
            end
          end
        # MemoWise::InternalAPI::MULTIPLE_REQUIRED, MemoWise::InternalAPI::SPLAT,
        # MemoWise::InternalAPI::DOUBLE_SPLAT, MemoWise::InternalAPI::SPLAT_AND_DOUBLE_SPLAT
        else
          # NOTE: When benchmarking this implementation against something like:
          #
          #   @_memo_wise.fetch(key) do
          #     ...
          #   end
          #
          # this implementation may sometimes perform worse than the above. This
          # is because this case uses a more complex hash key (see
          # `MemoWise::InternalAPI.key_str`), and hashing that key has less
          # consistent performance. In general, this should still be faster for
          # truthy results because `Hash#[]` generally performs hash lookups
          # faster than `Hash#fetch`.
          #
          # NOTE: Ruby 2.6 and below, and TruffleRuby 3.0, break when we use
          # `define_method(...) do |*args, **kwargs|`. Instead we must use the
          # simpler `|*args|` pattern. We can't just do this always though
          # because Ruby 2.7 and above require `|*args, **kwargs|` to work
          # correctly.
          # See: https://blog.saeloun.com/2019/10/07/ruby-2-7-keyword-arguments-redesign.html#ruby-26
          # :nocov:
          if RUBY_VERSION < "2.7" || RUBY_ENGINE == "truffleruby"
            klass.send(:define_method, method_name) do |*args| # Ruby 2.4's `define_method` is private in some cases
              index = MemoWise::InternalAPI.index(self, method_name)
              klass.module_eval <<~HEREDOC, __FILE__, __LINE__ + 1
                def #{method_name}(#{MemoWise::InternalAPI.args_str(method)})
                  _memo_wise_hash = (@_memo_wise[#{index}] ||= {})
                  _memo_wise_key = #{MemoWise::InternalAPI.key_str(method)}
                  _memo_wise_output = _memo_wise_hash[_memo_wise_key]
                  if _memo_wise_output || _memo_wise_hash.key?(_memo_wise_key)
                    _memo_wise_output
                  else
                    _memo_wise_hash[_memo_wise_key] = #{original_memo_wised_name}(#{MemoWise::InternalAPI.call_str(method)})
                  end
                end
              HEREDOC

              klass.send(visibility, method_name)
              send(method_name, *args)
            end
            # :nocov:
          else # Ruby 2.7 and above break with (*args)
            klass.define_method(method_name) do |*args, **kwargs|
              index = MemoWise::InternalAPI.index(self, method_name)
              klass.module_eval <<~HEREDOC, __FILE__, __LINE__ + 1
                def #{method_name}(#{MemoWise::InternalAPI.args_str(method)})
                  _memo_wise_hash = (@_memo_wise[#{index}] ||= {})
                  _memo_wise_key = #{MemoWise::InternalAPI.key_str(method)}
                  _memo_wise_output = _memo_wise_hash[_memo_wise_key]
                  if _memo_wise_output || _memo_wise_hash.key?(_memo_wise_key)
                    _memo_wise_output
                  else
                    _memo_wise_hash[_memo_wise_key] = #{original_memo_wised_name}(#{MemoWise::InternalAPI.call_str(method)})
                  end
                end
              HEREDOC

              klass.send(visibility, method_name)
              send(method_name, *args, **kwargs)
            end
          end
        end

        klass.send(visibility, method_name)
      end
    end

    unless target.singleton_class?
      # Create class methods to implement .preset_memo_wise and .reset_memo_wise
      %i[preset_memo_wise reset_memo_wise].each do |method_name|
        # Like calling 'module_function', but original method stays public
        target.define_singleton_method(
          method_name,
          MemoWise.instance_method(method_name)
        )
      end

      # Override [Module#instance_method](https://ruby-doc.org/core-3.0.0/Module.html#method-i-instance_method)
      # to proxy the original `UnboundMethod#parameters` results. We want the
      # parameters to reflect the original method in order to support callers
      # who want to use Ruby reflection to process the method parameters,
      # because our overridden `#initialize` method, and in some cases the
      # generated memoized methods, will have a generic set of parameters
      # (`...` or `*args, **kwargs`), making reflection on method parameters
      # useless without this.
      def target.instance_method(symbol)
        original_memo_wised_name = MemoWise::InternalAPI.original_memo_wised_name(symbol)

        super.tap do |curr_method|
          # Start with calling the original `instance_method` on `symbol`,
          # which returns an `UnboundMethod`.
          #   IF it was replaced by MemoWise,
          #   THEN find the original method's parameters, and modify current
          #        `UnboundMethod#parameters` to return them.
          if symbol == :initialize
            # For `#initialize` - because `prepend MemoWise` overrides the same
            # method in the module ancestors, use `UnboundMethod#super_method`
            # to find the original method.
            orig_method = curr_method.super_method
            orig_params = orig_method.parameters
            curr_method.define_singleton_method(:parameters) { orig_params }
          elsif private_method_defined?(original_memo_wised_name)
            # For any memoized method - because the original method was renamed,
            # call the original `instance_method` again to find the renamed
            # original method.
            orig_method = super(original_memo_wised_name)
            orig_params = orig_method.parameters
            curr_method.define_singleton_method(:parameters) { orig_params }
          end
        end
      end
    end
  end

  ##
  # @!method self.memo_wise(method_name)
  #   Implements memoization for the given method name.
  #
  #   - **Q:** What does it mean to "implement memoization"?
  #   - **A:** To wrap the original method such that, for any given set of
  #            arguments, the original method will be called at most *once*. The
  #            result of that call will be stored on the object. All future
  #            calls to the same method with the same set of arguments will then
  #            return that saved result.
  #
  #   Methods which implicitly or explicitly take block arguments cannot be
  #   memoized.
  #
  #   @param method_name [Symbol]
  #     Name of method for which to implement memoization.
  #
  #   @return [void]
  #
  #   @example
  #     class Example
  #       prepend MemoWise
  #
  #       def method_to_memoize(x)
  #         @method_called_times = (@method_called_times || 0) + 1
  #       end
  #       memo_wise :method_to_memoize
  #     end
  #
  #     ex = Example.new
  #
  #     ex.method_to_memoize("a") #=> 1
  #     ex.method_to_memoize("a") #=> 1
  #
  #     ex.method_to_memoize("b") #=> 2
  #     ex.method_to_memoize("b") #=> 2
  ##

  ##
  # @!method self.preset_memo_wise(method_name, *args, **kwargs)
  #   Implementation of {#preset_memo_wise} for class methods.
  #
  #   @example
  #     class Example
  #       prepend MemoWise
  #
  #       def self.method_called_times
  #         @method_called_times
  #       end
  #
  #       def self.method_to_preset
  #         @method_called_times = (@method_called_times || 0) + 1
  #         "A"
  #       end
  #       memo_wise self: :method_to_preset
  #     end
  #
  #     Example.preset_memo_wise(:method_to_preset) { "B" }
  #
  #     Example.method_to_preset #=> "B"
  #
  #     Example.method_called_times #=> nil
  ##

  ##
  # @!method self.reset_memo_wise(method_name = nil, *args, **kwargs)
  #   Implementation of {#reset_memo_wise} for class methods.
  #
  #   @example
  #     class Example
  #       prepend MemoWise
  #
  #       def self.method_to_reset(x)
  #         @method_called_times = (@method_called_times || 0) + 1
  #       end
  #       memo_wise self: :method_to_reset
  #     end
  #
  #     Example.method_to_reset("a") #=> 1
  #     Example.method_to_reset("a") #=> 1
  #     Example.method_to_reset("b") #=> 2
  #     Example.method_to_reset("b") #=> 2
  #
  #     Example.reset_memo_wise(:method_to_reset, "a") # reset "method + args" mode
  #
  #     Example.method_to_reset("a") #=> 3
  #     Example.method_to_reset("a") #=> 3
  #     Example.method_to_reset("b") #=> 2
  #     Example.method_to_reset("b") #=> 2
  #
  #     Example.reset_memo_wise(:method_to_reset) # reset "method" (any args) mode
  #
  #     Example.method_to_reset("a") #=> 4
  #     Example.method_to_reset("b") #=> 5
  #
  #     Example.reset_memo_wise # reset "all methods" mode
  ##

  # Presets the memoized result for the given method to the result of the given
  # block.
  #
  # This method is for situations where the caller *already* has the result of
  # an expensive method call, and wants to preset that result as memoized for
  # future calls. In other words, the memoized method will be called *zero*
  # times rather than once.
  #
  # NOTE: Currently, no attempt is made to validate that the given arguments are
  # valid for the given method.
  #
  # @param method_name [Symbol]
  #   Name of a method previously set up with `#memo_wise`.
  #
  # @param args [Array]
  #   (Optional) If the method takes positional args, these are the values of
  #   position args for which the given block's result will be preset as the
  #   memoized result.
  #
  # @param kwargs [Hash]
  #   (Optional) If the method takes keyword args, these are the keys and values
  #   of keyword args for which the given block's result will be preset as the
  #   memoized result.
  #
  # @yieldreturn [Object]
  #   The result of the given block will be preset as memoized for future calls
  #   to the given method.
  #
  # @return [void]
  #
  # @example
  #   class Example
  #     prepend MemoWise
  #     attr_reader :method_called_times
  #
  #     def method_to_preset
  #       @method_called_times = (@method_called_times || 0) + 1
  #       "A"
  #     end
  #     memo_wise :method_to_preset
  #   end
  #
  #   ex = Example.new
  #
  #   ex.preset_memo_wise(:method_to_preset) { "B" }
  #
  #   ex.method_to_preset #=> "B"
  #
  #   ex.method_called_times #=> nil
  #
  def preset_memo_wise(method_name, *args, **kwargs)
    raise ArgumentError, "Pass a block as the value to preset for #{method_name}, #{args}" unless block_given?

    MemoWise::InternalAPI.validate_memo_wised!(self, method_name)

    method = method(MemoWise::InternalAPI.original_memo_wised_name(method_name))
    method_arguments = MemoWise::InternalAPI.method_arguments(method)
    index = MemoWise::InternalAPI.index(self, method_name)

    if method_arguments == MemoWise::InternalAPI::NONE
      @_memo_wise_sentinels[index] = true
      @_memo_wise[index] = yield
      return
    end

    hash = (@_memo_wise[index] ||= {})

    case method_arguments
    when MemoWise::InternalAPI::ONE_REQUIRED_POSITIONAL then hash[args.first] = yield
    when MemoWise::InternalAPI::ONE_REQUIRED_KEYWORD then hash[kwargs.first.last] = yield
    when MemoWise::InternalAPI::SPLAT then hash[args] = yield
    when MemoWise::InternalAPI::DOUBLE_SPLAT then hash[kwargs] = yield
    when MemoWise::InternalAPI::MULTIPLE_REQUIRED
      key = method.parameters.map.with_index do |(type, name), idx|
        type == :req ? args[idx] : kwargs[name]
      end
      hash[key] = yield
    else # MemoWise::InternalAPI::SPLAT_AND_DOUBLE_SPLAT
      hash[[args, kwargs]] = yield
    end
  end

  # Resets memoized results of a given method, or all methods.
  #
  # There are three _reset modes_ depending on how this method is called:
  #
  # **method + args** mode (most specific)
  #
  # - If given `method_name` and *either* `args` *or* `kwargs` *or* both:
  # - Resets *only* the memoized result of calling `method_name` with those
  #   particular arguments.
  #
  # **method** (any args) mode
  #
  # - If given `method_name` and *neither* `args` *nor* `kwargs`:
  # - Resets *all* memoized results of calling `method_name` with any arguments.
  #
  # **all methods** mode (most general)
  #
  # - If *not* given `method_name`:
  # - Resets all memoized results of calling *all methods*.
  #
  # @param method_name [Symbol, nil]
  #   (Optional) Name of a method previously set up with `#memo_wise`. If not
  #   given, will reset *all* memoized results for *all* methods.
  #
  # @param args [Array]
  #   (Optional) If the method takes positional args, these are the values of
  #   position args for which the memoized result will be reset.
  #
  # @param kwargs [Hash]
  #   (Optional) If the method takes keyword args, these are the keys and values
  #   of keyword args for which the memoized result will be reset.
  #
  # @return [void]
  #
  # @example
  #   class Example
  #     prepend MemoWise
  #
  #     def method_to_reset(x)
  #       @method_called_times = (@method_called_times || 0) + 1
  #     end
  #     memo_wise :method_to_reset
  #   end
  #
  #   ex = Example.new
  #
  #   ex.method_to_reset("a") #=> 1
  #   ex.method_to_reset("a") #=> 1
  #   ex.method_to_reset("b") #=> 2
  #   ex.method_to_reset("b") #=> 2
  #
  #   ex.reset_memo_wise(:method_to_reset, "a") # reset "method + args" mode
  #
  #   ex.method_to_reset("a") #=> 3
  #   ex.method_to_reset("a") #=> 3
  #   ex.method_to_reset("b") #=> 2
  #   ex.method_to_reset("b") #=> 2
  #
  #   ex.reset_memo_wise(:method_to_reset) # reset "method" (any args) mode
  #
  #   ex.method_to_reset("a") #=> 4
  #   ex.method_to_reset("b") #=> 5
  #
  #   ex.reset_memo_wise # reset "all methods" mode
  #
  def reset_memo_wise(method_name = nil, *args, **kwargs)
    if method_name.nil?
      raise ArgumentError, "Provided args when method_name = nil" unless args.empty?
      raise ArgumentError, "Provided kwargs when method_name = nil" unless kwargs.empty?

      @_memo_wise.clear
      @_memo_wise_sentinels.clear
      return
    end

    raise ArgumentError, "#{method_name.inspect} must be a Symbol" unless method_name.is_a?(Symbol)
    raise ArgumentError, "#{method_name} is not a defined method" unless respond_to?(method_name, true)

    MemoWise::InternalAPI.validate_memo_wised!(self, method_name)

    method = method(MemoWise::InternalAPI.original_memo_wised_name(method_name))
    method_arguments = MemoWise::InternalAPI.method_arguments(method)
    index = MemoWise::InternalAPI.index(self, method_name)

    case method_arguments
    when MemoWise::InternalAPI::NONE
      @_memo_wise_sentinels[index] = nil
      @_memo_wise[index] = nil
    when MemoWise::InternalAPI::ONE_REQUIRED_POSITIONAL
      if args.empty?
        @_memo_wise[index]&.clear
      else
        @_memo_wise[index]&.delete(args.first)
      end
    when MemoWise::InternalAPI::ONE_REQUIRED_KEYWORD
      if kwargs.empty?
        @_memo_wise[index]&.clear
      else
        @_memo_wise[index]&.delete(kwargs.first.last)
      end
    when MemoWise::InternalAPI::SPLAT
      if args.empty?
        @_memo_wise[index]&.clear
      else
        @_memo_wise[index]&.delete(args)
      end
    when MemoWise::InternalAPI::DOUBLE_SPLAT
      if kwargs.empty?
        @_memo_wise[index]&.clear
      else
        @_memo_wise[index]&.delete(kwargs)
      end
    else # MemoWise::InternalAPI::MULTIPLE_REQUIRED, MemoWise::InternalAPI::SPLAT_AND_DOUBLE_SPLAT
      if args.empty? && kwargs.empty?
        @_memo_wise[index]&.clear
      else
        key = if method_arguments == MemoWise::InternalAPI::SPLAT_AND_DOUBLE_SPLAT
                [args, kwargs]
              else
                method.parameters.map.with_index do |(type, name), i|
                  type == :req ? args[i] : kwargs[name] # rubocop:disable Metrics/BlockNesting
                end
              end
        @_memo_wise[index]&.delete(key)
      end
    end
  end
end

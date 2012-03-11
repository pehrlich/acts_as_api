module ActsAsApi
  # Represents an api template for a model.
  # This class should not be initiated by yourself, api templates
  # are created by defining them in the model by calling: +api_accessible+.
  #
  # The api template is configured in the block passed to +api_accessible+.
  #
  # Please note that +ApiTemplate+ inherits from +Hash+ so you can use all
  # kind of +Hash+ and +Enumerable+ methods to manipulate the template.
  class ApiTemplate < Hash

    # The name of the api template as a Symbol.
    attr_accessor :api_template

    attr_reader :options

    # Returns a new ApiTemplate with the api template name
    # set to the passed template.
    def self.create(template)
      t = ApiTemplate.new
      t.api_template = template
      return t
    end

    def initialize
      @options ||= {}
    end

    def merge!(other_hash, &block)
      super
      self.options.merge!(other_hash.options) if other_hash.respond_to?(:options)
    end

    # Adds a field to the api template
    #
    # The value passed can be one of the following:
    #  * Symbol - the method with the same name will be called on the model when rendering.
    #  * String - must be in the form "method1.method2.method3", will call this method chain.
    #  * Hash - will be added as a sub hash and all its items will be resolved the way described above.
    #
    # Possible options to pass:
    #  * :template - Determine the template that should be used to render the item if it is
    #    +api_accessible+ itself.
    def add(val, options = {})
      field = (options[:as] || val).to_sym

      self[field] = val

      @options[field] = options
    end

    def add?(val, options = {})
      self.add val, options.merge({try: true})
    end

    def add_with_context(val, options={})
      self.add val, options.merge({pass_context: true})
    end

    def in_this_context(val, options={})
      self.add val, options.merge({pass_context: self})
    end

    # Removes a field from the template
    def remove(field)
      self.delete(field)
      @options.delete(field)
    end

    # Returns the options of a field in the api template
    def options_for(field)
      @options[field]
    end

    # Returns the passed option of a field in the api template
    def option_for(field, option)
      @options[field][option] if @options[field]
    end

    # If a special template name for the passed item is specified
    # it will be returned, if not the original api template.
    def api_template_for(fieldset, field)
      return api_template unless fieldset.is_a? ActsAsApi::ApiTemplate
      fieldset.option_for(field, :template) || api_template
    end

    # Decides if the passed item should be added to
    # the response based on the conditional options passed.
    def allowed_to_render?(fieldset, field, model)
      return true unless fieldset.is_a? ActsAsApi::ApiTemplate
      allowed = true
      allowed = condition_fulfilled?(model, fieldset.option_for(field, :if)) if fieldset.option_for(field, :if)
      allowed = !(condition_fulfilled?(model, fieldset.option_for(field, :unless))) if fieldset.option_for(field, :unless)
      return allowed
    end

    # Checks if a condition is fulfilled
    # (result is not nil or false)
    def condition_fulfilled?(model, condition)
      case condition
        when Symbol
          result = model.send(condition)
        when Proc
          result = condition.call(model)
      end
      !result.nil? && !result.is_a?(FalseClass)
    end

    # Generates a hash that represents the api response based on this
    # template for the passed model instance.
    def to_response_hash(model, context = nil)
      #p context
      queue = []
      api_output = {}

      queue << {:output => api_output, :item => self}

      until queue.empty? do
        leaf = queue.pop
        fieldset = leaf[:item]

        fieldset.each do |field, value|
          next unless allowed_to_render?(fieldset, field, model)

          options = options_for(field) || {}
          #p "reading options for fieldset #{field}"
          #p options

          if options[:pass_context] == true
            options[:context] = context
          elsif options[:pass_context]
            options[:context] = options[:pass_context]
          end

          case value
            when Symbol
              if model.respond_to?(value)
                out = send_with_context(model, value, options)
              end

            when Proc
              # todo: pass [model, context] in to proc
              out = value.call(model)
            #out = send_with_context(value, options)

            when String
              # go up the call chain
              out = model

              # only send context to last method
              method_ids = value.split(".").map(&:to_sym)
              last_method = method_ids.pop

              if options[:try]
                method_ids.each { |method| out = out.send method if out }
              else
                method_ids.each { |method| out = out.send method }
              end

              out = send_with_context(out, last_method, options)


            when Hash
              leaf[:output][field] ||= {}
              queue << {:output => leaf[:output][field], :item => value}
              next
          end

          if out.respond_to?(:as_api_response)
            sub_template = api_template_for(fieldset, field)
            out = out.send(:as_api_response, sub_template, context)
          end

          leaf[:output][field] = out
        end

      end

      api_output
    end

    protected

    # todo: it would be more fun to detect if arguments accepted, and pass in context if provided
    # it would probably be best to only send context that require it, rather than ones that could accept it,
    # as this behavior could still be unexpected
    # unless explicitly set otherwise (with_context: false).  This would do-in with the need for our custom add_with_context

    def send_with_context(object_or_method, method_id, options = {})
      #p "send with context"
      #p object_or_method
      #p method_id

      if [Method, Proc].include? object_or_method.class
        # in the case of procs, there is no object receiver
        method = object_or_method
        options = method_id
      else
        if options[:try] && !object_or_method
          p "API#add?: nil receiver for method, ok: #{method_id}"
          return nil
        end
        begin
          method = object_or_method.method(method_id)
        rescue NoMethodError => e
          p "API#add?: receiver yes, method no"
          if options[:try]
            return nil
          end
        end
      end


      if options[:pass_context]

        # we can't check arity because that would make method_missing fail
        # todo: catch wrong number of arguments exceptions, and display the same info
        #if method.arity == 0 # note: arity returns negative number if variable arguments
        #  raise "Trying to pass context #{context} to #{object.class}##{method_id}, but it doesn't accept arguments"
        #end
        begin
          method.call options[:context]
        rescue ArgumentError => e
          throw "#{method} sent context, not ok. (#{e.message})"
        end


      else

        #p "sending #{object} #{method_id}"

        #unless method.arity == 0 # note: arity returns negative number if variable arguments
        #  raise "#{object.class}##{method_id}, demands context, but none specified"
        #end

        begin
          method.call
            # todo: the following doesn't catch shit.
            # http://ruby-doc.org/docs/ProgrammingRuby/html/tut_exceptions.html
        rescue ArgumentError => e
          # for some reason, this is catching recursive versions of itself. lame.
          p e.backtrace.join('\n')
          throw "#{method} requires context to be sent. (#{e.message})"
            #throw "#{method} requires context to be sent. (#{e.backtrace.join('\n')})"
        rescue NameError => e
          p e.backtrace.join('\n')
          message = object_or_method ? "#{object_or_method.class}" : ''
          message << "##{method.name.to_s}: `#{e.message}`"
          #message << "##{method.name.to_s}: `#{e.backtrace.join('\n')}`"
          throw message
        end

      end
    end


  end
end

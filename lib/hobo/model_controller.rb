module Hobo

  module ModelController

    include Hobo::Controller

    class PermissionDeniedError < RuntimeError; end

    VIEWLIB_DIR = "hobolib"
    
    GENERIC_PAGE_TAGS = [:index, :show, :new, :edit, :show_collection, :new_in_collection]

    class << self

      def included(base)
        base.extend(ClassMethods)
        base.helper_method(:find_partial, :model, :current_user)

        Hobo::ControllerHelpers.public_instance_methods.each {|m| base.hide_action(m)}

        add_collection_actions(base)

        base.before_filter :set_no_cache_headers
      end

      def find_partial(klass, as)
        find_model_template(klass, as, true)
      end


      def template_path(dir, name, is_partial)
        fileRx = is_partial ? /^_#{name}\.[^.]+/ : /^#{name}\.[^.]+/
        unless Dir.entries("#{RAILS_ROOT}/app/views/#{dir}").grep(fileRx).empty?
          return "#{dir}/#{name}"
        end
      end


      def find_model_template(klass, name, is_partial=false)
        while klass and klass != ActiveRecord::Base
          dir = klass.name.underscore.pluralize
          path = template_path(dir, name, is_partial)
          return path if path

          klass = klass.superclass
        end
        nil
      end


      private


      def add_collection_actions(controller_class)
        for refl in controller_class.model.reflections.values.oselect{macro == :has_many}
          show_method = "show_#{refl.name}"
          if show_method.not_in?(controller_class.instance_methods)
            controller_class.class_eval <<-END, __FILE__, __LINE__+1
              def #{show_method}
                @owner = find_instance
                @association = @owner.#{refl.name}
                @pages = ::ActionController::Pagination::Paginator.new(self, @association.size, 20, params[:page])
                options = { :limit  =>  @pages.items_per_page, :offset =>  @pages.current.offset }
                @this = @association.find(:all, options)
                @this = @this.uniq if @association.proxy_reflection.options[:uniq]
                hobo_render(:#{show_method}) or hobo_render(:show_collection, @association.member_class)
              end
            END
          end
          new_method = "new_#{refl.name.to_s.singularize}"
          if Hobo.simple_has_many_association?(refl) and new_method.not_in?(controller_class.instance_methods)
            controller_class.class_eval <<-END, __FILE__, __LINE__+1
              def #{new_method}
                @owner = find_instance
                @this = @owner.#{refl.name}.new_without_appending
                @this.created_by(current_user)
                hobo_render(:#{new_method}) or hobo_render(:new_in_collection, @this.class)
              end
            END
          end
        end
      end


    end

    module ClassMethods

      attr_writer :model
      
      def web_methods
        @web_methods ||= []
      end
      
      def show_methods
        @show_methods ||= []
      end

      def model
        @model ||= name.sub(/Controller$/, "").singularize.constantize
      end


      def autocomplete_for(attr, options={})
        opts = { :limit => 15 }.update(options)
        @completers ||= {}
        @completers[attr.to_sym] = opts
      end


      def autocompleter(name)
        (@completers && @completers[name]) ||
          (superclass.respond_to?(:autocompleter) && superclass.autocompleter(name))
      end


      def def_data_filter(name, &b)
        @data_filters ||= {}
        @data_filters[name] = b
      end
      
      
      def web_method(web_name, method_name=nil)
        method_name ||= web_name
        web_methods << web_name.to_sym
        before_filter(:only => [web_name]) {|controller| controller.send(:prepare_web_method, method_name)}
      end
      
      
      def show_method(*names)
        show_methods.concat(names)
        for name in names
          class_eval "def #{name}; show; end"
        end
      end
      
      
      def data_filter(name)
        (@data_filters && @data_filters[name]) ||
          (superclass.respond_to?(:data_filter) && superclass.data_filter(name))
      end


      def find_instance(id)
        if model.id_name? and id !~ /^\d+$/
          model.find_by_id_name(id)
        else
          model.find(id)
        end
      end

    end

    # --- ACTIONS --- #

    def index
      @model = model
      count = count_with_data_filter
      @pages = ::ActionController::Pagination::Paginator.new(self, count, 20, params[:page])
      options = { :limit  =>  @pages.items_per_page, :offset =>  @pages.current.offset, :order => :default }
      @this = find_with_data_filter(options)
      hobo_render
    end


    def show
      @this = find_instance
      if @this
        if Hobo.can_view?(current_user, @this)
          hobo_render
        else
          permission_denied
        end
      else
        render :text => "Can't find #{model.name.titleize}: #{params[:id]}", :status => 404
      end
    end


    def new
      @this = model.new
      @this.created_by(current_user)
      hobo_render
    end


    def create
      begin
        @this = new_from_params(model, params[model.name.underscore])
      rescue PermissionDeniedError
        permission_denied and return
      end

      if @this.save
        respond_to do |wants|
          wants.html do
            create_response
            redirect_to object_url(@this) unless performed?
          end

          wants.js   { hobo_ajax_response(@this) or render :text => "" }
        end
      else
        # Validation errors
        respond_to do |wants|
          wants.html do
            invalid_create_response
            hobo_render :new unless performed?
          end

          wants.js do
            render(:status => 500,
                   :text => "There was a problem creating that #{model.name}.\n" +
                            @this.errors.full_messages.join("\n"))
          end
        end
      end
    end


    def edit
      @this = find_instance
      hobo_render
    end


    def update
      @this = find_instance
      original = @this.duplicate
      changes = params[model.name.underscore]
      update_with_params(@this, changes)
      permission_denied and return unless Hobo.can_update?(current_user, original, @this)
      if @this.save
        respond_to do |wants|
          wants.html do
            update_response
            redirect_to object_url(@this) unless performed?
          end

          wants.js   do
            if hobo_ajax_response(@this)
              # ok we're done then
            elsif changes.size == 1
              # Slightly hacky support for the scriptaculous in-place-editor
              render_tag("show", :obj => @this, :attr => changes.keys.first)
            else
              # we don't expect this, but it's not really an error
              render :text => ""
            end
          end
        end
      else
        # Validation errors
        respond_to do |wants|
          wants.html do
            invalid_update_response
            render :action => :edit unless performed?
          end

          wants.js do
            # Temporary hack
            render(:status => 500,
                   :text => ("There was a problem with that update.\n" +
                             @this.errors.full_messages.join("\n")))
          end
        end
      end
    end


    def destroy
      @this = find_instance
      permission_denied and return unless Hobo.can_delete?(current_user, @this)

      @this.destroy

      respond_to do |wants|
        wants.html do
          destroy_response
          redirect_to :action => "index" unless performed?
        end
        wants.js { hobo_ajax_response(@this) or render :text => "" }
      end
    end


    def completions
      attr = params[:for]
      opts = attr && self.class.autocompleter(attr.to_sym)
      if opts
        q = params[:query]
        items = find_with_data_filter(opts) { send("#{attr}_contains", q) }

        render :text => "<ul>\n" + items.map {|i| "<li>#{i.send(attr)}</li>\n"}.join + "</ul>"
      else
        render :text => "No completer for #{attr}", :status => 404
      end
    end


    ###### END OF ACTIONS ######

    protected
    
    # --- hooks --- #
    
    def create_response; end
    
    def invalid_create_response; end
    
    def update_response; end
    
    def invalid_update_response; end
    
    def destroy_response; end 
    
    # --- end hooks --- #
    
    # --- filters --- #
    
    def prepare_web_method(method)
      @this = find_instance
      permission_denied unless Hobo.can_call?(current_user, @this, method)
    end
    
    # --- end filters --- #
    

    def set_no_cache_headers
      headers["Pragma"] = "no-cache"
      #headers["Cache-Control"] = ["must-revalidate", "no-cache", "no-store"]
      #headers["Cache-Control"] = "no-cache"
      headers["Cache-Control"] = "no-store"
      headers["Expires"] ='0'
    end


    def permission_denied
      render :text => "Permission Denied", :status => 403
    end


    def find_instance(id=nil)
      self.class.find_instance(id || params[:id])
    end


    def hobo_render(page_kind = nil, page_model=nil)
      page_kind ||= params[:action].to_sym
      page_model ||= model
      
      template = Hobo::ModelController.find_model_template(page_model, page_kind)

      if template
        render :template => template
        true
      else
        if page_kind.in? GENERIC_PAGE_TAGS
          render_tag("#{page_kind}_page", :obj => @this)
          true
        else
          false
        end
      end
    end


    def model
      self.class.model
    end


    def find_template
      Hobo::ModelController.find_model_template(model, params[:action])
    end


    def with_data_filter(operation, *args, &block)
      filter_param = params.keys.ofind {starts_with? "where_"}
      proc = filter_param && self.class.data_filter(filter_param[6..-1].to_sym)
      if proc
        filter_args = params[filter_param]
        filter_args = [filter_args] unless filter_args.is_a? Array
        model.send(operation, *args) do
          if block
            instance_eval(&block) & instance_exec(*filter_args, &proc)
          else
            instance_exec(*filter_args, &proc)
          end
        end
      else
        if block
          model.send(operation, *args) { instance_eval(&block) }
        else
          model.send(operation, *args)
        end
      end
    end
    
    
    def find_with_data_filter(opts={}, &b)
      with_data_filter(:find, :all, opts, &b)
    end
    
    
    def count_with_data_filter(opts={}, &b)
      with_data_filter(:count, opts, &b)
    end
    

    def new_from_params(model, params)
      obj = model.new
      update_with_params(obj, params)
      obj.created_by(current_user)
      raise PermissionDeniedError.new unless Hobo.can_create?(current_user, obj)
      obj
    end


    def update_with_params(object, params)
      return unless params

      params.each_pair do |field,value|
        field = field.to_sym
        refl = object.class.reflections[field]
        ar_value = if refl
                     if refl.macro == :belongs_to
                       param_to_record(refl.klass, value)

                     elsif Hobo.simple_has_many_association?(refl) and object.new_record?
                       # only populate has_many relationships for new records. For existing
                       # records, AR updates the DB immediately, bypassing Hobo's permission check
                       if value.is_a? Array
                         value.map {|x| param_to_record(refl.klass, x) }
                       else
                         value.keys.every(:to_i).sort.map{|i| param_to_record(refl.klass, value[i.to_s]) }
                       end
                     else
                       raise HoboError.new("association #{refl.name} is not settable via parameters")
                     end
                   else
                     param_to_value(object.class.field_type(field), value)
                   end
        object.send("#{field}=".to_sym, ar_value)
      end
    end

    
    def parse_datetime(s)
      defined?(Chronic) ? Chronic.parse(s) : Time.parse(s)
    end


    def param_to_value(field_type, value)
      case field_type
      when :date
        if value.is_a? Hash
          Date.new(*(%w{year month day}.map{|s| value[s].to_i}))
        elsif value.is_a? String
          dt = parse_datetime(value)
          dt && dt.to_date
        end
      when :datetime
        if value.is_a? Hash
          Time.local(*(%w{year month day hour minute}.map{|s| value[s].to_i}))
        elsif value.is_a? String
          parse_datetime(value)
        end
      else
        # primitive field
        value
      end
    end

    def param_to_record(klass, value)
      if value.is_a? String
        if value.starts_with?('@')
          Hobo.object_from_dom_id(value[1..-1])
        elsif klass.id_name?
          klass.find_by_id_name(value)
        else
          nil
        end
      else
        new_from_params(klass, value)
      end
    end


    def object_from_param(param)
      Hobo.object_from_dom_id(param)
    end


    # debugging support

    def debug(*args)
      logger.debug(args.inspect)
    end

    def stop_with(*args)
      x = args.length == 1 ? args[0] : args
      raise PP.pp(x, "")
    end

  end

end

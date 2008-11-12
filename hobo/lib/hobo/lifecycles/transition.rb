module Hobo

  module Lifecycles

    class Transition < Struct.new(:lifecycle, :name, :who, :start_states, :end_state, :on_transition, :options)

      include Actions


      def initialize(*args)
        super
        self.name = name.to_sym
        start_states.each do |from|
          state = lifecycle.states[from]
          raise ArgumentError, "No such state '#{from}' in #{'name'} transition (#{lifecycle.model.name})" unless state
          state.transitions_out << self
        end
        unless end_state.to_s == "destroy"
          state = lifecycle.states[end_state]
          raise ArgumentError, "No such state '#{end_state}' in '#{name}' transition (#{lifecycle.model.name})" unless state
          state.transitions_in << self
        end
        lifecycle.transitions << self
      end


      def allowed?(record, attributes=nil)
        prepare_and_check!(record, attributes) && true
      end


      def extract_attributes(attributes)
        update_attributes = options.fetch(:update, [])
        attributes & update_attributes
      end


      def run!(record, user, attributes)
        record.lifecycle.active_step = self
        record.with_acting_user(user) do
          if prepare_and_check!(record, attributes)
            if record.lifecycle.become end_state
              fire_event(record, on_transition)
            end
          else
            raise Hobo::Model::PermissionDeniedError
          end
        end
      end


      def set_or_check_who_with_key!(record)
        if who == :with_key
          record.lifecycle.valid_key? or raise LifecycleKeyError
        else
          set_or_check_who_without_key!(record)
        end
      end
      alias_method_chain :set_or_check_who!, :key


      def parameters
        options[:update] || []
      end


    end

  end

end

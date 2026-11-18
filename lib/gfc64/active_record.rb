# frozen_string_literal: true

class GFC64
  # Deprecated: GFC64::Model (has_public_id / has_code) replaces this; it is
  # kept so 0.1.0 apps keep working.
  module ActiveRecord
    def self.[](gfc)
      Module.new do
        include ActiveRecord

        define_singleton_method :included do |klass|
          klass.extend(ClassMethods)
          klass.send(:include, InstanceMethods)
          klass.f_gfc = gfc
        end
      end
    end

    module ClassMethods
      attr_accessor :f_gfc

      def gfc
        @gfc ||= f_gfc.respond_to?(:call) ? f_gfc.call : f_gfc
      end

      # Accepts the String from params; a bad or out-of-range value raises
      # ActiveRecord::RecordNotFound (404) instead of ArgumentError (500).
      def find_gfc(gfc_id)
        id = gfc.decrypt(Integer(gfc_id.to_s, 10))
        find(id)
      rescue ArgumentError, TypeError
        raise ::ActiveRecord::RecordNotFound, "Couldn't find #{name} with gfc id #{gfc_id.to_s[0, 64].inspect}"
      end
    end

    module InstanceMethods
      def gfc_id
        id && self.class.gfc.encrypt(id)
      end

      def to_param
        gfc_id.to_s
      end
    end
  end
end

class GFC64
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

      def find_gfc(gfc_id)
        find(gfc.decrypt(gfc_id))
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

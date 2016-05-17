module VagrantReflect
  module Configuration
    # Configuration object for vagrant-reflect
    class Reflect < Vagrant.plugin('2', :config)
      attr_accessor :show_sync_time

      def initialize
        @show_sync_time = UNSET_VALUE
      end

      def finalize!
        @show_sync_time = 0 if @show_sync_time == UNSET_VALUE
      end

      def validate(_)
        errors = _detected_errors
        if show_sync_time != true && show_sync_time != false
          errors << 'show_sync_time must be TRUE or FALSE'
        end

        { 'reflect' => errors }
      end
    end
  end
end

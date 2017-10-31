module VagrantReflect
  module Configuration
    # Configuration object for vagrant-reflect
    class Reflect < Vagrant.plugin('2', :config)
      attr_accessor :show_sync_time
      attr_accessor :show_notification

      def initialize
        @show_sync_time = UNSET_VALUE
        @show_notification = UNSET_VALUE
      end

      def finalize!
        @show_sync_time = 0 if @show_sync_time == UNSET_VALUE
        @show_notification = 0 if @show_notification == UNSET_VALUE
      end
    end
  end
end

require 'log4r'
require 'optparse'
require 'thread'
require 'date'

require 'vagrant/action/builtin/mixin_synced_folders'
require 'vagrant/util/busy'
require 'vagrant/util/platform'

require_relative '../util/excludes'
require_relative '../util/sync'

require 'driskell-listen'

module VagrantReflect
  module Command
    class Reflect < Vagrant.plugin('2', :command)
      include Vagrant::Action::Builtin::MixinSyncedFolders

      def self.synopsis
        'a better rsync-auto'
      end

      def execute
        @logger = Log4r::Logger.new('vagrant::commands::reflect')

        options = {
          poll:        false,
          incremental: true
        }

        opts = OptionParser.new do |o|
          o.banner = 'Usage: vagrant reflect [vm-name]'
        end

        # Parse the options and return if we don't have any target.
        argv = parse_options(opts)
        return unless argv

        # Build up the paths that we need to listen to.
        paths = {}
        with_target_vms(argv) do |machine|
          machine = check_proxy(machine)
          folders = get_folders(machine)
          next if !folders || folders.empty?

          folders.each do |id, folder_opts|
            # If we marked this folder to not auto sync, then
            # don't do it.
            next if folder_opts.key?(:auto) && !folder_opts[:auto]

            # Push on .vagrant exclude
            folder_opts = folder_opts.dup
            folder_opts[:exclude] ||= []
            folder_opts[:exclude] << '.vagrant/'

            syncer = Util::Sync.new(machine, folder_opts)

            machine.ui.info(
              I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_initial'))
            syncer.sync_full

            hostpath = folder_opts[:hostpath]
            hostpath = File.expand_path(hostpath, machine.env.root_path)
            paths[hostpath] ||= []
            paths[hostpath] << {
              id:      id,
              machine: machine,
              opts:    folder_opts,
              syncer:  syncer
            }
          end
        end

        # Exit immediately if there is nothing to watch
        if paths.empty?
          @env.ui.info(
            I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_no_paths'))
          return 1
        end

        @logger.info(
          "Listening via: #{Driskell::Listen::Adapter.select.inspect}")

        # Create a listener for each path so the callback can easily
        # distinguish which path changed
        listeners = paths.keys.sort.collect do |path|
          opts = paths[path]
          callback = method(:callback).to_proc.curry[path][opts][options]

          ignores = []
          opts.each do |path_opts|
            ignores += Util::Excludes.convert(path_opts[:opts][:exclude] || [])
            path_opts[:machine].ui.info(
              I18n.t(
                'vagrant.plugins.vagrant-reflect.rsync_auto_path',
                path: path.to_s))
          end

          @logger.info("Listening to path: #{path}")
          @logger.info("Ignoring #{ignores.length} paths:")
          ignores.each do |ignore|
            @logger.info("-- #{ignore}")
          end

          listopts = { ignore: ignores, force_polling: options[:poll] }
          Driskell::Listen.to(path, listopts, &callback)
        end

        # Create the callback that lets us know when we've been interrupted
        queue    = Queue.new
        callback = lambda do
          # This needs to execute in another thread because Thread
          # synchronization can't happen in a trap context.
          Thread.new { queue << true }
        end

        # Run the listeners in a busy block so that we can cleanly
        # exit once we receive an interrupt.
        Vagrant::Util::Busy.busy(callback) do
          listeners.each(&:start)
          queue.pop
          listeners.each do |listener|
            listener.stop if listener.state != :stopped
          end
        end

        0
      end

      def check_proxy(machine)
        return machine unless machine.provider.capability?(:proxy_machine)

        proxy = machine.provider.capability(:proxy_machine)
        return machine unless proxy

        machine.ui.warn(
          I18n.t(
            'vagrant.plugins.vagrant-reflect.rsync_proxy_machine',
            name: machine.name.to_s,
            provider: machine.provider_name.to_s))

        proxy
      end

      def get_folders(machine)
        cached = synced_folders(machine, cached: true)
        fresh  = synced_folders(machine)
        diff   = synced_folders_diff(cached, fresh)
        unless diff[:added].empty?
          machine.ui.warn(
            I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_new_folders'))
        end

        cached[:rsync]
      end

      # This is the callback that is called when any changes happen
      def callback(path, opts, options, modified, added, removed)
        @logger.info("File change callback called for #{path}!")
        @logger.info("  - Modified: #{modified.inspect}")
        @logger.info("  - Added: #{added.inspect}")
        @logger.info("  - Removed: #{removed.inspect}")

        callback = options[:incremental] ? :sync_incremental : :sync_full

        # Perform the sync for each machine
        opts.each do |path_opts|
          begin
            # If disabled incremental, do a full
            send callback, path, path_opts, modified, added, removed

            path_opts[:machine].ui.info(
              get_sync_time +
              I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_synced'))
          rescue Vagrant::Errors::MachineGuestNotReady
            # Error communicating to the machine, probably a reload or
            # halt is happening. Just notify the user but don't fail out.
            path_opts[:machine].ui.error(
              I18n.t('vagrant.plugins.vagrant-reflect.'\
                     'rsync_communicator_not_ready_callback'))
          rescue Vagrant::Errors::VagrantError => e
            path_opts[:machine].ui.error(e.message)
          end
        end
      end

      def sync_full(path, path_opts, modified, added, removed)
        [modified, added].flatten.each do |change|
          path_opts[:machine].ui.info(
            I18n.t(
              'vagrant.plugins.vagrant-reflect.rsync_auto_full_change',
              path: strip_path(path, change)))
        end

        removed.each do |remove|
          path_opts[:machine].ui.info(
            I18n.t(
              'vagrant.plugins.vagrant-reflect.rsync_auto_full_remove',
              path: strip_path(path, remove)))
        end

        path_opts[:machine].ui.info(
          I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_full'))

        path_opts[:syncer].sync_full
      end

      def sync_incremental(path, path_opts, modified, added, removed)
        sync_time = get_sync_time

        if !modified.empty? || !added.empty?
          # Pass the list of changes to rsync so we quickly synchronise only
          # the changed files instead of the whole folder
          items = strip_paths(path, modified + added)
          path_opts[:syncer].sync_incremental(items) do |item|
            path_opts[:machine].ui.info(
              sync_time +
              I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_increment_change',
                     path: item))
          end
        end

        return if removed.empty?

        # Pass list of changes to a remove command
        items = strip_paths(path, removed)
        path_opts[:syncer].sync_removals(items) do |item|
          path_opts[:machine].ui.info(
            sync_time +
            I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_increment_remove',
                   path: item))
        end
      end

      def get_sync_time()
        # TODO: Hold this configuration per machine when we refactor
        with_target_vms(nil, single_target: true) do |vm|
          if vm.config.reflect.show_sync_time == true
            return '(' + Time.now.strftime("%H:%M:%S") + ') '
          end
        end

        ''
      end

      def strip_paths(path, items)
        items.map do |item|
          item[path.length..-1]
        end
      end

      def strip_path(path, item)
        item[path.length..-1]
      end
    end
  end
end

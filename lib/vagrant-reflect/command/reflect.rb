require 'log4r'
require 'optparse'
require 'thread'

require 'vagrant/action/builtin/mixin_synced_folders'
require 'vagrant/util/busy'
require 'vagrant/util/platform'

require_relative '../util/syncer'

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
          o.separator ''
          o.separator 'Options:'
          o.separator ''

          o.on('--[no-]poll', 'Force polling filesystem (slow)') do |poll|
            options[:poll] = poll
          end
          o.on(
            '--[no-]incremental',
            'Perform incremental copies of changes where possible (fast)'
          ) do |incremental|
            options[:incremental] = incremental
          end
        end

        # Parse the options and return if we don't have any target.
        argv = parse_options(opts)
        return unless argv

        # Build up the paths that we need to listen to.
        paths = {}
        with_target_vms(argv) do |machine|
          if machine.provider.capability?(:proxy_machine)
            proxy = machine.provider.capability(:proxy_machine)
            if proxy
              machine.ui.warn(
                I18n.t(
                  'vagrant.plugins.vagrant-reflect.rsync_proxy_machine',
                  name: machine.name.to_s,
                  provider: machine.provider_name.to_s))

              machine = proxy
            end
          end

          cached = synced_folders(machine, cached: true)
          fresh  = synced_folders(machine)
          diff   = synced_folders_diff(cached, fresh)
          unless diff[:added].empty?
            machine.ui.warn(
              I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_new_folders'))
          end

          folders = cached[:rsync]
          next if !folders || folders.empty?

          folders.each do |id, folder_opts|
            # If we marked this folder to not auto sync, then
            # don't do it.
            next if folder_opts.key?(:auto) && !folder_opts[:auto]

            syncer = Syncer.new(machine, folder_opts)

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
            path_opts[:machine].ui.info(
              I18n.t(
                'vagrant.plugins.vagrant-reflect.rsync_auto_path',
                path: path.to_s))

            next unless path_opts[:exclude]

            Array(path_opts[:exclude]).each do |pattern|
              ignores << Syncer.exclude_to_regexp(hostpath, pattern.to_s)
            end
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

      # This is the callback that is called when any changes happen
      def callback(path, opts, options, modified, added, removed)
        @logger.info("File change callback called for #{path}!")
        @logger.info("  - Modified: #{modified.inspect}")
        @logger.info("  - Added: #{added.inspect}")
        @logger.info("  - Removed: #{removed.inspect}")

        # Perform the sync for each machine
        opts.each do |path_opts|
          begin
            # If we have any removals or have disabled incremental, perform a
            # single full sync
            # It's seemingly impossible to ask rsync to only do a deletion
            if !options[:incremental] || !removed.empty?
              removed.each do |remove|
                path_opts[:machine].ui.info(
                  I18n.t(
                    'vagrant.plugins.vagrant-reflect.rsync_auto_full_remove',
                    path: strip_path(path, remove)))
              end

              [modified, added].each do |changes|
                changes.each do |change|
                  path_opts[:machine].ui.info(
                    I18n.t(
                      'vagrant.plugins.vagrant-reflect.rsync_auto_full_change',
                      path: strip_path(path, change)))
                end
              end

              path_opts[:machine].ui.info(
                I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_full'))

              path_opts[:syncer].sync_full
            elsif !modified.empty? || !added.empty?
              # Pass the list of changes to rsync so we quickly synchronise only
              # the changed files instead of the whole folder
              items = strip_paths(path, modified + added)
              path_opts[:syncer].sync_incremental(items) do |item|
                path_opts[:machine].ui.info(
                  I18n.t('vagrant.plugins.vagrant-reflect.rsync_auto_increment',
                         path: item))
              end
            end

            path_opts[:machine].ui.info(
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

      def strip_paths(path, items)
        items.map do |item|
          item[path.length..item.length]
        end
      end

      def strip_path(path, item)
        item[path.length..item.length]
      end
    end
  end
end

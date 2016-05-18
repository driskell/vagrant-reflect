require 'vagrant/util/platform'

require_relative '../patched/subprocess'
require_relative 'shell'

module VagrantReflect
  module Util
    # This is a helper that abstracts out the functionality of rsync and rm
    class Sync
      def initialize(machine, opts)
        @machine = machine

        init_paths(opts)

        @shell = Shell.new(@machine, @guestpath, @hostpath, opts[:exclude])

        log_configuration opts[:exclude] || []
      end

      def sync_incremental(items, &block)
        send_items_to_command items, @shell.rsync_command_inc, &block
      end

      def sync_full
        r = Vagrant::Util::SubprocessPatched.execute(*@shell.rsync_command_full)
        check_exit @shell.rsync_command_full, r
      end

      def sync_removals(items, &block)
        # Look for removed directories and fill in guest paths
        dirs = prepare_items_for_removal(items)

        send_items_to_command items, @shell.rm_command, &block
        sync_removals_parents dirs.values unless dirs.empty?
      end

      def sync_removals_parents(guest_items)
        send_items_to_command guest_items, @shell.rmdir_command
      end

      protected

      def log_configuration(excludes)
        @machine.ui.info(
          I18n.t(
            'vagrant.plugins.vagrant-reflect.rsync_folder_configuration',
            guestpath: @guestpath,
            hostpath: @hostpath))

        return if excludes.empty?

        @machine.ui.info(
          I18n.t(
            'vagrant.plugins.vagrant-reflect.rsync_folder_excludes',
            excludes: excludes.inspect))
      end

      def init_paths(opts)
        # Folder info
        @guestpath = opts[:guestpath]
        @hostpath  = opts[:hostpath]
        @hostpath  = File.expand_path(@hostpath, @machine.env.root_path)
        @hostpath  = Vagrant::Util::Platform.fs_real_path(@hostpath).to_s

        if Vagrant::Util::Platform.windows?
          # rsync for Windows expects cygwin style paths, always.
          @hostpath = Vagrant::Util::Platform.cygwin_path(@hostpath)
        end

        # Make sure the host path ends with a "/" to avoid creating
        # a nested directory...
        @hostpath += '/' unless @hostpath.end_with?('/')
      end

      def prepare_items_for_removal(items)
        dirs = {}
        items.map! do |rel_path|
          check_for_empty_parents(rel_path, dirs)
          @guestpath + rel_path
        end
        dirs
      end

      def check_for_empty_parents(rel_path, dirs)
        parent = rel_path
        loop do
          parent = File.dirname(parent)
          break if parent == '/'
          next if File.exist?(@hostpath + parent)
          # Insertion order is maintained so ensure we move repeated paths to
          # end so they are deleted last
          dirs.delete parent
          dirs[parent] = @guestpath + parent
        end
      end

      def send_items_to_command(items, command, &block)
        current = next_item(items, &block)
        r = Vagrant::Util::SubprocessPatched.execute(*command) do |what, io|
          next if what != :stdin

          current = process_items(io, items, current, &block)
        end
        check_exit command, r
      end

      def process_items(io, items, current, &block)
        until current.nil?
          send_data(io, current)
          current = next_item(items, &block)
        end

        # Finished! Close stdin
        io.close_write
      rescue IO::WaitWritable, Errno::EINTR
        # Wait for writable again
        return current
      end

      def next_item(items)
        return nil if items.empty?
        current = items.shift + "\n"
        yield current if block_given?
        current
      end

      def send_data(io, current)
        # Handle partial writes
        n = io.write_nonblock(current)
        return unless n < current.length
        current.slice! 0, n
        throw IO::WaitWritable
      end

      def check_exit(command, r)
        return if r.exit_code == 0

        raise Vagrant::Errors::RSyncError,
              command: command.join(' '),
              guestpath: @guestpath,
              hostpath: @hostpath,
              stderr: r.stderr
      end
    end # ::Sync
  end # ::Util
end # ::VagrantReflect

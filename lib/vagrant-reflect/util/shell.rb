module VagrantReflect
  module Util
    # This is a helper that builds the required commands and returns them
    class Shell
      def initialize(machine, guestpath, hostpath, excludes)
        @machine = machine
        @guestpath = guestpath
        @hostpath = hostpath
        @excludes = excludes || []

        init_connection_info
        init_commands
      end

      attr_reader :rsync_command_inc
      attr_reader :rsync_command_full
      attr_reader :rm_command
      attr_reader :rmdir_command

      protected

      def init_connection_info
        # Connection information
        username = @machine.ssh_info[:username]
        host     = @machine.ssh_info[:host]
        @remote = "#{username}@#{host}"
        @target = "#{@remote}:#{@guestpath}"
      end

      def init_commands
        @workdir = @machine.env.root_path.to_s

        build_rsh_command

        base = compile_base_rsync
        build_rsync_command_full base
        build_rsync_command_inc base

        build_rm_command
        build_rmdir_command
      end

      def build_rsh_command
        proxy_command = []
        if @machine.ssh_info[:proxy_command]
          proxy_command += [
            '-o',
            "ProxyCommand='#{@machine.ssh_info[:proxy_command]}'"
          ]
        end

        @rsh = rsh_command_args(proxy_command).flatten
      end

      def rsh_command_args(proxy_command)
        [
          'ssh',
          '-p', @machine.ssh_info[:port].to_s,
          proxy_command,
          '-o', 'StrictHostKeyChecking=no',
          '-o', 'IdentitiesOnly=true',
          '-o', 'UserKnownHostsFile=/dev/null',
          @machine.ssh_info[:private_key_path].map { |p| ['-i', p] }
        ]
      end

      def compile_base_rsync
        # Get the command-line arguments
        # TODO: Re-enable customisation of this
        base_rsync = [
          'rsync', '--verbose', '--archive', '--delete', '-z', '--links']

        # On Windows, we have to set a default chmod flag to avoid permission
        # issues
        add_windows_chmod_args(base_rsync) if Vagrant::Util::Platform.windows?

        add_owner_args(base_rsync)

        base_rsync += ['-e', @rsh.join(' ')]

        @excludes.map { |e| base_rsync += ['--exclude', e] }

        base_rsync
      end

      def add_windows_chmod_args(base_rsync)
        return if base_rsync.any? { |arg| arg.start_with?('--chmod=') }

        # Ensures that all non-masked bits get enabled
        base_rsync << '--chmod=ugo=rwX'

        # Remove the -p option if --archive is enabled (--archive equals
        # -rlptgoD) otherwise new files will not have the destination-default
        # permissions
        return unless base_rsync.include?('--archive') ||
                      base_rsync.include?('-a')

        base_rsync << '--no-perms'
      end

      def add_owner_args(base_rsync)
        # Disable rsync's owner/group preservation (implied by --archive) unless
        # specifically requested, since we adjust owner/group to match shared
        # folder setting ourselves.
        base_rsync << '--no-owner' unless
          base_rsync.include?('--owner') || base_rsync.include?('-o')
        base_rsync << '--no-group' unless
          base_rsync.include?('--group') || base_rsync.include?('-g')
      end

      def build_rsync_command_full(base_rsync)
        @rsync_command_full = base_rsync + [
          @hostpath, @target, { workdir: @workdir }]
      end

      def build_rsync_command_inc(base_rsync)
        @rsync_command_inc = base_rsync + [
          '--files-from=-', @hostpath, @target,
          { workdir: @workdir, notify: :stdin }]
      end

      def build_rm_command
        @rm_command = @rsh + [
          @remote, 'xargs rm -f', { workdir: @workdir, notify: :stdin }]
      end

      def build_rmdir_command
        # Make this command silent
        # Sometimes we attempt to remove parent folders that aren't empty yet
        # on the remote because we didn't yet sync across all of the removals
        @rmdir_command = @rsh + [@remote, 'xargs -n 1 rmdir 2>/dev/null',
                                 { workdir: @workdir, notify: :stdin }]
      end
    end # ::Shell
  end # ::Util
end # ::VagrantReflect

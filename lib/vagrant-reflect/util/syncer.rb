require 'vagrant/util/platform'

require_relative '../patched/subprocess'

module VagrantReflect
  # This is a helper that abstracts out the functionality of rsyncing
  # folders so that it can be called from anywhere.
  class Syncer
    RSYNC_TO_REGEXP_PATTERNS = [
      ['.', '\\.'],
      ['***', '|||EMPTY|||'],
      ['**', '|||GLOBAL|||'],
      ['*', '|||PATH|||'],
      ['?', '[^/]'],
      ['|||PATH|||', '[^/]+'],
      ['|||GLOBAL|||', '.+'],
      ['|||EMPTY|||', '.*']
    ].freeze

    def initialize(machine, opts)
      @opts = opts
      @machine = machine
      @workdir = @machine.env.root_path.to_s

      init_paths
      init_connection_info
      init_excludes
      init_commands
    end

    def log_configuration
      @machine.ui.info(
        I18n.t(
          'vagrant.plugins.vagrant-reflect.rsync_folder_configuration',
          guestpath: @guestpath,
          hostpath: @hostpath))

      return if @excludes.empty?

      @machine.ui.info(
        I18n.t(
          'vagrant.plugins.vagrant-reflect.rsync_folder_excludes',
          excludes: @excludes.inspect))
    end

    # This converts the rsync exclude patterns to regular expressions we can
    # send to Listen.
    def excludes_to_regexp
      return @regexp if @regexp

      @regexp = @excludes.map(&method(:exclude_to_regex_single))
    end

    def sync_incremental(items, &block)
      send_items_to_command items, @rsync_command_inc, &block
    end

    def sync_full
      r = Vagrant::Util::SubprocessPatched.execute(*@rsync_command_full)
      check_exit @rsync_command_full, r
    end

    def sync_removals(items, &block)
      # Look for removed directories and fill in guest paths
      dirs = prepare_items_for_removal(items)

      send_items_to_command items, @rm_command, &block
      sync_removals_parents dirs.values, &block unless dirs.empty?
    end

    def sync_removals_parents(guest_items, &block)
      send_items_to_command guest_items, @rmdir_command, &block
    end

    protected

    def init_paths
      # Folder info
      @guestpath = @opts[:guestpath]
      @hostpath  = @opts[:hostpath]
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

    def init_connection_info
      # Connection information
      username = @machine.ssh_info[:username]
      host     = @machine.ssh_info[:host]
      @remote = "#{username}@#{host}"
      @target = "#{@remote}:#{@guestpath}"
    end

    def init_excludes
      # Exclude some files by default, and any that might be configured
      # by the user.
      @excludes = []
      @excludes += Array(@opts[:exclude]).map(&:to_s) if @opts[:exclude]
      @excludes.uniq!
    end

    def init_commands
      init_rsh_command
      init_rsync_command
      init_rsync_command_full
      init_rsync_command_inc
      init_rm_command
      init_rmdir_command
    end

    def init_rsh_command
      proxy_command = []
      if @machine.ssh_info[:proxy_command]
        proxy_command += [
          '-o',
          "ProxyCommand='#{@machine.ssh_info[:proxy_command]}'"
        ]
      end

      @rsh = build_rsh_command(proxy_command).flatten
    end

    def build_rsh_command(proxy_command)
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

    def init_rsync_command
      # Get the command-line arguments
      if @opts[:args]
        @rsync_command = ['rsync'] + Array(@opts[:args]).dup
      else
        @rsync_command = [
          'rsync', '--verbose', '--archive', '--delete', '-z', '--copy-links']
      end

      # On Windows, we have to set a default chmod flag to avoid permission
      # issues
      build_windows_chmod_args if Vagrant::Util::Platform.windows?

      build_owner_args

      @rsync_command += ['-e', @rsh.join(' ')]

      @excludes.map { |e| @rsync_command += ['--exclude', e] }
    end

    def build_windows_chmod_args
      return if @rsync_command.any? { |arg| arg.start_with?('--chmod=') }

      # Ensures that all non-masked bits get enabled
      @rsync_command << '--chmod=ugo=rwX'

      # Remove the -p option if --archive is enabled (--archive equals
      # -rlptgoD) otherwise new files will not have the destination-default
      # permissions
      return unless @rsync_command.include?('--archive') ||
                    @rsync_command.include?('-a')

      @rsync_command << '--no-perms'
    end

    def build_owner_args
      # Disable rsync's owner/group preservation (implied by --archive) unless
      # specifically requested, since we adjust owner/group to match shared
      # folder setting ourselves.
      @rsync_command << '--no-owner' unless
        @rsync_command.include?('--owner') || @rsync_command.include?('-o')
      @rsync_command << '--no-group' unless
        @rsync_command.include?('--group') || @rsync_command.include?('-g')
    end

    def init_rsync_command_full
      @rsync_command_full = @rsync_command.dup + [
        @hostpath,
        @target,
        {
          workdir: @workdir
        }
      ]
    end

    def init_rsync_command_inc
      @rsync_command_inc = @rsync_command.dup + [
        '--files-from=-',
        @hostpath,
        @target,
        {
          workdir: @workdir,
          notify: :stdin
        }
      ]
    end

    def init_rm_command
      @rm_command = @rsh.dup + [
        @remote,
        'xargs rm -f',
        {
          workdir: @workdir,
          notify: :stdin
        }
      ]
    end

    def init_rmdir_command
      @rmdir_command = @rsh.dup + [
        @remote,
        'xargs rmdir',
        {
          workdir: @workdir,
          notify: :stdin
        }
      ]
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
        unless File.exist?(@hostpath + parent) || dirs.key?(parent)
          dirs[parent] = @guestpath + parent
        end
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

    def exclude_to_regex_single(exclude)
      start_anchor = false

      if exclude.start_with?('/')
        start_anchor = true
        exclude = exclude[1..-1]
      end

      regexp = start_anchor ? '^' : '(?:^|/)'
      regexp += perform_substitutions(exclude)
      regexp += exclude.end_with?('/') ? '' : '(?:/|$)'

      Regexp.new(regexp)
    end

    def perform_substitutions(exclude)
      # This is REALLY ghetto, but its a start. We can improve and
      # keep unit tests passing in the future.
      # TODO: Escaped wildcards get substituted incorrectly - replace with FSM?
      RSYNC_TO_REGEXP_PATTERNS.each do |pattern|
        exclude = exclude.gsub(pattern[0], pattern[1])
      end
      exclude
    end
  end
end

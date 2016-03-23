require 'vagrant/util/platform'

require_relative '../patched/subprocess'

module VagrantReflect
  # This is a helper that abstracts out the functionality of rsyncing
  # folders so that it can be called from anywhere.
  class Syncer
    def initialize(machine, opts)
      @opts = opts
      @machine = machine
      @workdir = @machine.env.root_path.to_s

      # Folder info
      @guestpath = @opts[:guestpath]
      @hostpath  = @opts[:hostpath]
      @hostpath  = File.expand_path(@hostpath, machine.env.root_path)
      @hostpath  = Vagrant::Util::Platform.fs_real_path(@hostpath).to_s

      if Vagrant::Util::Platform.windows?
        # rsync for Windows expects cygwin style paths, always.
        @hostpath = Vagrant::Util::Platform.cygwin_path(@hostpath)
      end

      # Make sure the host path ends with a "/" to avoid creating
      # a nested directory...
      @hostpath += '/' unless @hostpath.end_with?('/')

      # Connection information
      username = @machine.ssh_info[:username]
      host     = @machine.ssh_info[:host]
      proxy_command = []
      if @machine.ssh_info[:proxy_command]
        proxy_command += [
          '-o',
          "ProxyCommand='#{@machine.ssh_info[:proxy_command]}'"
        ]
      end

      @rsh = [
        'ssh',
        '-p', @machine.ssh_info[:port].to_s,
        proxy_command,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'IdentitiesOnly=true',
        '-o', 'UserKnownHostsFile=/dev/null',
        @machine.ssh_info[:private_key_path].map { |p| ['-i', p] }
      ].flatten

      @remote = "#{username}@#{host}"
      @target = "#{@remote}:#{@guestpath}"

      # Exclude some files by default, and any that might be configured
      # by the user.
      @excludes = []
      @excludes += Array(@opts[:exclude]).map(&:to_s) if @opts[:exclude]
      @excludes.uniq!

      # Get the command-line arguments
      @command = ['rsync']
      @command += Array(@opts[:args]).dup if @opts[:args]
      @command ||= ['--verbose', '--archive', '--delete', '-z', '--copy-links']

      # On Windows, we have to set a default chmod flag to avoid permission
      # issues
      if Vagrant::Util::Platform.windows?
        unless @command.any? { |arg| arg.start_with?('--chmod=') }
          # Ensures that all non-masked bits get enabled
          @command << '--chmod=ugo=rwX'

          # Remove the -p option if --archive is enabled (--archive equals
          # -rlptgoD) otherwise new files will not have the destination-default
          # permissions
          @command << '--no-perms' if
            @command.include?('--archive') || @command.include?('-a')
        end
      end

      # Disable rsync's owner/group preservation (implied by --archive) unless
      # specifically requested, since we adjust owner/group to match shared
      # folder setting ourselves.
      @command << '--no-owner' unless
        @command.include?('--owner') || @command.include?('-o')
      @command << '--no-group' unless
        @command.include?('--group') || @command.include?('-g')

      @command += [
        '-e', @rsh.join(' ')
      ]

      @excludes.map { |e| @command += ['--exclude', e] }

      machine.ui.info(
        I18n.t(
          'vagrant.plugins.vagrant-reflect.rsync_folder_configuration',
          guestpath: @guestpath,
          hostpath: @hostpath))

      if @excludes.length > 1
        machine.ui.info(
          I18n.t(
            'vagrant.plugins.vagrant-reflect.rsync_folder_excludes',
            excludes: @excludes.inspect))
      end
    end

    # This converts the rsync exclude patterns to regular expressions we can
    # send to Listen.
    def excludes_to_regexp
      return @regexp if @regexp

      @regexp = @excludes.map(&method(:exclude_to_regex_single))
    end

    def sync_incremental(items, &block)
      command = @command.dup + [
        '--files-from=-',
        @hostpath,
        @target,
        {
          workdir: @workdir,
          notify: :stdin
        }
      ]

      send_items_to_command items, command, &block
    end

    def sync_full
      command = @command.dup + [
        @hostpath,
        @target,
        {
          workdir: @workdir
        }
      ]

      r = Vagrant::Util::SubprocessPatched.execute(*command)
      check_exit command, r
    end

    def sync_removals(items, &block)
      command = @rsh.dup + [
        @remote,
        'xargs rm -f',
        {
          workdir: @workdir,
          notify: :stdin
        }
      ]

      # Look for removed directories and fill in guest paths
      dirs = {}
      items.map! do |rel_path|
        parent = rel_path
        loop do
          parent = File.dirname(parent)
          break if parent == '/'
          unless File.exist?(@hostpath + parent) || dirs.key?(parent)
            dirs[parent] = @guestpath + parent
          end
        end
        @guestpath + rel_path
      end

      send_items_to_command items, command, &block
      sync_removals_parents dirs.values, &block unless dirs.empty?
    end

    def sync_removals_parents(guest_items, &block)
      command = @rsh.dup + [
        @remote,
        'xargs rmdir',
        {
          workdir: @workdir,
          notify: :stdin
        }
      ]

      send_items_to_command guest_items, command, &block
    end

    protected

    def send_items_to_command(items, command, &block)
      current = false
      r = Vagrant::Util::SubprocessPatched.execute(*command) do |what, io|
        next if what != :stdin

        current = process_items(io, items, current, &block)
      end
      check_exit command, r
    end

    def process_items(io, items, current, &block)
      until items.empty?
        # If we don't have a line, grab one and print it
        if current === false
          current = items.shift + "\n"
          block.call(current) if block_given?
        end

        # Handle partial writes
        n = io.write_nonblock(current)
        if n < current.length
          current = current[n..current.length]
          break
        end

        # Request a new line for next write
        current = false
      end

      # Finished! Close stdin
      io.close_write
    rescue IO::WaitWritable, Errno::EINTR
      # Ignore
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
      dir_only = false

      if exclude.start_with?('/')
        start_anchor = true
        exclude      = exclude[1..-1]
      end

      if exclude.end_with?('/')
        dir_only = true
        exclude      = exclude[0..-2]
      end

      regexp = start_anchor ? '^' : '(?:^|/)'

      # This is REALLY ghetto, but its a start. We can improve and
      # keep unit tests passing in the future.
      # TODO: Escaped wildcards get substituted incorrectly - replace with FSM?
      exclude = exclude.gsub('.', '\\.')
      exclude = exclude.gsub('***', '|||EMPTY|||')
      exclude = exclude.gsub('**', '|||GLOBAL|||')
      exclude = exclude.gsub('*', '|||PATH|||')
      exclude = exclude.gsub('?', '[^/]')
      exclude = exclude.gsub('|||PATH|||', '[^/]+')
      exclude = exclude.gsub('|||GLOBAL|||', '.+')
      exclude = exclude.gsub('|||EMPTY|||', '.*')
      regexp += exclude

      regexp += dir_only ? '/' : '(?:/|$)'

      Regexp.new(regexp)
    end
  end
end

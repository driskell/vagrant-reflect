# To SSH into the machine:
#	 ssh -p 2222 vagrant@localhost
# Password is: penrhyn

Vagrant.configure('2') do |config|
  # Our base box
  config.vm.box = 'centos-65-x64-virtualbox-nocm'
  config.vm.box_url = 'http://puppet-vagrant-boxes.puppetlabs.com/centos-65-x64-virtualbox-nocm.box'

  # Bridge with the local network
  config.vm.network :public_network

  if Vagrant.has_plugin?("vagrant-reflect")
    # Show sync time next to messages
    config.reflect.show_sync_time = true
    # Show notification about file changes
    config.reflect.show_notification = true
  end

  # Adjust the RAM and CPU count - this can be modified per repository
  config.vm.provider 'virtualbox' do |v|
    # CPU/Memory
    v.memory = 512
    v.cpus = 2
    # Uncomment the following to make the VirtualBox console for this VM visible
    # (Good for diagnosing boot issues)
    v.gui = true
  end

  # Rsync shared folder for testing
  config.vm.synced_folder(
    '.', '/vagrant',
    type: 'rsync',
    rsync__args:
      ['--verbose', '--archive', '--delete', '-z', '--copy-links',
       '--hard-links'],
    rsync__exclude: ['.git', 'vendor'])
end

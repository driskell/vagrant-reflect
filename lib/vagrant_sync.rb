I18n.load_path << File.join(File.dirname(File.dirname(__FILE__)), 'templates/locales/en.yml')

# VagrantSync plugin
module VagrantSync
  # A Vagrant Plugin
  class Plugin < Vagrant.plugin('2')
    name 'Vagrant Sync'

    command 'sync-auto' do
      require_relative 'command/sync_auto'
      Command::SyncAuto
    end
  end
end

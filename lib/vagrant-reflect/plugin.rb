# Vagrant Reflect plugin
module VagrantReflect
  # A Vagrant Plugin
  class Plugin < Vagrant.plugin('2')
    name 'Vagrant Reflect'

    command 'reflect' do
      require_relative 'command/reflect'
      Command::Reflect
    end

    config 'reflect' do
      require_relative 'configuration/reflect'
      Configuration::Reflect
    end
  end
end

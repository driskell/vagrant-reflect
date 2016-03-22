require 'vagrant'

I18n.load_path << File.join(
  File.dirname(File.dirname(__FILE__)), 'templates/locales/en.yml')

require 'vagrant-reflect/plugin'
require 'vagrant-reflect/version'

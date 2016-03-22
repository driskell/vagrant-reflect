lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'vagrant-reflect/version'

Gem::Specification.new do |gem|
  gem.name              = 'vagrant-reflect'
  gem.version           = VagrantReflect::VERSION
  gem.description       = 'Vagrant Reflect'
  gem.summary           = 'A better vagrant rsync-auto'
  gem.homepage          = 'https://github.com/driskell/vagrant-reflect'
  gem.authors           = ['Jason Woods']
  gem.email             = ['devel@jasonwoods.me.uk']
  gem.licenses          = ['Apache']
  gem.rubyforge_project = 'nowarning'
  gem.require_paths     = ['lib']
  gem.files             = Dir['{lib,templates}/**/*']

  gem.add_runtime_dependency 'driskell-listen', '~>3.0.6.9'
end

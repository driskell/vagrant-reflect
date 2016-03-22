# Pull version from git if we're cloned (git command sure to exist)
# Otherwise, if in an archive, use version.txt, which is the last stable version
if File.directory? '.git'
  version = \
    `git describe | sed 's/-\([0-9][0-9]*\)-\([0-9a-z][0-9a-z]*\)$/-\1.\2/g'`
  version.sub!(/^v/, '')
else
  version = ''
end
version = IO.read 'version.txt' if version == ''

version.chomp!

Gem::Specification.new do |gem|
  gem.name              = 'vagrant-reflect'
  gem.version           = version
  gem.description       = 'Vagrant Reflect'
  gem.summary           = 'A better vagrant rsync-auto'
  gem.homepage          = 'https://github.com/driskell/vagrant-reflect'
  gem.authors           = ['Jason Woods']
  gem.email             = ['devel@jasonwoods.me.uk']
  gem.licenses          = ['Apache']
  gem.rubyforge_project = 'nowarning'
  gem.require_paths     = ['lib']
  gem.files             = Dir['{lib,templates}/**/*']

  gem.add_runtime_dependency 'driskell-listen', '~>3.0.6.8'
end

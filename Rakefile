require 'rubygems'
require 'rubygems/package_task'

# gemspec = Gem::Specification.load('logstash-input-courier.gemspec')
# Gem::PackageTask.new(gemspec).define

task :default do
  Rake::Task[:deploy].invoke
end

task :deploy do
  Bundler.with_clean_env do
    sh 'bundle install --deployment'
  end
end

task :update do
  Bundler.with_clean_env do
    sh 'bundle install --no-deployment --path vendor/bundle'
  end
end

# task :release => [:package] do
#   sh "gem push pkg/logstash-input-courier-#{gemspec.version}.gem"
# end

task :clean do
  sh 'rm -rf .bundle'
  sh 'rm -rf pkg'
  sh 'rm -rf vendor'
end

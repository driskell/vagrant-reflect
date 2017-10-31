# Vagrant Reflect

## Introduction

Vagrant Reflect offers an extremely fast and highly optimised rsync-auto
replacement for developers using Vagrant and Rsync with very large repositories.

```
$ vagrant reflect
==> default: Configuring rsync: /Users/Jason/Documents/Projects/vagrant-reflect/ => /vagrant
==> default:   - Exclude: [".git", "vendor", ".vagrant/"]
==> default: Doing an initial rsync...
==> default: Watching: /Users/Jason/Documents/Projects/vagrant-reflect
==> default: Sending change: /something
==> default: Synchronization completed
==> default: Sending change: /lib/something
==> default: Synchronization completed
==> default: Sending removal: /something
==> default: Synchronization completed
==> default: Sending removal: /lib/something
==> default: Synchronization completed
```

## Installation

    vagrant plugin install vagrant-reflect

## Usage

Vagrant reflect will work with the usual `rsync` shared folder configurations
and requires no further configuration.

However, there are a few vagrant-reflect specific options you can adjust that
affect its behaviour. The available options and how to configure them is shown
below.

*NOTE: Currently, there is only a single option, show_sync_time.*

```ruby
Vagrant.configure('2') do |config|
    if Vagrant.has_plugin?("vagrant-reflect")
      # Show sync time next to messages
      # Default: false
      config.reflect.show_sync_time = true
      # Send notification when sync is completed
      # Default: false
      config.reflect.show_notification = true
    end
end
```

## Improvements

* Incremental transfer of file changes, accounting for the majority of a
developers actions, instead of a full rsync of the entire folder. This will
maintain server-side changes.
* Feedback on what and when is transferred
* Massively improved OS X performance by using a largely improved alpha version
of guard/listen (see
[guard/listen#308](https://github.com/guard/listen/pull/308) and [driskell/listen](https://github.com/driskell/listen/tree/v3_rework_record_logic))
* Unnecessary directory recursion is avoided reducing some common CPU usage
issues
* Fixed a major issue which causes additions and modifications in the repository
root to trigger an exponential recursive scan, hanging the process for minutes
on large repositories
* Wrapped and released as `driskell-listen` for wider testing
* Improved support for rsync exclude strings so no unnecessary transfers are
triggers

## Known Issues / Limitations

* Tested on OS X and Arch Linux - please feedback for other platforms!
* Symlinks can cause some strange behaviour in some instances due to incomplete
implementations in both the improved guard/listen code and the incremental rsync

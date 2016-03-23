# Vagrant Reflect

## Introduction

Vagrant Reflect offers an extremely fast and highly optimised rsync-auto replacement for developers using Vagrant and Rsync with very large repositories.

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
==> default: Processing removal: /something
==> default: Performing full synchronisation due to removals
==> default: Synchronization completed
==> default: Processing removal: /lib/something
==> default: Performing full synchronisation due to removals
==> default: Synchronization completed
```

## Installation

    vagrant plugin install vagrant-reflect

## Improvements

* Incremental transfer of file additions and changes, accounting for the majority of a developers actions, instead of a full rsync of the entire folder. Removals still trigger a full sync
* Feedback on what and when is transferred
* Massively improved OS X performance by using a largely improved alpha version of guard/listen (see [guard/listen#308](https://github.com/guard/listen/pull/308) and [driskell/listen](https://github.com/driskell/listen/tree/v3_rework_record_logic))
  * Unnecessary directory recursion is avoided reducing some common CPU usage issues
  * Fixed a major issue which causes additions and modifications in the repository root to trigger an exponential recursive scan, hanging the process for minutes on large repositories
  * Wrapped and released as `driskell-listen` for wider testing
* Improved support for rsync exclude strings so no unnecessary transfers are triggers

## Known Issues / Limitations

* Only tested on OS X - please feedback for other platforms!
* Symlinks are treated as files and not followed by the change watcher

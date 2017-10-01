# wavefront-puppet-reporter

## Description

A Puppet report processor which sends metrics to a
[Wavefront](https://www.wavefront.com/) proxy.

Supports SmartOS, Solaris, Linux, OpenBSD and FreeBSD.

## Requirements

* Puppet
* The [Wavefront Ruby SDK](https://github.com/snltd/wavefront-sdk)
* A Wavefront account and proxy

## Installation and Usage

This was written to work with masterless Puppet. I don't have any
Puppet Master knowledge or experience. If someone wants to fix this
omission, please do.

For masterless usage

1. Ensure the Wavefront SDK is available before the Puppet run
starts.
2. Put the `wavefront.rb` file somewhere in the module path.
3. Ensure your `puppet.conf` contains something akin to:

```
[main]
reports=wavefront
```

4. In Heira, configure your Wavefront endpoint:

* `wavefront_endpoint`: the IP/DNS name of a Wavefront proxy. Port
  2878 will be used. Default: `wavefront`.
* `wf_report_path`: the base path for metrics. The name of each
  report value will be dot-appended to this. Default: `puppet`.
* `wf_report_tags`: an array of tags to apply to each point.
  Default: `[:run_by, :status]`

The following point tags can be enabled by including them in the
`wf_rerpot_tags` array:

* `run_by`: what triggered the run. Could be `cron`,
  `bootstrap`, or `interactive`.
* `git_rev`: the short (7 char) git revision of the repo in which
  the reporter resides. Useful if you deploy from Git.
  Requires the `git` CLI.
* `puppet_version`: the version of the Puppet agent which performed
  the run.
* `status`:  what happened on the run: one of `failed`, `changed`,
  or `unchanged`.
* `environment`: the Puppet environment which was used.
* `run_no`: how many times Puppet (specifically the reporter)
  has run on this host

5. Ensure, probably via Puppet itself, that a directory
`/etc/puppet/report/wavefront` exists and is writable.

## Author

Robert Fisher (@no_identifier)

## License

BSD 2-Clause.

#
# A reporter to take a Puppet run's metrics and push them to Wavefront. It
# sends every metric given as part of a standard Puppet report, with
# a configurable number of point tags.
#
# You can add any or all of the following tags to every point:
#
# run_by:         What triggered the run. Could be 'cron', 'bootstrap', or
#                 'interactive'.
# git_rev:        the short (7 char) git revision of the repo holding this
#                 file. Requires the `git` CLI.
# puppet_version: the version of the Puppet agent which performed
#                 the run
# status:         what happened on the run: one of 'failed', 'changed',
#                 or 'unchanged'
# environment:    the Puppet environment which was used
# run_no:         how many times Puppet (specifically the reporter)
#                 has run on this host
#
# The following Hiera variables can be used to configure the
# reporter:
#   wavefront_endpoint  the IP/DNS name of a Wavefront proxy
#   wf_report_tags      an array of tags to apply to each point
#                        (see above)
#   wf_report_path      the base path for metrics. The name of each
#                       report value will be dot-appended
#
# Requires: wavefront-sdk gem (https://github.com/snltd/wavefront-sdk)
#           a writeable directory CF_DIR to store state
# Supports: SmartOS, Solaris, Linux, FreeBSD, OpenBSD
#

require 'puppet'
require 'hiera'
require 'facter'
require 'wavefront-sdk/write'

CF_DIR     = Pathname.new('/etc/puppet/report/wavefront')
SKIP_FILE  = CF_DIR + 'no_report'
SCOREBOARD = CF_DIR + 'scoreboard'

HIERA      = Hiera.new(config: lambda {
  %w[/etc/puppetlabs/puppet /etc/puppet /opt/puppet].each do |d|
    p = Pathname.new(d) + 'hiera.yaml'
    return p.to_s if p.exist?
  end
}.call)

SCOPE      = { '::environment' => Facter[:environment].value }.freeze
ENDPOINT   = HIERA.lookup('wavefront_endpoint', 'wf', SCOPE)
TAGS       = HIERA.lookup('wf_report_tags', %w[run_by status], SCOPE)
PATH_BASE  = HIERA.lookup('wf_report_path', 'puppet', SCOPE)

# Examine the process table. Works for Solaris, FreeBSD, OpenBSD and
# Linux.
#
# @param pid [Integer] the process ID we are interested in
# @raise [String] UnknownOS if the OS is not recognized
# @return [Array] the command name of #pid and the parent PID
#
def ps_cmd(pid)
  case RbConfig::CONFIG['arch']
  when /solaris|bsd/
    `ps -o comm,ppid -p #{pid}`
  when /linux/
    `ps -o cmd,ppid #{pid}`
  else
    raise 'UnknownOS'
  end.split("\n").last.split
end

# The PID of the init process. This is generally 1, but not in a
# Solaris or SmartOS zone
#
# @raise [String] 'UnknownOS' if it doesn't recognize the OS
# @return [Integer] the PID of the init process, or equivalent
#
def init_pid
  if RbConfig::CONFIG['arch'] =~ /solaris/
    if `zoneadm list -c | grep ^global$`.empty?
      `/bin/pgrep -fx zsched`.to_i
    else
      `/bin/pgrep -fx /sbin/init`.to_i
    end
  else
    1
  end
end

INIT_PID = init_pid

# Walk up the process tree hierarchy, returning the name of the
# process above this one, and immediately below `init`, or
# equivalent. So, if the reporter is running as a cron job, it
# will return 'cron'.  If you run Puppet interactively, you'll
# likely get '/usr/lib/sshd'.
#
# It's a recursive function, which limits itself to ten
# iterations, to be on the safe side.
#
# @param pid [Integer] the process ID of the program for which we wish
#   to know the parent.
# @param depth [Integer] a counter recording the depth of recursion
# @raise [String] UnknownAncestor if it hits maximum recursion depth
# @return [String] the oldest ancestor of pid
#
def launched_from(pid, depth = 0)
  raise 'UnknownAncestor' if depth > 8
  cmd, ppid = ps_cmd(pid)
  return cmd if ppid.to_i == INIT_PID
  launched_from(ppid, depth + 1)
end

# A wrapper around launched_from() to make tags simpler to
# understand
#
# @return [String]
#
def run_by
  prog = launched_from(Process.pid)

  case prog
  when %r{/sshd$}
    'interactive'
  when 'sshd:', '/usr/bin/python', '/lib/svc/bin/svc.startd'
    'bootstrapper'
  when /cron/
    'cron'
  else
    prog
  end
end

Puppet::Reports.register_report(:wavefront) do
  # @return [String] the short git rev for the repo containing this
  #   file. Assumes you have the git CLI installed, but if you
  #   don't, it's unlikely you'd be using a clone of a git repo.
  #
  def git_rev
    `git rev-parse --short HEAD`.strip
  end

  # @return [Hash] point tags which will be applied to each metric
  #
  def setup_tags
    TAGS.each_with_object({}) { |t, ret| ret[t.to_sym] = send(t) }
  end

  # @return [Integer] the run number, from the scoreboard file
  #
  def run_no
    SCOREBOARD.exist? ? IO.read(SCOREBOARD).to_i : 1
  end

  # Update the scoreboard
  #
  def update_run_number
    FileUtils.mkdir_p(SCOREBOARD.dirname) unless SCOREBOARD.dirname.exist?
    File.open(SCOREBOARD, 'w') { |f| f.write(run_no + 1) }
  end

  # Turn the `metrics` object which Puppet gives us into actual
  # Wavefront points.
  # @return [Array] points ready to be pushed to Wavefront.
  #
  def metrics_as_points
    ts = Time.now.to_i

    metrics.each_with_object([]) do |(category, metric), aggr|
      metric.values.each do |v|
        aggr.<< ({ path:  [PATH_BASE, category, v[0]].join('.'),
                   value: v[2],
                   ts:    ts })
      end
    end
  end

  # Send the metrics to Wavefront, and update the scoreboard file.
  #
  def process
    Wavefront::Write.new({ proxy: ENDPOINT, port: 2878 },
                         tags: setup_tags).write(metrics_as_points)
    update_run_number
  end
end

require 'open3'
require 'optparse'
require 'pathname'

module MoonshineTokenGuard
  extend self
  TAP = 'evertonstz/moonshine-tap'
  class Failure < StandardError; end

  def conflicts(requested, installed)
    unless requested.match?(%r{\Aevertonstz/moonshine-tap/moonshine(?:@(?:untested|(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)))?\z})
      raise Failure, 'Invalid requested Moonshine cask token'
    end
    installed.reject do |name|
      raise Failure, 'Malformed installed-cask listing' unless name.match?(%r{\A[a-zA-Z0-9@._+/-]+\z})
      base = name.split('/').last
      name == requested || (base != 'moonshine' && !base.start_with?('moonshine@'))
    end
  end

  def run(brew)
    Open3.capture3({'RUBYOPT' => nil, 'RUBYLIB' => nil,
                   'HOMEBREW_NO_AUTO_UPDATE' => '1', 'HOMEBREW_NO_ANALYTICS' => '1'},
                  brew, 'list', '--cask', '--full-name', '-1')
  end

  def main(argv = ARGV, euid: Process.euid, runner: method(:run))
    options = {}
    parser = OptionParser.new do |p|
      p.banner = 'Usage: moonshine_token_guard.rb --brew FILE --token TAP/CASK'
      p.on('--brew FILE') { |value| options[:brew] = value }
      p.on('--token TOKEN') { |value| options[:token] = value }
    end
    parser.parse!(argv)
    raise Failure, parser.to_s unless argv.empty? && options.keys.sort == %i[brew token]
    raise Failure, 'Run Homebrew token checks as the normal operator, never with sudo' if euid.zero?
    brew = Pathname(options[:brew])
    raise Failure, 'Homebrew executable must be an absolute executable path' unless brew.absolute? && brew.file? && brew.executable?
    output, error, status = runner.call(brew.to_s)
    raise Failure, "Cannot list installed casks: #{error.strip}" unless status.success? && output.bytesize <= 1024 * 1024
    other = conflicts(options[:token], output.lines.map(&:strip).reject(&:empty?))
    unless other.empty?
      raise Failure, "Ordinarily uninstall #{other.join(', ')} before installing #{options[:token]}. Do not use --zap."
    end
    0
  rescue Failure, SystemCallError, OptionParser::ParseError => e
    warn "moonshine-token-guard: #{e.message}"
    1
  end
end

exit MoonshineTokenGuard.main if $PROGRAM_NAME == __FILE__

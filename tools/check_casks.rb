#!/usr/bin/env ruby
require 'optparse'
require_relative '../lib/release_update'
require_relative '../lib/moonshine_token_guard'

module MoonshineCaskCheck
  extend self
  def command(args)
    Open3.capture3({'HOMEBREW_NO_AUTO_UPDATE' => '1', 'HOMEBREW_NO_ANALYTICS' => '1',
                   'RUBYOPT' => nil, 'RUBYLIB' => nil}, *args)
  end

  def run(root:, brew:, tap:, runner: method(:command), euid: Process.euid)
    MoonshineUpdate.check(!euid.zero?, 'Run Homebrew validation as the normal operator')
    executable = Pathname(brew)
    MoonshineUpdate.check(executable.absolute? && executable.file? && executable.executable?, 'Missing explicit Homebrew executable')
    MoonshineUpdate.check(tap == MoonshineTokenGuard::TAP, 'Unexpected Homebrew validation tap')
    recipes = MoonshineReleases.recipes(root)
    output, error, status = runner.call([brew, 'readall', '--aliases', '--os=all', '--arch=all', tap])
    MoonshineUpdate.check(status.success?, "Homebrew readall failed: #{error.strip}")
    candidate = MoonshineCandidates.recipe(root)
    tokens = MoonshineReleases.tokens(root)
    tokens.each do |token|
      recipe = token == 'moonshine@untested' ? candidate : token == 'moonshine' ? recipes.first : recipes.find { |item| token == MoonshineReleases.exact_token(item) }
      output, error, status = runner.call([brew, 'info', '--cask', '--json=v2', "#{tap}/#{token}"])
      MoonshineUpdate.check(status.success? && output.bytesize <= 2 * 1024 * 1024,
                            "Homebrew cask loading failed: #{token}: #{error.strip}")
      data = JSON.parse(output, max_nesting: 30)
      casks = data.fetch('casks')
      MoonshineUpdate.check(casks.is_a?(Array) && casks.length == 1, 'Homebrew did not load exactly the requested cask')
      cask = casks.first
      release = recipe.release
      MoonshineUpdate.check(cask['token'] == token && cask['full_token'] == "#{tap}/#{token}" &&
                            cask['version'] == (token == 'moonshine@untested' || recipe.delivery&.fetch('style') == 'recipe' ? "#{release['version']}+#{recipe.identity}" : release['version']) && cask['sha256'] == release['sha256'] &&
                            cask['url'] == MoonshineUpdate.download_url(release), 'Homebrew loaded an unexpected cask identity or RPM pin')
    end
    {'readall_executed' => true, 'tokens_loaded' => tokens, 'host_installation' => false}
  end

  def main(argv = ARGV)
    options = {}
    parser = OptionParser.new do |flags|
      flags.banner = 'Usage: ruby tools/check_casks.rb --brew /absolute/path/to/brew --tap evertonstz/moonshine-tap'
      flags.on('--brew FILE') { |value| options[:brew] = value }
      flags.on('--tap TAP') { |value| options[:tap] = value }
      flags.on('--help') { puts flags; return 0 }
    end
    parser.parse!(argv)
    raise MoonshineUpdate::Failure, parser.banner unless argv.empty? && options.keys.sort == %i[brew tap]
    puts JSON.pretty_generate(run(root: Pathname(__dir__).parent, **options))
    0
  rescue StandardError => e
    warn "cask loading checks failed: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshineCaskCheck.main if $PROGRAM_NAME == __FILE__

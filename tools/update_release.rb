#!/usr/bin/env ruby
require 'optparse'
require_relative '../lib/release_update'
require_relative '../lib/release_candidate'

module MoonshineUpdateCLI
  extend self
  def main(argv = ARGV)
    options = {root: Pathname(__dir__).parent, prepare: false}
    parser = OptionParser.new do |flags|
      flags.banner = 'Usage: ruby tools/update_release.rb --bsdtar /absolute/path/to/bsdtar [--prepare]'
      flags.on('--bsdtar PATH') { |path| options[:bsdtar] = path }
      flags.on('--prepare', 'Create a disposable candidate; never edit accepted inputs') { options[:prepare] = true }
      flags.on('--help') { puts flags; return 0 }
    end
    parser.parse!(argv)
    raise MoonshineUpdate::Failure, parser.banner unless argv.empty? && options[:bsdtar]
    sha, _, status = Open3.capture3('git', 'rev-parse', 'HEAD')
    MoonshineUpdate.check(status.success?, 'Cannot bind candidate source commit')
    result = MoonshineUpdate::Updater.new(source_sha: sha.strip, root: options[:root], client: MoonshineUpdate::HTTP.new(token: ENV['GITHUB_TOKEN']),
                                          inspector: MoonshineUpdate::Contract.new(bsdtar: options[:bsdtar]),
                                          store: MoonshineCandidate::Store.new).run(prepare: options[:prepare])
    puts JSON.pretty_generate(result)
    result['status'] == 'review_required' ? 1 : 0
  rescue StandardError => e
    warn "release validation failed: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshineUpdateCLI.main if $PROGRAM_NAME == __FILE__

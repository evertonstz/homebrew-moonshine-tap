#!/usr/bin/env ruby
# Package-only checks. Each retained recipe uses its own helper in a separate Ruby process.
require 'optparse'
require_relative '../lib/release_update'

module MoonshineReleaseCheck
  extend self
  INSPECT = <<~'RUBY'.freeze
    require 'json'
    expected = MoonshineReleases.metadata(JSON.parse(ARGV.fetch(2)))
    abort 'Retained helper identity differs' unless expected == MoonshineHost::RELEASE
    contract = MoonshineUpdate::Contract.new(bsdtar: ARGV.fetch(1)).inspect(ARGV.fetch(0), expected)
    puts JSON.generate(contract)
  RUBY

  def run(root:, bsdtar:, client:, packages: nil, compare: false, test_rpm_copy: nil)
    root = Pathname(root)
    accepted = MoonshineReleases.recipes(root)
    recipes = [*accepted, *MoonshineCandidates.retained(root)]
    Dir.mktmpdir('moonshine-retained-rpms-') do |directory|
      contracts = recipes.map do |recipe|
        release = recipe.release
        path = Pathname(packages || directory)/release.fetch('filename')
        client.download(MoonshineUpdate.download_url(release), path) unless packages || path.exist?
        MoonshineUpdate.check(path.file? && !path.symlink?, 'Missing real retained RPM')
        helper = recipe.helper_path
        output, error, status = Open3.capture3({'RUBYOPT' => nil, 'RUBYLIB' => nil, 'GITHUB_TOKEN' => nil},
                                               RbConfig.ruby, '--disable=rubyopt', '-r', helper.to_s,
                                               '-r', (Pathname(__dir__).parent/'lib/release_update.rb').to_s,
                                               '-e', INSPECT, path.to_s, bsdtar, JSON.generate(release))
        MoonshineUpdate.check(status.success?, "Retained #{release['version']} inspection failed: #{error.strip}")
        contract = JSON.parse(output, max_nesting: 20)
        MoonshineUpdate.check(contract.keys.sort == %w[dependencies inventory protected tags], 'Invalid retained inspection result')
        contract
      end
      if compare
        MoonshineUpdate.check(accepted.length == 2, 'Release comparison requires two checked retained RPMs')
        contracts.drop(1).each { |contract| MoonshineUpdate::Contract.compare(contracts.first, contract) }
      end
      if test_rpm_copy
        destination = Pathname(test_rpm_copy)
        MoonshineUpdate.check(destination.absolute? && !destination.symlink? && !destination.exist?, 'Unsafe test-RPM destination')
        source = Pathname(packages || directory)/recipes.first.release.fetch('filename')
        destination.open(File::WRONLY | File::CREAT | File::EXCL, 0600) do |output|
          source.open('rb') { |input| IO.copy_stream(input, output) }
        end
        MoonshineUpdate.check(Digest::SHA256.file(destination).hexdigest == recipes.first.release['sha256'], 'Exported test RPM digest differs')
      end
      {'versions' => recipes.map(&:release), 'inspected' => contracts.length,
       'extraction_executed' => true, 'contract_compared' => compare, 'host_installation' => false}
    end
  end

  def main(argv = ARGV)
    options = {}
    parser = OptionParser.new do |flags|
      flags.banner = 'Usage: ruby tools/check_releases.rb --bsdtar /absolute/path [--package-dir DIR] [--compare]'
      flags.on('--bsdtar PATH') { |path| options[:bsdtar] = path }
      flags.on('--package-dir DIR', 'Use already downloaded, digest-checked package inputs') { |path| options[:packages] = path }
      flags.on('--compare', 'Require matching retained packaging contracts') { options[:compare] = true }
      flags.on('--test-rpm-copy FILE', 'Export the checked current RPM for regression tests') { |path| options[:test_rpm_copy] = path }
      flags.on('--help') { puts flags; return 0 }
    end
    parser.parse!(argv)
    raise MoonshineUpdate::Failure, parser.banner unless argv.empty? && options[:bsdtar]
    result = run(root: Pathname(__dir__).parent, bsdtar: options.fetch(:bsdtar),
                 client: MoonshineUpdate::HTTP.new(token: ENV['GITHUB_TOKEN']),
                 packages: options[:packages], compare: options.fetch(:compare, false), test_rpm_copy: options[:test_rpm_copy])
    puts JSON.pretty_generate(result)
    0
  rescue StandardError => e
    warn "retained RPM checks failed: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshineReleaseCheck.main if $PROGRAM_NAME == __FILE__

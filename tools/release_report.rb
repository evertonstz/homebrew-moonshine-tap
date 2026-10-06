#!/usr/bin/env ruby
# Export checked scalar data only. Never export paths to executable candidate artifacts.
require_relative '../lib/release_catalog'

module MoonshineReleaseReport
  extend self
  def fields(report, base_sha, current)
    MoonshineReleases.check(report.is_a?(Hash) && %w[unchanged awaiting_asset eligible].include?(report['status']),
                            'Unexpected release outcome')
    MoonshineReleases.check(base_sha.is_a?(String) && base_sha.match?(/\A[0-9a-f]{40}\z/), 'Invalid trusted base commit')
    MoonshineReleases.check(MoonshineReleases.metadata(report.fetch('current')) == current, 'Release report baseline differs')
    result = {'status' => report['status'], 'base_sha' => base_sha}
    if report['status'] == 'eligible'
      release = MoonshineReleases.metadata(report.fetch('release'))
      MoonshineReleases.check((MoonshineReleases.version(release['version']) <=> MoonshineReleases.version(current['version'])) == 1,
                              'Eligible release must be newer than the trusted baseline')
      asset = report['asset_id']
      MoonshineReleases.check(asset.is_a?(Integer) && asset.positive? && asset <= 0x7fff_ffff_ffff_ffff, 'Invalid checked asset ID')
      result['release'] = JSON.generate(release)
      result['asset_id'] = asset.to_s
    end
    result
  end

  def main(argv = ARGV)
    MoonshineReleases.check(argv.length == 1, 'Usage: ruby tools/release_report.rb REPORT.json')
    report = JSON.parse(MoonshineReleases.read_file(argv.first, 32 * 1024), max_nesting: 10)
    sha, error, status = Open3.capture3('git', 'rev-parse', 'HEAD')
    MoonshineReleases.check(status.success?, 'Cannot bind trusted base')
    output = fields(report, sha.strip, MoonshineReleases.current(Pathname(__dir__).parent).release)
    File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') { |file| output.each { |key, value| file.puts "#{key}=#{value}" } }
    File.open(ENV.fetch('GITHUB_STEP_SUMMARY'), 'a') do |file|
      file.puts "Release outcome: #{output.fetch('status')}. Package-only validation; no installation, downgrade or streaming proof."
      file.puts 'Only an eligible result can reach the separately scoped PR publisher. Activation and protected merging require owner configuration.'
    end
    0
  rescue StandardError => e
    warn "release report failed: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshineReleaseReport.main if $PROGRAM_NAME == __FILE__

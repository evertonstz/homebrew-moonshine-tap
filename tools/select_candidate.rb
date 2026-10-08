#!/usr/bin/env ruby
# Owner rollback/reselection inspection. No patch approval and no write credential use.
require_relative '../lib/release_candidate'
require_relative 'check_releases'

module MoonshineCandidateSelection
  extend self
  def main(argv = ARGV)
    MoonshineUpdate.check(argv.length == 1 && ENV['GITHUB_EVENT_NAME'] == 'workflow_dispatch' && ENV['GITHUB_ACTOR'] == 'evertonstz',
                          'Rollback selection requires an owner dispatch and explicit extraction tool')
    root = Pathname(__dir__).parent
    target = MoonshineCandidates.identity(ENV.fetch('MOONSHINE_SELECTION_TARGET'))
    reason = ENV.fetch('MOONSHINE_SELECTION_REASON')
    MoonshineCandidates.reason!(reason)
    MoonshineCask.generate(root: root, check: true)
    recipe = MoonshineCandidates.recipe(root, target)
    data = MoonshineCandidates.catalog(root)
    source, _, status = Open3.capture3('git', 'rev-parse', 'HEAD')
    MoonshineUpdate.check(status.success?, 'Cannot bind owner selection base')
    changes = MoonshineCandidates.patch(root: root, release: recipe.release, source: source.strip,
      expected_current: data['current'], operation: 'rollback', target: target, reason: reason)
    if changes.empty?
      puts JSON.pretty_generate('status' => 'unchanged', 'current' => MoonshineReleases.development(root).release)
      return 0
    end
    client = MoonshineUpdate::HTTP.new(token: ENV['GITHUB_TOKEN'])
    release_data = client.json("https://api.github.com/repos/hgaiser/moonshine/releases/tags/v#{recipe.release['version']}")
    selector = MoonshineUpdate::Updater.new(root: root, client: client, inspector: nil)
    outcome, asset = selector.select(release_data, recipe.release)
    MoonshineUpdate.check(outcome == 'selected' && asset['version'] == recipe.release['version'], 'Retained official asset is unavailable')
    Dir.mktmpdir('moonshine-selection-rpm-') do |directory|
      path = Pathname(directory)/recipe.release['filename']
      client.download(MoonshineUpdate.download_url(recipe.release), path)
      MoonshineUpdate.check(Digest::SHA256.file(path).hexdigest == recipe.release['sha256'] && path.size == asset['size'] &&
                            (!asset['digest'] || asset['digest'] == "sha256:#{recipe.release['sha256']}"), 'Retained official asset identity changed')
      output, error, result = Open3.capture3({'RUBYOPT' => nil, 'RUBYLIB' => nil, 'GITHUB_TOKEN' => nil, 'MOONSHINE_APP_TOKEN' => nil},
        RbConfig.ruby, '--disable=rubyopt', '-r', recipe.helper_path.to_s, '-r', (root/'lib/release_update.rb').to_s,
        '-e', MoonshineReleaseCheck::INSPECT, path.to_s, argv.first, JSON.generate(recipe.release))
      MoonshineUpdate.check(result.success?, "Retained recipe package inspection refused: #{error.strip}")
      contract = JSON.parse(output, max_nesting: 20)
      MoonshineUpdate.check(contract.keys.sort == %w[dependencies inventory protected tags], 'Malformed retained package report')
    end
    puts JSON.pretty_generate('status' => 'eligible', 'current' => MoonshineReleases.development(root).release,
      'release' => recipe.release, 'asset_id' => asset['id'], 'source_sha' => source.strip,
      'recipe_sha256' => target, 'expected_current' => data['current'], 'operation' => 'rollback', 'reason' => reason)
    0
  rescue StandardError => e
    warn "Owner candidate selection refused: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshineCandidateSelection.main if $PROGRAM_NAME == __FILE__

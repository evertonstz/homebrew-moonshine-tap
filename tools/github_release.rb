#!/usr/bin/env ruby
# Run only trusted default-branch controller code. Accept only checked scalar inputs.
require_relative '../lib/github_release'

module MoonshineGitHubCLI
  extend self
  def main(argv = ARGV, env = ENV, api: nil, root: Pathname(__dir__).parent, runner: Open3.method(:capture3))
    MoonshineGitHub.check(argv.length == 1 && %w[publish promote merge].include?(argv.first), 'Usage: ruby tools/github_release.rb publish|promote|merge')
    candidate_enabled = env['MOONSHINE_RELEASE_UPDATES_ENABLED'] == 'true'
    promotion_enabled = env['MOONSHINE_STABLE_PROMOTION_ENABLED'] == 'true'
    enabled = argv.first == 'promote' ? promotion_enabled : argv.first == 'publish' ? candidate_enabled : candidate_enabled || promotion_enabled
    MoonshineGitHub.check(env['GITHUB_REPOSITORY'] == MoonshineGitHub::REPOSITORY && enabled,
      'Requested release automation is not activated for this repository')
    if argv.first == 'promote'
      MoonshineGitHub.check(env['GITHUB_EVENT_NAME'] == 'workflow_dispatch' && env['GITHUB_REF'] == 'refs/heads/main' &&
        env['GITHUB_ACTOR'] == 'evertonstz' && env['GITHUB_TRIGGERING_ACTOR'] == 'evertonstz',
        'Promotion requires an owner request on trusted main')
      MoonshineGitHub.check(%w[MOONSHINE_RELEASE MOONSHINE_ASSET_ID MOONSHINE_RECIPE_SHA256 MOONSHINE_EXPECTED_CURRENT
        MOONSHINE_OPERATION MOONSHINE_ROLLBACK_REASON MOONSHINE_NATIVE_EVIDENCE].all? { |name| env[name].to_s.empty? },
        'Cannot mix promotion with candidate publication inputs')
    elsif argv.first == 'publish'
      MoonshineGitHub.check(%w[schedule workflow_dispatch workflow_run].include?(env['GITHUB_EVENT_NAME']) &&
        env['GITHUB_REF'] == 'refs/heads/main', 'Publication requires a default-branch detection run')
    else
      MoonshineGitHub.check(env['GITHUB_EVENT_NAME'] == 'workflow_run', 'Merge requires CI completion metadata')
    end
    MoonshineGitHub.check(env['MOONSHINE_TOKEN_APP_SLUG'] == env.fetch('MOONSHINE_APP_SLUG'), 'Token App does not match configured identity')
    api ||= MoonshineGitHub::API.new(token: env.fetch('MOONSHINE_APP_TOKEN'))
    controller = MoonshineGitHub::Controller.new(api: api, root: root,
      bot_slug: env.fetch('MOONSHINE_APP_SLUG'), bot_id: Integer(env.fetch('MOONSHINE_BOT_ID'), 10),
      check_app_id: Integer(env.fetch('MOONSHINE_CHECK_APP_ID'), 10),
      promotions_enabled: promotion_enabled, candidates_enabled: candidate_enabled)
    base, _, status = runner.call('git', '-C', root.to_s, 'rev-parse', 'HEAD')
    MoonshineGitHub.check(status.success?, 'Cannot identify trusted checkout')
    base = MoonshineGitHub.sha(base.strip)
    result = if argv.first == 'promote'
      MoonshineGitHub.check(base == env['MOONSHINE_BASE_SHA'], 'Prerequisite and publisher baselines differ')
      id = env.fetch('MOONSHINE_NATIVE_COMMENT_ID')
      MoonshineGitHub.check(id.match?(/\A[1-9][0-9]{0,18}\z/), 'Invalid GitHub comment identity')
      selection = {'target' => env.fetch('MOONSHINE_PROMOTION_TARGET'), 'expected_stable' => env.fetch('MOONSHINE_EXPECTED_STABLE'),
        'origin' => {'comment_id' => Integer(id, 10), 'body_sha256' => env.fetch('MOONSHINE_NATIVE_COMMENT_SHA256'),
                     'updated_at' => env.fetch('MOONSHINE_NATIVE_COMMENT_UPDATED_AT')},
        'report_sha256' => env.fetch('MOONSHINE_NATIVE_REPORT_SHA256')}
      controller.publish(base: base, promotion: selection)
    elsif argv.first == 'publish'
      MoonshineGitHub.check(base == env['MOONSHINE_BASE_SHA'], 'Detection and publisher baselines differ')
      controller.checked_main!(base, Integer(env.fetch('MOONSHINE_SOURCE_CI_RUN_ID'), 10)) if env['GITHUB_EVENT_NAME'] == 'workflow_run'
      selection = {}
      if env['MOONSHINE_RECIPE_SHA256'] && !env['MOONSHINE_RECIPE_SHA256'].empty?
        selection = {recipe: env['MOONSHINE_RECIPE_SHA256'], expected_current: env['MOONSHINE_EXPECTED_CURRENT'].to_s.empty? ? nil : env['MOONSHINE_EXPECTED_CURRENT'],
                     operation: env.fetch('MOONSHINE_OPERATION', 'forward'), reason: env['MOONSHINE_ROLLBACK_REASON'].to_s.empty? ? nil : env['MOONSHINE_ROLLBACK_REASON']}
        MoonshineGitHub.check(env['GITHUB_EVENT_NAME'] == 'workflow_dispatch' && env['GITHUB_ACTOR'] == 'evertonstz', 'Only the owner can request rollback') if selection[:operation] == 'rollback'
      end
      controller.publish(base: base, release: JSON.parse(env.fetch('MOONSHINE_RELEASE'), max_nesting: 5),
        asset: Integer(env.fetch('MOONSHINE_ASSET_ID'), 10), **selection)
    else
      controller.merge(base: base, run_id: Integer(env.fetch('MOONSHINE_CI_RUN_ID'), 10))
    end
    puts JSON.generate(result)
    0
  rescue MoonshineGitHub::Failure => e
    warn "Release controller refused: #{e.message}"
    1
  rescue StandardError
    # Do not echo untrusted response bodies, credentials, event data or parse failures.
    warn 'Release controller failed; owner review required. No automatic retry or bypass.'
    1
  end
end
exit MoonshineGitHubCLI.main if $PROGRAM_NAME == __FILE__

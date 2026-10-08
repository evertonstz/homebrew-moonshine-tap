#!/usr/bin/env ruby
# Run only trusted default-branch controller code. Accept only checked scalar inputs.
require_relative '../lib/github_release'

module MoonshineGitHubCLI
  extend self
  def main(argv = ARGV, env = ENV)
    MoonshineGitHub.check(argv.length == 1 && %w[publish merge].include?(argv.first), 'Usage: ruby tools/github_release.rb publish|merge')
    MoonshineGitHub.check(env['GITHUB_REPOSITORY'] == MoonshineGitHub::REPOSITORY &&
      env['MOONSHINE_RELEASE_UPDATES_ENABLED'] == 'true', 'Release automation is not activated for this repository')
    if argv.first == 'publish'
      MoonshineGitHub.check(%w[schedule workflow_dispatch workflow_run].include?(env['GITHUB_EVENT_NAME']) &&
        env['GITHUB_REF'] == 'refs/heads/main', 'Publication requires a default-branch detection run')
    else
      MoonshineGitHub.check(env['GITHUB_EVENT_NAME'] == 'workflow_run', 'Merge requires CI completion metadata')
    end
    MoonshineGitHub.check(env['MOONSHINE_TOKEN_APP_SLUG'] == env.fetch('MOONSHINE_APP_SLUG'), 'Token App does not match configured identity')
    api = MoonshineGitHub::API.new(token: env.fetch('MOONSHINE_APP_TOKEN'))
    controller = MoonshineGitHub::Controller.new(api: api, root: Pathname(__dir__).parent,
      bot_slug: env.fetch('MOONSHINE_APP_SLUG'), bot_id: Integer(env.fetch('MOONSHINE_BOT_ID'), 10),
      check_app_id: Integer(env.fetch('MOONSHINE_CHECK_APP_ID'), 10))
    base, _, status = Open3.capture3('git', 'rev-parse', 'HEAD')
    MoonshineGitHub.check(status.success?, 'Cannot identify trusted checkout')
    base = MoonshineGitHub.sha(base.strip)
    result = if argv.first == 'publish'
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

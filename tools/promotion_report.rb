#!/usr/bin/env ruby
require_relative '../lib/promotion'
require_relative 'check_releases'

module MoonshinePromotionReport
  extend self
  def main(argv = ARGV, env = ENV, api: nil, root: Pathname(__dir__).parent, client: nil, runner: Open3.method(:capture3))
    MoonshineReleases.check((argv.empty? || argv.length == 1) && env['GITHUB_EVENT_NAME'] == 'workflow_dispatch' &&
      env['GITHUB_REPOSITORY'] == 'evertonstz/homebrew-moonshine-tap' && env['GITHUB_REF'] == 'refs/heads/main' &&
      env['GITHUB_ACTOR'] == 'evertonstz' && env['GITHUB_TRIGGERING_ACTOR'] == 'evertonstz',
      'Promotion requires an owner request on trusted main')
    MoonshineReleases.check(env['MOONSHINE_APP_TOKEN'].to_s.empty?, 'Package prerequisites must not carry write credentials')
    MoonshineReleases.check(argv.empty? || (argv.first.is_a?(String) && Pathname(argv.first).absolute? &&
      File.file?(argv.first) && File.executable?(argv.first)), 'Real RPM extraction requires an explicit executable bsdtar')
    target = MoonshineCandidates.identity(env.fetch('MOONSHINE_PROMOTION_TARGET'))
    stable = MoonshineCandidates.identity(env.fetch('MOONSHINE_EXPECTED_STABLE'))
    source_names = %w[MOONSHINE_NATIVE_COMMENT_ID MOONSHINE_NATIVE_COMMENT_SHA256 MOONSHINE_NATIVE_COMMENT_UPDATED_AT]
    if source_names.any? { |name| env.key?(name) }
      MoonshineReleases.check(source_names.all? { |name| env[name].is_a?(String) && !env[name].empty? } &&
        env.fetch('MOONSHINE_NATIVE_EVIDENCE', '').empty?, 'Incomplete or mixed native report origin request')
      id = env.fetch('MOONSHINE_NATIVE_COMMENT_ID')
      MoonshineReleases.check(id.bytesize <= 19 && id.match?(/\A[1-9][0-9]*\z/), 'Invalid GitHub comment identity')
      origin = {'comment_id' => id.to_i, 'body_sha256' => env.fetch('MOONSHINE_NATIVE_COMMENT_SHA256'),
                'updated_at' => env.fetch('MOONSHINE_NATIVE_COMMENT_UPDATED_AT')}
      MoonshineNativeEvidence.digest(origin['body_sha256'], 'Invalid native report body digest')
      MoonshineNativeOrigin.timestamp(origin['updated_at'])
      MoonshineGitHub.integer(origin['comment_id'])
      api ||= MoonshineGitHub::API.new(token: env.fetch('GH_TOKEN'))
      result = MoonshinePromotion.assess(root: root, target: target, expected_stable: stable, origin: origin, api: api)
    else
      result = MoonshinePromotion.assess(root: root, target: target, expected_stable: stable,
                                        evidence: env.fetch('MOONSHINE_NATIVE_EVIDENCE'))
    end
    unless argv.empty?
      MoonshineReleases.check(result['owner_report_authenticated'] == true, 'Package prerequisites require authenticated report origin')
      changes = MoonshinePromotion.projection(root: root, target: target, expected_stable: stable, api: api)
      MoonshineReleases.check(!changes.empty?, 'Recipe is already accepted; do not publish a promotion loop')
      base, _, status = runner.call('git', '-C', root.to_s, 'rev-parse', 'HEAD')
      MoonshineGitHub.check(status.success?, 'Cannot identify trusted promotion checkout')
      base = MoonshineGitHub.sha(base.strip)
      before = MoonshineCandidate.tree(root)
      packages = MoonshineReleaseCheck.run(root: root, bsdtar: argv.first,
        client: client || MoonshineUpdate::HTTP.new(token: env['GH_TOKEN']), compare: true, runner: runner)
      # Package inspection does not freeze mutable owner comments or the trusted base.
      MoonshinePromotion.patch(root: root, target: target, expected_stable: stable,
        origin: origin, api: api, report_sha256: result['report_sha256'])
      current = api.call('GET', "/repos/#{MoonshineGitHub::REPOSITORY}/git/ref/heads/main")
      MoonshineGitHub.check(current.dig('object', 'sha') == base, 'Default branch changed; fresh validation required')
      MoonshineReleases.check(MoonshineCandidate.tree(root) == before, 'Promotion prerequisite inputs changed')
      fields = {'status' => 'eligible', 'base_sha' => base, 'target' => target, 'expected_stable' => stable,
                'comment_id' => origin['comment_id'].to_s, 'comment_sha256' => origin['body_sha256'],
                'comment_updated_at' => origin['updated_at'], 'report_sha256' => result['report_sha256']}
      File.open(env.fetch('GITHUB_OUTPUT'), 'a') { |file| fields.each { |key, value| file.puts("#{key}=#{value}") } }
      puts JSON.pretty_generate(result.merge('packages' => packages))
      return 0
    end
    puts JSON.pretty_generate(result)
    raise MoonshineReleases::Failure, 'Read-only report matching cannot authorize publication; package prerequisites were not requested'
  rescue StandardError => e
    warn "Promotion refused before write credentials: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshinePromotionReport.main if $PROGRAM_NAME == __FILE__

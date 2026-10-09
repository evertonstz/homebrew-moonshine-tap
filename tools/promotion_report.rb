#!/usr/bin/env ruby
require_relative '../lib/promotion'

module MoonshinePromotionReport
  extend self
  def main(argv = ARGV, api: nil)
    MoonshineReleases.check(argv.empty? && ENV['GITHUB_EVENT_NAME'] == 'workflow_dispatch' &&
      ENV['GITHUB_REPOSITORY'] == 'evertonstz/homebrew-moonshine-tap' && ENV['GITHUB_REF'] == 'refs/heads/main' &&
      ENV['GITHUB_ACTOR'] == 'evertonstz' && ENV['GITHUB_TRIGGERING_ACTOR'] == 'evertonstz',
      'Promotion requires an owner request on trusted main')
    target = MoonshineCandidates.identity(ENV.fetch('MOONSHINE_PROMOTION_TARGET'))
    stable = MoonshineCandidates.identity(ENV.fetch('MOONSHINE_EXPECTED_STABLE'))
    source_names = %w[MOONSHINE_NATIVE_COMMENT_ID MOONSHINE_NATIVE_COMMENT_SHA256 MOONSHINE_NATIVE_COMMENT_UPDATED_AT]
    if source_names.any? { |name| ENV.key?(name) }
      MoonshineReleases.check(source_names.all? { |name| ENV[name].is_a?(String) && !ENV[name].empty? } &&
        ENV.fetch('MOONSHINE_NATIVE_EVIDENCE', '').empty?, 'Incomplete or mixed native report origin request')
      id = ENV.fetch('MOONSHINE_NATIVE_COMMENT_ID')
      MoonshineReleases.check(id.bytesize <= 19 && id.match?(/\A[1-9][0-9]*\z/), 'Invalid GitHub comment identity')
      origin = {'comment_id' => id.to_i, 'body_sha256' => ENV.fetch('MOONSHINE_NATIVE_COMMENT_SHA256'),
                'updated_at' => ENV.fetch('MOONSHINE_NATIVE_COMMENT_UPDATED_AT')}
      MoonshineNativeEvidence.digest(origin['body_sha256'], 'Invalid native report body digest')
      MoonshineNativeOrigin.timestamp(origin['updated_at'])
      MoonshineGitHub.integer(origin['comment_id'])
      api ||= MoonshineGitHub::API.new(token: ENV.fetch('GH_TOKEN'))
      result = MoonshinePromotion.assess(root: Pathname(__dir__).parent, target: target, expected_stable: stable, origin: origin, api: api)
    else
      result = MoonshinePromotion.assess(root: Pathname(__dir__).parent, target: target, expected_stable: stable,
                                        evidence: ENV.fetch('MOONSHINE_NATIVE_EVIDENCE'))
    end
    puts JSON.pretty_generate(result)
    raise MoonshineReleases::Failure, 'Protected promotion publisher is not implemented; report matching cannot authorize publication'
  rescue StandardError => e
    warn "Promotion refused before write credentials: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshinePromotionReport.main if $PROGRAM_NAME == __FILE__

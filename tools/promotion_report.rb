#!/usr/bin/env ruby
require_relative '../lib/promotion'

module MoonshinePromotionReport
  extend self
  def main(argv = ARGV)
    MoonshineReleases.check(argv.empty? && ENV['GITHUB_EVENT_NAME'] == 'workflow_dispatch' &&
      ENV['GITHUB_REPOSITORY'] == 'evertonstz/homebrew-moonshine-tap' && ENV['GITHUB_REF'] == 'refs/heads/main' &&
      ENV['GITHUB_ACTOR'] == 'evertonstz' && ENV['GITHUB_TRIGGERING_ACTOR'] == 'evertonstz',
      'Promotion requires an owner request on trusted main')
    target = MoonshineCandidates.identity(ENV.fetch('MOONSHINE_PROMOTION_TARGET'))
    stable = MoonshineCandidates.identity(ENV.fetch('MOONSHINE_EXPECTED_STABLE'))
    result = MoonshinePromotion.assess(root: Pathname(__dir__).parent, target: target, expected_stable: stable,
                                      evidence: ENV.fetch('MOONSHINE_NATIVE_EVIDENCE'))
    puts JSON.pretty_generate(result)
    raise MoonshineReleases::Failure, 'Protected promotion publisher is not implemented; report matching cannot authorize publication'
  rescue StandardError => e
    warn "Promotion refused before write credentials: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshinePromotionReport.main if $PROGRAM_NAME == __FILE__

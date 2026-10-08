#!/usr/bin/env ruby
# Hosted read-only integration check. Restore the checkout after loading a private candidate.
require 'optparse'
require_relative '../lib/release_candidate'
require_relative 'check_casks'
require_relative 'check_releases'

module MoonshineCandidateCheck
  extend self

  def run(root:, brew:, tap:, bsdtar:, source:)
    before = MoonshineCandidate.tree(root)
    current = MoonshineCandidates.recipe(root)
    release = current ? current.release : MoonshineReleases.development(root).release
    stage = MoonshineCandidate::Store.new.prepare_channel(root, release: release, source: source,
                                                          expected_current: current&.identity)
    begin
      staged = MoonshineCandidate.tree(stage['directory'])
      changed = (before.keys | staged.keys).select { |name| before[name] != staged[name] }
      MoonshineUpdate.check(changed.all? { |name| name.start_with?('Casks/', 'releases/candidates/') }, 'Private candidate changed maintained inputs')
      changed.each do |name|
        path = Pathname(root)/name
        if staged[name]
          path.dirname.mkpath
          path.binwrite(staged[name])
        elsif path.exist?
          path.delete
        end
      end
      # No expired empty slot directories are allowed by the catalog loader.
      (Pathname(root)/'releases/candidates').children.select(&:directory?).each { |path| path.rmdir if path.children.empty? }
      MoonshineCask.generate(root: root, check: true)
      loading = MoonshineCaskCheck.run(root: root, brew: brew, tap: tap)
      extraction = MoonshineReleaseCheck.run(root: root, bsdtar: bsdtar, client: MoonshineUpdate::HTTP.new,
                                              compare: true)
      {'loading' => loading, 'packages' => extraction, 'private_candidate_only' => true, 'host_installation' => false}
    ensure
      actual = MoonshineCandidate.tree(root)
      (before.keys | actual.keys).each do |name|
        next if before[name] == actual[name]
        MoonshineUpdate.check(name.start_with?('Casks/', 'releases/candidates/'), 'Unexpected checkout mutation during private candidate validation')
        path = Pathname(root)/name
        if before[name]
          path.dirname.mkpath
          path.binwrite(before[name])
        elsif path.exist?
          path.delete
        end
      end
      candidate_parent = Pathname(root)/'releases/candidates'
      if candidate_parent.directory?
        candidate_parent.children.select(&:directory?).each { |path| path.rmdir if path.children.empty? }
        candidate_parent.rmdir if candidate_parent.children.empty?
      end
      FileUtils.remove_entry_secure(stage['directory'])
      MoonshineUpdate.check(MoonshineCandidate.tree(root) == before, 'Private candidate checkout restoration differs')
    end
  end

  def main(argv = ARGV)
    MoonshineUpdate.check(ENV['GITHUB_ACTIONS'] == 'true' && ENV['GITHUB_REPOSITORY'] == MoonshineTokenGuard::TAP.sub('/moonshine-tap', '/homebrew-moonshine-tap'),
                          'Private Homebrew candidate validation runs only on this repository hosted CI')
    options = {}
    parser = OptionParser.new do |flags|
      flags.on('--brew FILE') { |value| options[:brew] = value }
      flags.on('--tap TAP') { |value| options[:tap] = value }
      flags.on('--bsdtar FILE') { |value| options[:bsdtar] = value }
    end
    parser.parse!(argv)
    MoonshineUpdate.check(argv.empty? && options.keys.sort == %i[brew bsdtar tap], 'Usage: check_candidate.rb --brew FILE --tap TAP --bsdtar FILE')
    source, _, status = Open3.capture3('git', 'rev-parse', 'HEAD')
    MoonshineUpdate.check(status.success?, 'Cannot bind the private candidate source')
    puts JSON.pretty_generate(run(root: Pathname(__dir__).parent, source: source.strip, **options))
    0
  rescue StandardError => e
    warn "Private candidate validation failed: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshineCandidateCheck.main if $PROGRAM_NAME == __FILE__

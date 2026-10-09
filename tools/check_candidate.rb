#!/usr/bin/env ruby
# Hosted read-only integration check. Restore the checkout after loading a private candidate.
require 'optparse'
require_relative '../lib/release_candidate'
require_relative 'check_casks'
require_relative 'check_releases'

module MoonshineCandidateCheck
  extend self

  def process(*args)
    args.first.is_a?(Array) ? MoonshineCaskCheck.command(args.first) : Open3.capture3(*args)
  end

  def validation_path?(name)
    name.start_with?('Casks/', 'releases/candidates/', 'releases/stable/', 'releases/previous/') || name == 'releases/catalog.json'
  end

  def run(root:, brew:, tap:, bsdtar:, source:, runner: method(:process), client: MoonshineUpdate::HTTP.new)
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
      loading = MoonshineCaskCheck.run(root: root, brew: brew, tap: tap, runner: ->(args) { runner.call(args) })
      extraction = MoonshineReleaseCheck.run(root: root, bsdtar: bsdtar, client: client,
                                              compare: true, runner: runner)
      # Synthetic delivery metadata exercises actual Homebrew loading and package checks.
      # It is not a promotion, native attestation or positive publisher prerequisite.
      stable = MoonshineReleases.current(root)
      target = MoonshineCandidates.recipe(root)
      if target.identity != stable.identity
        preview = MoonshineCandidate.tree(root)
        accepted_paths = MoonshineReleases.tokens(root).reject { |token| token == 'moonshine@untested' }.map { |token| "Casks/#{token}.rb" }
        preview.delete_if { |name, _| name.start_with?('releases/stable/', 'releases/previous/') || accepted_paths.include?(name) }
        preview.merge!(MoonshinePromotion.snapshot('stable', target)).merge!(MoonshinePromotion.snapshot('previous', stable))
        record = MoonshineCandidates.catalog(root)['history'].find { |item| item['identity'] == target.identity }
        preview['releases/catalog.json'] = JSON.pretty_generate('schema' => 2, 'stable' => 'stable', 'previous' => 'previous',
          'deliveries' => {'stable' => {'style' => 'recipe', 'identity' => target.identity, 'source_sha' => record.fetch('source_sha')},
                          'previous' => stable.delivery || {'style' => 'legacy', 'identity' => stable.identity, 'source_sha' => nil}}) + "\n"
        actual = MoonshineCandidate.tree(root)
        (actual.keys | preview.keys).each do |name|
          next if actual[name] == preview[name]
          MoonshineUpdate.check(validation_path?(name), 'Private delivery changed unrelated inputs')
          path = Pathname(root)/name
          if preview[name]
            path.dirname.mkpath
            path.binwrite(preview[name])
          elsif path.exist?
            path.delete
          end
        end
        MoonshineCask.generate(root: root)
      end
      delivery_loading = MoonshineCaskCheck.run(root: root, brew: brew, tap: tap, runner: ->(args) { runner.call(args) })
      delivery_packages = MoonshineReleaseCheck.run(root: root, bsdtar: bsdtar, client: client, compare: true, runner: runner)
      {'loading' => loading, 'packages' => extraction, 'private_candidate_only' => true, 'host_installation' => false,
       'delivery_preview' => {'loading' => delivery_loading, 'packages' => delivery_packages,
         'private_only' => true, 'publication_enabled' => false, 'native_acceptance_verified' => false, 'host_installation' => false}}
    ensure
      actual = MoonshineCandidate.tree(root)
      (before.keys | actual.keys).each do |name|
        next if before[name] == actual[name]
        MoonshineUpdate.check(validation_path?(name), 'Unexpected checkout mutation during private candidate validation')
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

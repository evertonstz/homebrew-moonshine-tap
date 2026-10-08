require 'minitest/autorun'
require_relative '../lib/release_candidate'
require_relative '../lib/moonshine_token_guard'
require_relative '../lib/promotion'

class CandidateCatalogTest < Minitest::Test
  ROOT = Pathname(__dir__).parent
  C = MoonshineCandidates
  R = MoonshineReleases

  def fixture
    Dir.mktmpdir('moonshine-channel-test-') do |directory|
      root = Pathname(directory)
      MoonshineCandidate.tree(ROOT).reject { |name, _| name.start_with?('releases/candidates/') || name == 'Casks/moonshine@untested.rb' }.each do |name, bytes|
        path = root/name
        path.dirname.mkpath
        path.binwrite(bytes)
      end
      MoonshineCask.generate(root: root)
      yield root
    end
  end

  def apply(root, changes)
    changes.each do |name, bytes|
      path = root/name
      if bytes
        path.dirname.mkpath
        path.binwrite(bytes)
      else
        path.delete
      end
    end
    root.glob('releases/candidates/*').select(&:directory?).each { |path| path.rmdir if path.children.empty? }
    MoonshineCask.generate(root: root, check: true)
  end

  def advance(root, source, release = R.current(root).release)
    changes = C.patch(root: root, release: release, source: source * 40, expected_current: C.catalog(root)['current'])
    apply(root, changes)
    C.recipe(root)
  end

  def test_same_rpm_creates_hash_versioned_candidate_with_separate_official_url_and_frozen_stable
    fixture do |root|
      accepted = R.recipes(root).map { |recipe| [recipe.identity, recipe.template, recipe.source] }
      before = MoonshineCandidate.tree(root)
      item = advance(root, 'a')
      assert_equal accepted, R.recipes(root).map { |recipe| [recipe.identity, recipe.template, recipe.source] }
      assert_equal %w[cask.rb helper.rb release.json], (root/'releases/candidates'/item.identity).children.map { |path| path.basename.to_s }.sort
      text = (root/'Casks/moonshine@untested.rb').read
      assert_includes text, "version \"0.16.1+#{item.identity}\""
      assert_includes text, 'releases/download/v0.16.1/moonshine-0.16.1-1.x86_64.rpm'
      assert_includes text, 'Opt-in untested integration recipe'
      refute_includes text, 'releases/download/v0.16.1+'
      assert_equal ['moonshine', 'moonshine@0.16.1', 'moonshine@0.16.0', 'moonshine@untested'], R.tokens(root)
      %w[lib/moonshine_host.rb reference/scriptlets.json releases/stable/cask.rb releases/previous/cask.rb].each do |name|
        assert_equal before[name], (root/name).binread
      end
      assert_empty C.patch(root: root, release: item.release, source: 'b' * 40, expected_current: item.identity)
    end
  end

  def test_helper_guard_and_lifecycle_changes_change_identity_but_docs_and_tests_do_not
    fixture do |root|
      initial = C.build(root, R.current(root).release).identity
      (root/'README.md').write('unrelated docs')
      (root/'tests/unrelated.rb').write('# unrelated test')
      assert_equal initial, C.build(root, R.current(root).release).identity
      %w[lib/moonshine_host.rb lib/moonshine_token_guard.rb].each do |name|
        path = root/name
        original = path.read
        path.write(original + "\n# relevant source change\n")
        refute_equal initial, C.build(root, R.current(root).release).identity
        path.write(original)
      end
      # The compiler is exercised in a separate process, not replaced with a mock.
      path = root/'tools/generate_cask.rb'
      path.write(path.read.sub('["libarchive", "erofs-utils"]', '["libarchive", "erofs-utils", "new-dependency"]'))
      script = "require #{(root/'lib/release_candidate.rb').to_s.inspect}; puts MoonshineCandidates.build(#{root.to_s.inspect}, MoonshineReleases.current(#{root.to_s.inspect}).release).identity"
      output, error, status = Open3.capture3(RbConfig.ruby, '-e', script)
      assert status.success?, error
      refute_equal initial, output.strip
    end
  end

  def test_current_previous_retention_expires_payload_but_preserves_history_and_refuses_expired_targets
    fixture do |root|
      first = advance(root, 'a')
      helper = root/'lib/moonshine_host.rb'
      helper.write(helper.read + "\n# candidate second\n")
      second = advance(root, 'b')
      helper.write(helper.read + "\n# candidate third\n")
      third = advance(root, 'c')
      data = C.catalog(root)
      assert_equal [third.identity, second.identity], data.values_at('current', 'previous')
      assert_equal [first.identity, second.identity, third.identity], data['history'].map { |record| record['identity'] }
      refute (root/'releases/candidates'/first.identity).exist?
      before = MoonshineCandidate.tree(root)
      assert_raises(R::Failure) { C.recipe(root, first.identity) }
      assert_raises(R::Failure) do
        C.patch(root: root, release: first.release, source: 'd' * 40, expected_current: third.identity,
                operation: 'rollback', target: first.identity, reason: 'native failure')
      end
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_rollback_requires_exact_current_target_and_reason_and_cannot_be_automatically_undone
    fixture do |root|
      first = advance(root, 'a')
      helper = root/'lib/moonshine_host.rb'
      helper.write(helper.read + "\n# second recipe\n")
      second = advance(root, 'b')
      before = MoonshineCandidate.tree(root)
      assert_raises(R::Failure) { C.patch(root: root, release: first.release, source: 'c' * 40, expected_current: nil) }
      assert_raises(R::Failure) do
        C.patch(root: root, release: first.release, source: 'c' * 40, expected_current: second.identity,
                operation: 'rollback', target: first.identity)
      end
      assert_equal before, MoonshineCandidate.tree(root)
      apply(root, C.patch(root: root, release: first.release, source: 'c' * 40, expected_current: second.identity,
                          operation: 'rollback', target: first.identity, reason: 'Owner selected the retained working recipe'))
      assert_equal first.identity, C.catalog(root)['current']
      assert_raises(R::Failure) { C.patch(root: root, release: second.release, source: 'd' * 40, expected_current: first.identity) }
      assert_equal second.identity, C.catalog(root)['previous']
    end
  end

  def test_candidate_loading_and_patch_reconstruction_never_execute_development_helper
    fixture do |root|
      sentinel = root/'unexpected-execution'
      helper = root/'lib/moonshine_host.rb'
      helper.write(helper.read + "\nFile.write(#{sentinel.to_s.inspect}, 'executed')\n")
      item = advance(root, 'a')
      assert_equal item.identity, C.recipe(root).identity
      refute sentinel.exist?
    end
  end

  def test_same_upstream_release_is_eligible_for_a_new_recipe_but_unchanged_after_selection
    rpm = ENV['MOONSHINE_TEST_RPM']
    skip 'Official package is supplied by mandatory CI' unless rpm && File.file?(rpm)
    fixture do |root|
      release = R.development(root).release
      client = Object.new
      client.define_singleton_method(:json) do |url|
        raise 'Wrong official API' unless url == MoonshineUpdate::API
        {'draft' => false, 'prerelease' => false, 'tag_name' => "v#{release['version']}",
         'assets' => [{'id' => 123, 'name' => release['filename'], 'state' => 'uploaded', 'size' => File.size(rpm),
                       'browser_download_url' => MoonshineUpdate.download_url(release), 'digest' => "sha256:#{release['sha256']}"}]}
      end
      client.define_singleton_method(:download) do |url, path|
        raise 'Unexpected package URL' unless url == MoonshineUpdate.download_url(release)
        FileUtils.cp(rpm, path)
      end
      checker = MoonshineUpdate::Contract.new(bsdtar: ENV.fetch('MOONSHINE_TEST_BSDTAR'))
      updater = MoonshineUpdate::Updater.new(root: root, client: client, inspector: checker,
        source_sha: 'a' * 40, store: MoonshineCandidate::Store.new)
      before = MoonshineCandidate.tree(root)
      report = updater.run(prepare: true)
      assert_equal 'eligible', report['status'], report.inspect
      assert_equal release, report['release']
      assert_equal before, MoonshineCandidate.tree(root)
      staged = report.fetch('candidate').fetch('directory')
      begin
        assert_equal report['recipe_sha256'], C.recipe(staged).identity
        unchanged = MoonshineUpdate::Updater.new(root: staged, client: client, inspector: checker,
                                                  source_sha: 'b' * 40).run
        assert_equal 'unchanged', unchanged['status']
      ensure
        FileUtils.remove_entry_secure(staged)
      end
    end
  end

  def test_scriptlet_digest_preserves_newline_normalization_and_exact_interpreter_binding
    rpm_path = ENV['MOONSHINE_TEST_RPM']
    skip 'Official package is supplied by mandatory CI' unless rpm_path && File.file?(rpm_path)
    package = MoonshineHost::Rpm.new(rpm_path)
    package.tags[1024] += "\n\n"
    package.validate
    package.tags[1086] = ['/bin/sh', '-c']
    assert_raises(MoonshineHost::Failure) { package.validate }
    package.tags[1086] = ['/bin/sh']
    package.tags[1024] += '# unapproved script'
    assert_raises(MoonshineHost::Failure) { package.validate }
    assert MoonshineHost::APPROVED_SCRIPTLETS['postinstall'].frozen?
    assert MoonshineHost::APPROVED_SCRIPTLETS['postinstall']['interpreter'].frozen?
  end

  def test_untested_guard_refuses_other_variants_and_invalid_names
    assert_empty MoonshineTokenGuard.conflicts('evertonstz/moonshine-tap/moonshine@untested',
                                                ['evertonstz/moonshine-tap/moonshine@untested'])
    assert_equal ['evertonstz/moonshine-tap/moonshine'], MoonshineTokenGuard.conflicts(
      'evertonstz/moonshine-tap/moonshine@untested', ['evertonstz/moonshine-tap/moonshine'])
    assert_raises(MoonshineTokenGuard::Failure) { MoonshineTokenGuard.conflicts('evertonstz/moonshine-tap/moonshine@latest', []) }
  end

  def test_same_version_stable_replacement_cannot_be_projected
    fixture do |root|
      item = advance(root, 'a')
      before = MoonshineCandidate.tree(root)
      error = assert_raises(R::Failure) do
        MoonshinePromotion.projection(root: root, target: item.identity, expected_stable: R.current(root).identity)
      end
      assert_includes error.message, 'explicit delivery policy'
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_changed_script_approval_or_candidate_bytes_refuse_without_writes
    fixture do |root|
      advance(root, 'a')
      path = root/'reference/scriptlets.json'
      data = JSON.parse(path.read)
      data['scriptlets']['postinstall']['sha256'] = '0' * 64
      path.write(JSON.generate(data))
      before = MoonshineCandidate.tree(root)
      assert_raises(R::Failure) { C.build(root, R.current(root).release) }
      assert_equal before, MoonshineCandidate.tree(root)
      current = C.catalog(root)['current']
      (root/'releases/candidates'/current/'cask.rb').write('# changed')
      assert_raises(R::Failure) { MoonshineCask.outputs(root: root) }
    end
  end
end

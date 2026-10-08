require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/moonshine_host'
require_relative '../lib/release_catalog'
require_relative '../lib/moonshine_token_guard'
require_relative '../tools/generate_cask'
require_relative '../tools/lock_recipes'

class ReleaseCatalogTest < Minitest::Test
  R = MoonshineReleases
  ROOT = Pathname(__dir__).parent

  def fixture
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      %w[lib/moonshine_host.rb lib/moonshine_token_guard.rb reference/postinstall.sh reference/postremove.sh].each do |name|
        (root/name).dirname.mkpath
        FileUtils.cp(name.start_with?("reference/") ? ROOT/"tests/fixtures/#{File.basename(name)}" : ROOT/name, root/name)
      end
      yield root
    end
  end

  def release(version, digest = 'a' * 64)
    {'version' => version, 'sha256' => digest, 'filename' => "moonshine-#{version}-1.x86_64.rpm"}
  end

  def predecessor(root, version = '0.16.0')
    latest = R.current(root)
    source = latest.source.sub(/^  RELEASE = [^\n]+\.freeze$/, "  RELEASE = #{release(version).inspect}.freeze")
    R.save_previous(root, R::Recipe.new(release: release(version), source: source, scripts: latest.scripts))
  end

  def lock_stable(root)
    recipe = R.current(root)
    dir = root/'releases/stable'
    dir.mkpath
    (dir/'helper.rb').write(recipe.source)
    recipe.scripts.each { |name, body| (dir/"#{name}.sh").write(body + "\n") }
    (dir/'release.json').write(JSON.generate('schema' => 1, 'release' => recipe.release,
                                           'helper_sha256' => Digest::SHA256.hexdigest(recipe.source)))
    (root/'releases/catalog.json').write(JSON.generate('schema' => 1, 'stable' => 'stable',
                                                      'previous' => (root/'releases/previous').exist? ? 'previous' : nil))
  end

  def freeze_outputs(root)
    recipes = R.recipes(root)
    outputs = MoonshineCask.outputs(root: root)
    recipes.each_with_index do |recipe, index|
      slot = index.zero? ? 'stable' : 'previous'
      dir = root/'releases'/slot
      dir.mkpath
      token = index.zero? ? 'moonshine' : "moonshine@#{recipe.release['version']}"
      template = outputs.fetch("Casks/#{token}.rb")
      template = template.sub("cask #{token.inspect} do", 'cask "__MOONSHINE_TOKEN__" do')
      template = template.sub("  version #{recipe.release['version'].inspect}", '  version "__MOONSHINE_VERSION__"')
      template = template.sub(/^  conflicts_with cask: \[[^\n]*\]$/, '  conflicts_with cask: [__MOONSHINE_CONFLICTS__]')
      template = template.sub("\"evertonstz/moonshine-tap/#{token}\"", '"evertonstz/moonshine-tap/__MOONSHINE_TOKEN__"')
      (dir/'helper.rb').write(recipe.source)
      (dir/'cask.rb').write(template)
      recipe.scripts.each { |name, body| (dir/"#{name}.sh").write(body + "\n") }
      fields = {'schema' => 2, 'release' => recipe.release,
                'helper_sha256' => Digest::SHA256.hexdigest(recipe.source),
                'template_sha256' => Digest::SHA256.hexdigest(template),
                'script_sha256' => recipe.scripts.sort.to_h.transform_values { |body| Digest::SHA256.hexdigest(body) }}
      fields['recipe_sha256'] = Digest::SHA256.hexdigest(JSON.generate(fields.sort.to_h))
      (dir/'release.json').write(JSON.generate(fields))
    end
    (root/'releases/catalog.json').write(JSON.generate('schema' => 1, 'stable' => 'stable',
                                                      'previous' => recipes.length == 2 ? 'previous' : nil))
  end

  def test_lock_builder_freezes_all_offered_recipes_without_changing_any_input
    fixture do |root|
      predecessor(root)
      accepted = MoonshineCask.generate(root: root)
      before = MoonshineCandidate.tree(root)
      changes = MoonshineRecipeLock.patch(root: root)
      assert_equal before, MoonshineCandidate.tree(root)
      refute changes.keys.any? { |name| name.start_with?('Casks/', 'lib/', 'reference/') }
      changes.each do |name, bytes|
        path = root/name
        path.dirname.mkpath
        path.binwrite(bytes)
      end
      assert_equal accepted, MoonshineCask.outputs(root: root)
      assert R.current(root).template
      assert R.previous(root).template
      assert_match(/\A[0-9a-f]{64}\z/, R.current(root).identity)
      assert_equal (root/'releases/stable/helper.rb').expand_path, R.current(root).helper_path
      locked = MoonshineCandidate.tree(root)
      assert_raises(R::Failure) { MoonshineRecipeLock.patch(root: root) }
      assert_equal locked, MoonshineCandidate.tree(root)
    end
  end

  def test_lock_builder_refuses_missing_offered_cask_without_writing
    fixture do |root|
      MoonshineCask.generate(root: root)
      (root/'Casks/moonshine@0.16.1.rb').delete
      before = MoonshineCandidate.tree(root)
      assert_raises(RuntimeError) { MoonshineRecipeLock.patch(root: root) }
      assert_equal before, MoonshineCandidate.tree(root)
      refute (root/'releases').exist?
    end
  end

  def test_complete_snapshots_preserve_token_guard_and_all_stable_outputs
    fixture do |root|
      predecessor(root)
      accepted = MoonshineCask.generate(root: root)
      freeze_outputs(root)
      guard = root/'lib/moonshine_token_guard.rb'
      guard.write(guard.read + "\n# unaccepted candidate guard change\n")

      assert_equal accepted, MoonshineCask.outputs(root: root)
      MoonshineCask.generate(root: root, check: true)
    end
  end

  def test_complete_snapshots_ignore_changed_development_compiler_without_execution
    fixture do |root|
      predecessor(root)
      MoonshineCask.generate(root: root)
      freeze_outputs(root)
      sentinel = root/'unexpected-development-execution'
      helper = root/'lib/moonshine_host.rb'
      helper.write(helper.read + "\nFile.write(#{sentinel.to_s.inspect}, 'executed')\n")
      (root/'tools').mkpath
      FileUtils.cp(ROOT/'lib/release_catalog.rb', root/'lib/release_catalog.rb')
      FileUtils.cp(ROOT/'lib/candidate_catalog.rb', root/'lib/candidate_catalog.rb')
      compiler = (ROOT/'tools/generate_cask.rb').read.sub('["libarchive", "erofs-utils"]', '["unaccepted-dependency"]')
      assert_includes compiler, '["unaccepted-dependency"]'
      (root/'tools/generate_cask.rb').write(compiler)

      output, error, status = Open3.capture3({'RUBYOPT' => nil, 'RUBYLIB' => nil}, RbConfig.ruby,
                                           (root/'tools/generate_cask.rb').to_s, '--check')
      assert status.success?, output + error
      refute sentinel.exist?
    end
  end

  def test_complete_snapshot_digest_refuses_template_and_script_drift_without_execution
    %w[cask.rb postinstall.sh release.json].each do |name|
      fixture do |root|
        MoonshineCask.generate(root: root)
        freeze_outputs(root)
        before = root.glob('**/*').select(&:file?).to_h { |path| [path.to_s, path.binread] }
        path = root/'releases/stable'/name
        if name == 'release.json'
          data = JSON.parse(path.read)
          data['recipe_sha256'] = '0' * 64
          path.write(JSON.generate(data))
        else
          path.write(path.read + "\n# unexpected change\n")
        end
        changed = root.glob('**/*').select(&:file?).to_h { |file| [file.to_s, file.binread] }

        assert_raises(R::Failure) { MoonshineCask.outputs(root: root) }
        assert_equal changed, root.glob('**/*').select(&:file?).to_h { |file| [file.to_s, file.binread] }
        refute_equal before, changed
      end
    end
  end

  def test_complete_snapshot_loading_never_executes_its_helper
    fixture do |root|
      MoonshineCask.generate(root: root)
      freeze_outputs(root)
      dir = root/'releases/stable'
      sentinel = root/'unexpected-snapshot-execution'
      old_source = (dir/'helper.rb').read
      source = old_source + "\nFile.write(#{sentinel.to_s.inspect}, 'executed')\n"
      (dir/'helper.rb').write(source)
      embedded = ->(text) { text.lines.map { |line| line.strip.empty? ? "\n" : '    ' + line }.join }
      template = (dir/'cask.rb').read.sub(embedded.call(old_source)) { embedded.call(source) }
      (dir/'cask.rb').write(template)
      fields = JSON.parse((dir/'release.json').read).reject { |key, _| key == 'recipe_sha256' }
      fields['helper_sha256'] = Digest::SHA256.hexdigest(source)
      fields['template_sha256'] = Digest::SHA256.hexdigest(template)
      fields['recipe_sha256'] = Digest::SHA256.hexdigest(JSON.generate(fields.sort.to_h))
      (dir/'release.json').write(JSON.generate(fields))

      assert_equal source, R.current(root).source
      assert_includes MoonshineCask.outputs(root: root).fetch('Casks/moonshine.rb'), 'unexpected-snapshot-execution'
      refute sentinel.exist?
    end
  end

  def test_development_helper_changes_do_not_rewrite_locked_stable_outputs
    fixture do |root|
      predecessor(root)
      accepted = MoonshineCask.generate(root: root)
      lock_stable(root)
      helper = root/'lib/moonshine_host.rb'
      helper.write(helper.read.sub("IMAGE_NAME = 'moonshine-homebrew'", "IMAGE_NAME = 'unaccepted-development'"))

      assert_equal accepted, MoonshineCask.outputs(root: root)
      MoonshineCask.generate(root: root, check: true)
      assert_equal '0.16.1', R.current(root).release['version']
      assert_equal '0.16.0', R.previous(root).release['version']
    end
  end

  def test_legacy_rotation_refuses_locked_stable_without_changing_inputs
    fixture do |root|
      predecessor(root)
      lock_stable(root)
      before = root.glob('**/*').select(&:file?).to_h { |path| [path.to_s, path.binread] }

      assert_raises(R::Failure) { R.rotate(root, release('0.16.2')) }
      assert_equal before, root.glob('**/*').select(&:file?).to_h { |path| [path.to_s, path.binread] }
    end
  end

  def test_current_metadata_has_one_source_of_truth
    fixture do |root|
      assert_equal MoonshineHost::RELEASE, R.current(root).release
      assert_equal %w[moonshine moonshine@0.16.1], R.tokens(root)
      assert_nil R.previous(root)
    end
  end

  def test_isolated_previous_helper_does_not_change_current_constants
    fixture do |root|
      predecessor(root)
      assert_equal '0.16.0', R.previous(root).release['version']
      assert_equal '0.16.1', R.current(root).release['version']
      assert_equal '0.16.1', MoonshineHost::RELEASE['version']
      assert_equal %w[moonshine moonshine@0.16.1 moonshine@0.16.0], R.tokens(root)
    end
  end

  def test_snapshot_digest_and_metadata_are_checked
    fixture do |root|
      predecessor(root)
      helper = root/'releases/previous/helper.rb'
      sentinel = root/'unexpected-execution'
      helper.write(helper.read + "\nFile.write(#{sentinel.to_s.inspect}, 'executed')\n")
      assert_raises(R::Failure) { R.previous(root) }
      refute sentinel.exist?
    end
    fixture do |root|
      predecessor(root)
      manifest = root/'releases/previous/release.json'
      data = JSON.parse(manifest.read)
      data['release'] = release('0.15.0')
      manifest.write(JSON.generate(data))
      assert_raises(R::Failure) { R.previous(root) }
    end
  end

  def test_snapshot_reference_drift_and_extra_files_fail
    fixture do |root|
      predecessor(root)
      (root/'releases/previous/postinstall.sh').write("echo changed\n")
      assert_raises(R::Failure) { R.previous(root) }
    end
    fixture do |root|
      predecessor(root)
      (root/'releases/previous/unreviewed.rb').write('unexpected')
      assert_raises(R::Failure) { R.previous(root) }
    end
  end

  def test_snapshot_symlink_and_oversized_inputs_fail
    fixture do |root|
      predecessor(root)
      reference = root/'releases/previous/postinstall.sh'
      reference.delete
      reference.make_symlink(root/'reference/postinstall.sh')
      assert_raises(R::Failure) { R.previous(root) }
    end
    fixture do |root|
      (root/'lib/moonshine_host.rb').write('x' * (R::MAX_SOURCE + 1))
      assert_raises(R::Failure) { R.current(root) }
    end
  end

  def test_invalid_versions_and_rpm_identity_fail
    ['../1', '1.2', '01.2.3', '1.2.3-beta', "1.2.3\n", '1.2.3;system("true")'].each do |value|
      assert_raises(R::Failure) { R.metadata(release(value)) }
    end
    assert_raises(R::Failure) { R.metadata(release('1.2.3', 'INVALID')) }
    assert_raises(R::Failure) { R.metadata(release('1.2.3').merge('filename' => 'other.rpm')) }
    assert_equal [0, 16, 10], R.version('0.16.10')
  end

  def test_previous_must_be_older
    fixture do |root|
      predecessor(root, '0.16.1')
      assert_raises(R::Failure) { R.recipes(root) }
    end
  end

  def test_all_tokens_render_their_own_helpers_and_conflicts
    fixture do |root|
      predecessor(root)
      outputs = MoonshineCask.outputs(root: root)
      assert_equal %w[Casks/moonshine.rb Casks/moonshine@0.16.1.rb Casks/moonshine@0.16.0.rb], outputs.keys
      outputs.each do |name, source|
        token = File.basename(name, '.rb')
        assert_includes source, "cask #{token.inspect} do"
        expected_version = token == 'moonshine@0.16.0' ? '0.16.0' : '0.16.1'
        assert_includes source, "version #{expected_version.inspect}"
        refute_includes source, 'VALIDATION.md'
        assert_includes source, 'moonshine-token-guard.rb'
        assert_includes source, 'conflicts_with cask:'
        assert_operator source.index('moonshine-token-guard.rb", "--brew"'), :<, source.index('moonshine-host.rb", "install"')
      end
      previous = outputs.fetch('Casks/moonshine@0.16.0.rb')
      assert_match(/"version"\s*=>\s*"0\.16\.0"/, previous)
      refute_includes previous, 'moonshine-0.16.1-1.x86_64.rpm'
    end
  end

  def test_rotation_preserves_former_current_recipe_and_expires_only_old_previous
    fixture do |root|
      predecessor(root)
      MoonshineCask.generate(root: root)
      former = R.current(root)
      R.rotate(root, release('0.18.4'))
      MoonshineCask.generate(root: root)
      assert_equal former.source, R.previous(root).source
      assert_equal former.release, R.previous(root).release
      assert_equal %w[moonshine moonshine@0.18.4 moonshine@0.16.1], R.tokens(root)
      refute (root/'Casks/moonshine@0.16.0.rb').exist?
      MoonshineCask.generate(root: root, check: true)
    end
  end

  def test_invalid_rotation_leaves_inputs_unchanged
    fixture do |root|
      predecessor(root)
      before = root.glob('**/*').select(&:file?).to_h { |path| [path.to_s, path.read] }
      assert_raises(R::Failure) { R.rotate(root, release('0.15.0')) }
      assert_equal before, root.glob('**/*').select(&:file?).to_h { |path| [path.to_s, path.read] }
    end
  end

  def test_check_mode_detects_previous_drift_and_expired_output
    fixture do |root|
      predecessor(root)
      MoonshineCask.generate(root: root)
      (root/'Casks/moonshine@0.16.0.rb').write('stale')
      assert_raises(RuntimeError) { MoonshineCask.generate(root: root, check: true) }
      MoonshineCask.generate(root: root)
      (root/'Casks/moonshine@0.15.0.rb').write('expired')
      assert_raises(RuntimeError) { MoonshineCask.generate(root: root, check: true) }
    end
  end
end

class TokenGuardTest < Minitest::Test
  G = MoonshineTokenGuard
  TAP = G::TAP

  def test_all_other_variants_conflict_including_expired_and_foreign_tap
    requested = "#{TAP}/moonshine@0.16.0"
    installed = ["#{TAP}/moonshine", "#{TAP}/moonshine@0.14.0", 'other/tap/moonshine@0.16.0', 'unrelated']
    assert_equal installed.first(3), G.conflicts(requested, installed)
    assert_empty G.conflicts(requested, [requested, 'unrelated'])
    assert_equal ['moonshine'], G.conflicts("#{TAP}/moonshine", ['moonshine'])
  end

  def test_guard_rejects_malformed_input
    assert_raises(G::Failure) { G.conflicts('moonshine', []) }
    assert_raises(G::Failure) { G.conflicts("#{TAP}/moonshine", ["name\ncommand"]) }
  end

  def test_normal_operator_guard_returns_before_any_privileged_call
    Dir.mktmpdir do |directory|
      brew = File.join(directory, 'brew')
      File.write(brew, 'not executed')
      File.chmod(0700, brew)
      calls = []
      success = Struct.new(:success?).new(true)
      runner = ->(path) { calls << path; ["#{TAP}/moonshine@0.14.0\n", '', success] }
      _, error = capture_io do
        assert_equal 1, G.main(['--brew', brew, '--token', "#{TAP}/moonshine"], euid: 1000, runner: runner)
      end
      assert_equal [brew], calls
      assert_includes error, 'Do not use --zap'
      calls.clear
      capture_io { assert_equal 1, G.main(['--brew', brew, '--token', "#{TAP}/moonshine"], euid: 0, runner: runner) }
      assert_empty calls
    end
  end

  def test_success_after_explicit_removal_and_list_failure_refuses
    Dir.mktmpdir do |directory|
      brew = File.join(directory, 'brew')
      File.write(brew, 'not executed')
      File.chmod(0700, brew)
      status = Struct.new(:success?).new(true)
      assert_equal 0, G.main(['--brew', brew, '--token', "#{TAP}/moonshine"], euid: 1000,
                            runner: ->(_) { ['unrelated', '', status] })
      status = Struct.new(:success?).new(false)
      capture_io do
        assert_equal 1, G.main(['--brew', brew, '--token', "#{TAP}/moonshine"], euid: 1000,
                              runner: ->(_) { ['', 'listing failed', status] })
      end
    end
  end
end

require_relative 'test_host'

class ReceiptSwitchHost < TransactionHost
  def initialize(root, enabled:, running:)
    super(root)
    @enabled = enabled
    @running = running
  end

  def uninstall
    value = state
    if value['phase'] == 'active'
      value['services'] = {'moonshine@test.service' => {'enabled' => @enabled, 'running' => running}}
      value['recovery'] = value['active']
    end
    value.merge!('active' => nil, 'phase' => 'removed')
    save(value)
    @active_version = nil
    @running = false
  end
end

class VersionSwitchTest < Minitest::Test
  include TestStubs

  def test_explicit_receipt_switch_preserves_four_service_states_and_personal_files
    old_release = {'version' => '0.16.0', 'sha256' => 'b' * 64, 'filename' => 'moonshine-0.16.0-1.x86_64.rpm'}
    %w[enabled disabled].product([true, false]).each do |enabled, running|
      Dir.mktmpdir do |directory|
        personal = Pathname(directory)/'pairing.json'
        personal.write('personal pairing data')
        subject = ReceiptSwitchHost.new(Pathname(directory)/'state', enabled: enabled, running: running)
        subject.manifests['bundle-old']['release'] = old_release
        subject.install('candidate')
        installed = ['evertonstz/moonshine-tap/moonshine']
        target = 'evertonstz/moonshine-tap/moonshine@0.16.0'
        assert_equal installed, MoonshineTokenGuard.conflicts(target, installed)
        subject.uninstall
        installed.clear
        assert_empty MoonshineTokenGuard.conflicts(target, installed)
        builds = []
        stubs(subject, build: ->(package) { builds << package; 'bundle-old' }) do
          with_constant(MoonshineHost, :RELEASE, old_release) { subject.install('old.rpm') }
        end
        assert_equal ['old.rpm'], builds
        assert_equal 'old', subject.active_version
        assert_equal running, subject.running
        assert_equal enabled, subject.state['services']['moonshine@test.service']['enabled']
        assert_equal 'personal pairing data', personal.read
        assert_equal 'bundle-new', subject.state['recovery']
      end
    end
  end

  def test_expired_definition_does_not_remove_the_fixture_installed_recipe
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      source_root = Pathname(__dir__).parent
      %w[lib/moonshine_host.rb lib/moonshine_token_guard.rb reference/postinstall.sh reference/postremove.sh].each do |name|
        (root/name).dirname.mkpath
        FileUtils.cp(name.start_with?("reference/") ? source_root/"tests/fixtures/#{File.basename(name)}" : source_root/name, root/name)
      end
      current = MoonshineReleases.current(root)
      old = {'version' => '0.16.0', 'sha256' => 'b' * 64, 'filename' => 'moonshine-0.16.0-1.x86_64.rpm'}
      helper = current.source.sub(/^  RELEASE = [^\n]+\.freeze$/, "  RELEASE = #{old.inspect}.freeze")
      MoonshineReleases.save_previous(root, MoonshineReleases::Recipe.new(release: old, source: helper, scripts: current.scripts))
      outputs = MoonshineCask.generate(root: root)
      installed_recipe = outputs.fetch('Casks/moonshine@0.16.0.rb').dup
      cached_helper = helper.dup
      next_release = {'version' => '0.18.4', 'sha256' => 'c' * 64, 'filename' => 'moonshine-0.18.4-1.x86_64.rpm'}
      MoonshineReleases.rotate(root, next_release)
      MoonshineCask.generate(root: root)
      refute (root/'Casks/moonshine@0.16.0.rb').exist?
      assert_includes installed_recipe, 'uninstall_preflight_steps do'
      assert_includes installed_recipe, '"{{staged_path}}/moonshine-host.rb", "uninstall"'
      refute_includes cached_helper, 'require_relative'
      assert_includes cached_helper, "def uninstall\n"
      assert_includes installed_recipe, 'moonshine-0.16.0-1.x86_64.rpm'
    end
  end
end

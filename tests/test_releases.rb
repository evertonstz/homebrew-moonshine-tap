require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/release_catalog'
require_relative '../lib/moonshine_token_guard'
require_relative '../tools/generate_cask'

class ReleaseCatalogTest < Minitest::Test
  R = MoonshineReleases
  ROOT = Pathname(__dir__).parent

  def fixture
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      %w[lib/moonshine_host.rb lib/moonshine_token_guard.rb reference/postinstall.sh reference/postremove.sh].each do |name|
        (root/name).dirname.mkpath
        FileUtils.cp(ROOT/name, root/name)
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
        FileUtils.cp(source_root/name, root/name)
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

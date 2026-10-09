require 'minitest/autorun'
require_relative '../lib/promotion'

class NativePolicyTest < Minitest::Test
  ROOT = Pathname(__dir__).parent
  R = MoonshineReleases
  C = MoonshineCandidates

  def fixture
    Dir.mktmpdir('moonshine-native-policy-test-') do |directory|
      root = Pathname(directory)/'tree'
      root.mkpath
      MoonshineCandidate.tree(ROOT).each do |name, bytes|
        path = root/name
        path.dirname.mkpath
        path.binwrite(bytes)
      end
      policy = {
        'schema' => 2, 'state' => 'configured', 'profile' => 'bazzite-owner-v1', 'owner' => 'evertonstz',
        'installation' => {'token' => 'moonshine@untested', 'version' => 'UPSTREAM_VERSION+RECIPE_SHA256', 'baseline' => 'accepted_stable_recipe'},
        'host' => {'os_id' => 'bazzite', 'architecture' => 'x86_64', 'ostree_booted' => true,
                   'selinux' => 'Enforcing', 'minimum_systemd' => 257},
        'checks' => %w[install start video audio keyboard_mouse upgrade uninstall recovery personal_data administrator_state unrelated_extensions groups lingering],
        'service_states' => %w[enabled_running enabled_stopped disabled_running disabled_stopped],
        'os_policy_updates' => 'observe_normal_updates'
      }
      (root/'reference/native-policy.json').write(JSON.pretty_generate(policy) + "\n")
      C.patch(root: root, release: R.current(root).release, source: 'a' * 40, expected_current: nil).each do |name, bytes|
        path = root/name
        path.dirname.mkpath
        bytes ? path.binwrite(bytes) : path.delete
      end
      item = C.recipe(root)
      # Synthetic claims test the report contract, not native host acceptance.
      evidence = {
        'schema' => 1, 'profile' => 'bazzite-owner-v1',
        'policy_sha256' => Digest::SHA256.file(root/'reference/native-policy.json').hexdigest,
        'recipe_sha256' => item.identity, 'rpm' => item.release,
        'installed_token' => 'moonshine@untested', 'installed_version' => "#{item.release['version']}+#{item.identity}",
        'baseline_recipe_sha256' => R.current(root).identity,
        'provenance' => {'kind' => 'owner-run-native', 'owner' => 'evertonstz'},
        'host' => {'os_id' => 'bazzite', 'image' => 'bazzite-dx-nvidia-gnome', 'version' => '44',
                   'architecture' => 'x86_64', 'ostree_booted' => true, 'selinux' => 'Enforcing',
                   'systemd' => '259.9', 'kernel' => '7.2.7', 'gpu_driver' => 'nvidia',
                   'selinux_policy_sha256' => 'b' * 64},
        'checks' => policy['checks'].to_h { |name| [name, 'passed'] },
        'service_states' => policy['service_states'].to_h { |name| [name, 'passed'] },
        'observed_at' => '2026-01-01T12:00:00Z', 'log_sha256' => 'c' * 64,
        'os_policy_updates' => 'ongoing'
      }
      yield root, item, evidence
    end
  end

  def report(root, item, evidence, environment = {})
    env = {'RUBYOPT' => nil, 'RUBYLIB' => nil, 'GITHUB_TOKEN' => nil, 'GH_TOKEN' => nil,
           'GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_REPOSITORY' => 'evertonstz/homebrew-moonshine-tap',
           'GITHUB_REF' => 'refs/heads/main', 'GITHUB_ACTOR' => 'evertonstz', 'GITHUB_TRIGGERING_ACTOR' => 'evertonstz',
           'MOONSHINE_PROMOTION_TARGET' => item.identity, 'MOONSHINE_EXPECTED_STABLE' => R.current(root).identity,
           'MOONSHINE_NATIVE_EVIDENCE' => evidence.is_a?(String) ? evidence : JSON.generate(evidence)}.merge(environment)
    Open3.capture3(env, RbConfig.ruby, '--disable=rubyopt', (root/'tools/promotion_report.rb').to_s)
  end

  def test_policy_cannot_be_read_through_a_symlinked_reference_directory
    fixture do |root, item, evidence|
      saved = root.parent/'outside-reference'
      (root/'reference').rename(saved)
      (root/'reference').make_symlink(saved)
      output, error, status = report(root, item, evidence)
      assert_equal 1, status.exitstatus
      assert_empty output
      assert_includes error, 'Unsafe native policy directory'
    end
  end

  def refused(root, item, evidence, message, environment = {})
    before = MoonshineCandidate.tree(root)
    output, error, status = report(root, item, evidence, environment)
    assert_equal 1, status.exitstatus
    assert_empty output
    assert_includes error, message
    assert_equal before, MoonshineCandidate.tree(root)
  end

  def test_missing_or_different_recipe_rpm_policy_and_stable_identities_refuse
    fixture do |root, item, evidence|
      %w[recipe_sha256 policy_sha256 profile].each do |name|
        changed = Marshal.load(Marshal.dump(evidence))
        changed[name] = name == 'profile' ? 'other-profile' : 'f' * 64
        refused(root, item, changed, 'Native evidence')
      end
      %w[version sha256 filename].each do |name|
        changed = Marshal.load(Marshal.dump(evidence))
        changed['rpm'][name] = {'version' => '0.16.0', 'sha256' => 'f' * 64, 'filename' => 'moonshine-0.16.0-1.x86_64.rpm'}.fetch(name)
        refused(root, item, changed, 'Promotion refused before write credentials')
      end
      refused(root, item, evidence, 'Accepted recipe changed', 'MOONSHINE_EXPECTED_STABLE' => 'f' * 64)
      refused(root, item, evidence, 'retained', 'MOONSHINE_PROMOTION_TARGET' => 'f' * 64)
      refused(root, item, {}, 'Unexpected native evidence fields')
    end
  end

  def test_owner_report_claims_do_not_bypass_trusted_owner_dispatch_or_rerun_actor
    fixture do |root, item, evidence|
      {'GITHUB_ACTOR' => 'someone-else', 'GITHUB_TRIGGERING_ACTOR' => 'someone-else',
       'GITHUB_EVENT_NAME' => 'pull_request', 'GITHUB_REF' => 'refs/heads/feature',
       'GITHUB_REPOSITORY' => 'someone-else/homebrew-moonshine-tap'}.each do |name, value|
        refused(root, item, evidence, 'owner request on trusted main', name => value)
      end
      %w[kind owner].each do |name|
        changed = Marshal.load(Marshal.dump(evidence))
        changed['provenance'][name] = name == 'kind' ? 'package-ci' : 'someone-else'
        refused(root, item, changed, 'owner-run report')
      end
    end
  end

  def test_non_native_or_incompatible_host_reports_refuse
    fixture do |root, item, evidence|
      {'os_id' => 'bluefin', 'image' => 'bluefin', 'architecture' => 'aarch64', 'ostree_booted' => 'true',
       'selinux' => 'Permissive', 'systemd' => '256.9', 'kernel' => 'shell;code',
       'gpu_driver' => "nvidia\nsecret", 'selinux_policy_sha256' => 'not-a-digest'}.each do |name, value|
        changed = Marshal.load(Marshal.dump(evidence))
        changed['host'][name] = value
        refused(root, item, changed, 'Promotion refused before write credentials')
      end
      changed = Marshal.load(Marshal.dump(evidence))
      changed['host'].delete('image')
      refused(root, item, changed, 'Unexpected native host details')
    end
  end

  def test_each_required_native_observation_and_service_state_must_pass
    fixture do |root, item, evidence|
      %w[checks service_states].each do |group|
        evidence[group].keys.each do |name|
          changed = Marshal.load(Marshal.dump(evidence))
          changed[group][name] = 'failed'
          refused(root, item, changed, 'Required native observations did not pass')
        end
        %w[skipped pending].each do |result|
          changed = Marshal.load(Marshal.dump(evidence))
          changed[group][changed[group].keys.first] = result
          refused(root, item, changed, 'Required native observations did not pass')
        end
        changed = Marshal.load(Marshal.dump(evidence))
        changed[group].delete(changed[group].keys.first)
        refused(root, item, changed, 'missing or unexpected observations')
      end
    end
  end

  def test_report_transport_is_bounded_strict_and_data_only
    fixture do |root, item, evidence|
      refused(root, item, ' ' * (32 * 1024 + 1), 'safe input bounds')
      %w[schema host recipe_sha256].each do |name|
        json = JSON.generate(evidence)
        duplicate = json.sub('{', "{#{JSON.generate(name)}:null,")
        refused(root, item, duplicate, 'Duplicate native evidence field')
      end
      duplicated_host = JSON.generate(evidence).sub('"os_id":"bazzite"', '"os_id":"bluefin","os_id":"bazzite"')
      refused(root, item, duplicated_host, 'Duplicate native evidence field')
      changed = Marshal.load(Marshal.dump(evidence))
      changed['schema'] = 1.0
      refused(root, item, changed, 'policy identity differs')
      sentinel = root/'unexpected-execution'
      changed = Marshal.load(Marshal.dump(evidence))
      changed['run'] = "File.write(#{sentinel.to_s.inspect}, 'executed')"
      refused(root, item, changed, 'Unexpected native evidence fields')
      refute sentinel.exist?
      refused(root, item, ('[' * 11) + '0' + (']' * 11), 'nesting exceeds safe bounds')
      refused(root, item, 'null', 'Unexpected native evidence fields')
      output, error, status = report(root, item, '{"private-account":"private-value",broken}')
      assert_equal 1, status.exitstatus
      assert_empty output
      assert_includes error, 'Invalid native evidence JSON'
      refute_includes error, 'private-account'
      refute_includes error, 'private-value'
    end
  end

  def test_unknown_policy_or_weakened_required_checks_refuse
    fixture do |root, item, evidence|
      original = (root/'reference/native-policy.json').read
      %w[schema owner checks service_states].each do |name|
        policy = JSON.parse(original)
        policy[name] = {'schema' => 2.0, 'owner' => 'someone-else', 'checks' => ['install'], 'service_states' => ['enabled_running']}.fetch(name)
        (root/'reference/native-policy.json').write(JSON.generate(policy))
        refused(root, item, evidence, 'Unsupported native evidence policy')
      end
    end
  end

  def test_invalid_future_or_missing_observation_times_and_log_digests_refuse
    fixture do |root, item, evidence|
      ['2099-01-01T00:00:00Z', '2026-02-30T12:00:00Z', '2026-01-01', nil].each do |value|
        changed = Marshal.load(Marshal.dump(evidence))
        changed['observed_at'] = value
        refused(root, item, changed, 'Promotion refused before write credentials')
      end
      changed = Marshal.load(Marshal.dump(evidence))
      changed['log_sha256'] = 'not-a-digest'
      refused(root, item, changed, 'Invalid native log digest')
      changed = Marshal.load(Marshal.dump(evidence))
      changed['os_policy_updates'] = 'passed'
      refused(root, item, changed, 'normal-update observation')
    end
  end

  def test_report_binds_the_installed_hash_version_and_tested_accepted_baseline
    fixture do |root, item, evidence|
      {'installed_token' => 'moonshine', 'installed_version' => item.release['version'],
       'baseline_recipe_sha256' => 'f' * 64}.each do |name, value|
        changed = Marshal.load(Marshal.dump(evidence))
        changed[name] = value
        refused(root, item, changed, name == 'baseline_recipe_sha256' ? 'Native upgrade baseline differs' : 'Native installed cask differs')
      end
      changed = Marshal.load(Marshal.dump(evidence))
      changed['installed_version'] = "#{item.release['version']}+#{'f' * 64}"
      refused(root, item, changed, 'Native installed cask differs')
      %w[installed_token installed_version baseline_recipe_sha256].each do |name|
        changed = Marshal.load(Marshal.dump(evidence))
        changed.delete(name)
        refused(root, item, changed, 'Unexpected native evidence fields')
      end
    end
  end

  def test_report_names_the_exact_retained_target_after_untested_advances_and_refuses_expiry
    fixture do |root, item, evidence|
      2.times do |index|
        (root/'lib/moonshine_token_guard.rb').open('a') { |file| file.puts "# later reviewed recipe #{index}" }
        C.patch(root: root, release: item.release, source: (index.zero? ? 'b' : 'c') * 40,
                expected_current: C.catalog(root)['current']).each do |name, bytes|
          path = root/name
          path.dirname.mkpath
          bytes ? path.binwrite(bytes) : path.delete
        end
        root.glob('releases/candidates/*').select(&:directory?).each { |path| path.rmdir if path.children.empty? }
        if index.zero?
          before = MoonshineCandidate.tree(root)
          output, error, status = report(root, item, evidence)
          assert_equal 1, status.exitstatus
          assert_includes error, 'Protected promotion publisher is not implemented'
          assert_equal item.identity, JSON.parse(output)['recipe_sha256']
          refute_equal C.catalog(root)['current'], item.identity
          assert_equal before, MoonshineCandidate.tree(root)
        else
          refused(root, item, evidence, 'target expired')
        end
      end
    end
  end

  def test_missing_symlinked_or_oversized_policy_files_refuse
    fixture do |root, item, evidence|
      path = root/'reference/native-policy.json'
      original = path.binread
      path.delete
      refused(root, item, evidence, 'Missing or unsafe release input')
      saved = root/'reference/saved-policy.json'
      saved.binwrite(original)
      path.make_symlink(saved)
      output, error, status = report(root, item, evidence)
      assert_equal 1, status.exitstatus
      assert_empty output
      assert_includes error, 'Missing or unsafe release input'
      assert path.symlink?
      assert_equal original, saved.binread
      path.delete
      path.binwrite(' ' * 8193)
      refused(root, item, evidence, 'Missing or unsafe release input')
    end
  end

  def test_report_digest_is_canonical_but_binds_changed_host_and_log_claims
    fixture do |root, item, evidence|
      first, _, _ = report(root, item, evidence)
      reordered, _, _ = report(root, item, JSON.pretty_generate(evidence.to_a.reverse.to_h))
      assert_equal JSON.parse(first)['report_sha256'], JSON.parse(reordered)['report_sha256']
      %w[log_sha256 host].each do |name|
        changed = Marshal.load(Marshal.dump(evidence))
        name == 'host' ? changed['host']['gpu_driver'] = 'nvidia-580.1' : changed['log_sha256'] = 'd' * 64
        output, _, _ = report(root, item, changed)
        refute_equal JSON.parse(first)['report_sha256'], JSON.parse(output)['report_sha256']
      end
    end
  end

  def test_matching_report_never_creates_a_patch_or_rotates_either_channel
    fixture do |root, item, evidence|
      before = MoonshineCandidate.tree(root)
      error = assert_raises(R::Failure) do
        MoonshinePromotion.patch(root: root, target: item.identity, expected_stable: R.current(root).identity, evidence: evidence)
      end
      assert_includes error.message, 'Protected promotion publisher is not implemented'
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_matching_owner_report_is_checked_without_enabling_publication_or_changing_channels
    fixture do |root, item, evidence|
      before = MoonshineCandidate.tree(root)
      output, error, status = report(root, item, evidence)
      assert_equal 1, status.exitstatus
      assert_includes error, 'Protected promotion publisher is not implemented'
      data = JSON.parse(output)
      assert_equal 'matching_owner_report', data['status']
      assert_equal item.identity, data['recipe_sha256']
      assert_equal false, data['publication_enabled']
      assert_equal false, data['native_acceptance_verified']
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end
end

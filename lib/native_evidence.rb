# Data-only owner-report checks. Matching claims are not authenticated native observations.
require 'time'
require_relative 'release_candidate'

module MoonshineNativeEvidence
  extend self
  MAX_REPORT = 32 * 1024
  POLICY = <<~JSON.freeze
    {
      "schema": 2,
      "state": "configured",
      "profile": "bazzite-owner-v1",
      "owner": "evertonstz",
      "installation": {"token": "moonshine@untested", "version": "UPSTREAM_VERSION+RECIPE_SHA256", "baseline": "accepted_stable_recipe"},
      "host": {"os_id": "bazzite", "architecture": "x86_64", "ostree_booted": true, "selinux": "Enforcing", "minimum_systemd": 257},
      "checks": ["install", "start", "video", "audio", "keyboard_mouse", "upgrade", "uninstall", "recovery", "personal_data", "administrator_state", "unrelated_extensions", "groups", "lingering"],
      "service_states": ["enabled_running", "enabled_stopped", "disabled_running", "disabled_stopped"],
      "os_policy_updates": "observe_normal_updates"
    }
  JSON

  def parse(text, limit: MAX_REPORT)
    MoonshineReleases.check(text.is_a?(String) && text.valid_encoding? && text.bytesize <= limit, 'Native evidence exceeds safe input bounds')
    JSON.parse(text, max_nesting: 10, allow_duplicate_key: false, create_additions: false)
  rescue JSON::NestingError
    raise MoonshineReleases::Failure, 'Native evidence nesting exceeds safe bounds'
  rescue JSON::ParserError => error
    # Parser diagnostics can include untrusted report values. Return only a static category.
    message = error.message.start_with?('duplicate key') ? 'Duplicate native evidence field' : 'Invalid native evidence JSON'
    raise MoonshineReleases::Failure, message
  end

  def fields(value, names, message)
    MoonshineReleases.check(value.is_a?(Hash) && value.keys.sort == names.sort, message)
  end

  def digest(value, message)
    MoonshineReleases.check(value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/), message)
  end

  def policy(root)
    directory = Pathname(root)/'reference'
    MoonshineReleases.check(directory.directory? && !directory.symlink?, 'Unsafe native policy directory')
    text = MoonshineReleases.read_file(directory/'native-policy.json', 8192)
    value = parse(text, limit: 8192)
    if value.is_a?(Hash) && value.keys.sort == %w[reason schema state] &&
       value['schema'].is_a?(Integer) && value['schema'] == 1 && value['state'] == 'unconfigured'
      raise MoonshineReleases::Failure, 'Native evidence policy is not configured; stable promotion is disabled'
    end
    expected = JSON.parse(POLICY)
    MoonshineReleases.check(value == expected && value['schema'].is_a?(Integer) &&
                            value.dig('host', 'minimum_systemd').is_a?(Integer),
                            'Unsupported native evidence policy; owner policy review required')
    [value, Digest::SHA256.hexdigest(text)]
  end

  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def assess(root:, target:, expected_stable:, evidence:)
    selected, policy_sha = policy(root)
    report = parse(evidence.is_a?(String) ? evidence : JSON.generate(evidence, allow_duplicate_key: false, max_nesting: 10))
    fields(report, %w[schema profile policy_sha256 recipe_sha256 rpm installed_token installed_version baseline_recipe_sha256 provenance host checks service_states observed_at log_sha256 os_policy_updates],
           'Unexpected native evidence fields')
    MoonshineReleases.check(report['schema'].is_a?(Integer) && report['schema'] == 1 &&
                            report['profile'] == selected['profile'] && report['policy_sha256'] == policy_sha,
                            'Native evidence policy identity differs')
    MoonshineCask.generate(root: root, check: true)
    stable = MoonshineReleases.current(root)
    MoonshineReleases.check(stable.identity == expected_stable, 'Accepted recipe changed; fresh promotion review required')
    candidate = MoonshineCandidates.recipe(root, MoonshineCandidates.identity(target))
    MoonshineReleases.check(candidate && report['recipe_sha256'] == candidate.identity,
                            'Native evidence does not identify the exact retained candidate')
    MoonshineReleases.check(MoonshineReleases.metadata(report['rpm']) == candidate.release, 'Native evidence RPM identity differs')
    MoonshineReleases.check(report['installed_token'] == 'moonshine@untested' &&
                            report['installed_version'] == "#{candidate.release['version']}+#{candidate.identity}",
                            'Native installed cask differs from the exact candidate')
    MoonshineReleases.check(report['baseline_recipe_sha256'] == stable.identity, 'Native upgrade baseline differs from accepted stable')
    fields(report['provenance'], %w[kind owner], 'Unexpected native evidence provenance')
    MoonshineReleases.check(report['provenance'] == {'kind' => 'owner-run-native', 'owner' => selected['owner']},
                            'Native evidence requires an owner-run report')
    host = report['host']
    fields(host, %w[os_id image version architecture ostree_booted selinux systemd kernel gpu_driver selinux_policy_sha256],
           'Unexpected native host details')
    %w[os_id architecture ostree_booted selinux].each do |name|
      MoonshineReleases.check(host[name] == selected['host'][name], 'Native evidence host is outside the selected Bazzite profile')
    end
    MoonshineReleases.check(host['image'].is_a?(String) && host['image'].bytesize <= 128 &&
                            host['image'].match?(/\Abazzite(?:-[a-z0-9]+)*\z/), 'Invalid Bazzite image identity')
    %w[version kernel gpu_driver].each do |name|
      MoonshineReleases.check(host[name].is_a?(String) && host[name].match?(/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z/),
                              'Invalid native host version or driver detail')
    end
    MoonshineReleases.check(host['systemd'].is_a?(String) && host['systemd'].bytesize <= 32 &&
                            host['systemd'].match?(/\A[0-9]+(?:\.[0-9]+){0,2}\z/) &&
                            host['systemd'].split('.').first.to_i >= selected['host']['minimum_systemd'],
                            'Native evidence requires systemd 257 or newer')
    digest(host['selinux_policy_sha256'], 'Invalid native SELinux-policy digest')
    {'checks' => selected['checks'], 'service_states' => selected['service_states']}.each do |name, required|
      fields(report[name], required, 'Native evidence has missing or unexpected observations')
      MoonshineReleases.check(report[name].values.all? { |result| result == 'passed' }, 'Required native observations did not pass')
    end
    digest(report['log_sha256'], 'Invalid native log digest')
    observed = report['observed_at']
    MoonshineReleases.check(observed.is_a?(String) && observed.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/) &&
                            Time.iso8601(observed).utc.iso8601 == observed && Time.iso8601(observed) <= Time.now,
                            'Invalid or future native observation time')
    MoonshineReleases.check(report['os_policy_updates'] == 'ongoing', 'OS and policy updates remain normal-update observation, not forced acceptance')
    {'status' => 'matching_owner_report', 'profile' => selected['profile'], 'policy_sha256' => policy_sha,
     'recipe_sha256' => candidate.identity, 'rpm' => candidate.release,
     'installed_token' => report['installed_token'], 'installed_version' => report['installed_version'],
     'baseline_recipe_sha256' => stable.identity,
     'report_sha256' => Digest::SHA256.hexdigest(JSON.generate(canonical(report))),
     'publication_enabled' => false, 'native_acceptance_verified' => false, 'host_installation' => false}
  end
end

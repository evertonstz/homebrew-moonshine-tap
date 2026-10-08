require 'minitest/autorun'
require 'yaml'
require 'stringio'
require 'tmpdir'
require_relative '../lib/ci_validation'
require_relative '../lib/test_gate'
require_relative '../tools/check_casks'
require_relative '../tools/release_report'

class CIValidationTest < Minitest::Test
  ROOT = Pathname(__dir__).parent

  def test_aggregate_requires_exact_successful_prerequisites
    assert MoonshineCI.successful?('checks' => {'result' => 'success'})
    %w[failure skipped cancelled neutral pending queued].each do |result|
      refute MoonshineCI.successful?('checks' => {'result' => result})
    end
    [{}, nil, [], {'checks' => {}}, {'checks' => nil},
     {'other' => {'result' => 'success'}}, {'checks' => {'result' => 'success'}, 'other' => {'result' => 'success'}}].each do |needs|
      refute MoonshineCI.successful?(needs)
    end
  end

  def test_workflow_preserves_matrix_and_has_no_write_credentials
    workflow = YAML.safe_load((ROOT/'.github/workflows/ci.yml').read)
    assert_equal 'Moonshine CI', workflow['name']
    assert_equal({'contents' => 'read'}, workflow['permissions'])
    assert_equal %w[push pull_request workflow_dispatch], workflow['on'].keys
    jobs = workflow.fetch('jobs')
    checks = jobs.fetch('checks')
    assert_equal %w[ubuntu-24.04 macos-15], checks.dig('strategy', 'matrix', 'os')
    assert_equal false, checks.dig('strategy', 'fail-fast')
    assert_equal 10, checks['timeout-minutes']
    uses = jobs.values.flat_map { |job| job['steps'] }.select { |step| step['uses'] }
    uses.each { |step| assert_match(/\A[^@]+@[0-9a-f]{40}\z/, step['uses']) }
    uses.select { |step| step['uses'].start_with?('actions/checkout@') }.each do |step|
      assert_equal false, step.dig('with', 'persist-credentials')
    end
    setup = uses.find { |step| step['uses'].start_with?('Homebrew/actions/setup-homebrew@') }
    assert_equal 'Homebrew/actions/setup-homebrew@1e34f2e2acaa766b7efacb8c26352e6abbb023f9', setup['uses']
    assert_equal '', setup.dig('with', 'token')
    assert_equal true, setup.dig('with', 'stable')
    assert_equal false, setup.dig('with', 'debug')
    text = (ROOT/'.github/workflows/ci.yml').read
    refute_includes text, 'secrets.'
    refute_includes text, 'pull_request_target'
    refute_includes text, 'create-github-app-token'
    assert_includes text, 'tools/check_casks.rb'
    assert_includes text, 'tools/check_releases.rb'
    assert_includes text, '--test-rpm-copy'
    assert_includes text, 'tools/run_tests.rb --no-skips'
    assert_includes text, 'automation/moonshine-release'
    aggregate = jobs.fetch('required')
    assert_equal MoonshineCI::REQUIRED_CHECK, aggregate['name']
    assert_equal MoonshineCI::JOBS, aggregate['needs']
    assert_equal '${{ always() }}', aggregate['if']
    assert_includes aggregate.fetch('steps').last.fetch('run'), 'MoonshineCI.successful?'
  end

  def test_rpm_path_is_initialized_on_runner_not_in_job_environment
    checks = YAML.safe_load((ROOT/'.github/workflows/ci.yml').read).fetch('jobs').fetch('checks')
    checks.fetch('env').each_value do |value|
      refute_match(/\$\{\{[^}]*\brunner\./, value.to_s, 'The runner context is unavailable in job-level env')
    end
    refute checks.fetch('env').key?('MOONSHINE_TEST_RPM')
    step = checks.fetch('steps').find { |item| item['name'] == 'Select the explicit extraction tool' }
    runner_os = RUBY_PLATFORM.include?('darwin') ? 'macOS' : 'Linux'
    tool = runner_os == 'macOS' ? '/usr/bin/tar' : '/usr/bin/bsdtar'
    Dir.mktmpdir do |directory|
      temporary = Pathname(directory)/'runner temp'
      output = Pathname(directory)/'job-env'
      env = {'RUNNER_OS' => runner_os, 'RUNNER_TEMP' => temporary.to_s, 'GITHUB_ENV' => output.to_s}
      stdout, stderr, status = Open3.capture3(env, 'bash', '-euo', 'pipefail', '-c', step.fetch('run'))
      assert status.success?, stdout + stderr
      assert_equal "MOONSHINE_TEST_BSDTAR=#{tool}\nMOONSHINE_TEST_RPM=#{temporary}/moonshine.rpm\n", output.read
    end
  end

  def test_daily_workflow_is_read_only_serialized_and_activation_gated
    workflow = YAML.safe_load((ROOT/'.github/workflows/release-update.yml').read)
    assert_equal({'contents' => 'read'}, workflow['permissions'])
    assert_equal '23 4 * * *', workflow.dig('on', 'schedule', 0, 'cron')
    assert workflow['on'].key?('workflow_dispatch')
    assert_equal false, workflow.dig('concurrency', 'cancel-in-progress')
    assert_equal 'moonshine-release-update', workflow.dig('concurrency', 'group')
    job = workflow.dig('jobs', 'detect')
    assert_includes job['if'], "vars.MOONSHINE_RELEASE_UPDATES_ENABLED == 'true'"
    assert_includes job['if'], "github.event_name == 'workflow_dispatch'"
    assert_includes job['if'], "github.event_name == 'schedule' && vars.MOONSHINE_RELEASE_SCHEDULE_ENABLED == 'true'"
    assert_includes job['if'], "github.event.workflow_run.event == 'push'"
    assert_includes job['if'], "github.event.workflow_run.head_repository.full_name == github.repository"
    assert_includes job['if'], "github.ref == 'refs/heads/main'"
    assert_includes job['if'], "github.repository == 'evertonstz/homebrew-moonshine-tap'"
    job['steps'].select { |step| step['uses'] }.each do |step|
      assert_match(/\A[^@]+@[0-9a-f]{40}\z/, step['uses'])
    end
    checkout = job['steps'].first
    assert_equal "${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || github.sha }}", checkout.dig('with', 'ref')
    assert_equal false, checkout.dig('with', 'persist-credentials')
    text = YAML.dump(job)
    refute_includes text, 'secrets.'
    refute_includes text, 'create-github-app-token'
    refute_includes text, 'upload-artifact'
    assert_includes text, 'tools/update_release.rb --bsdtar /usr/bin/bsdtar --prepare'
    assert_includes text, 'tools/release_report.rb'
  end

  def test_release_outputs_bind_base_and_pins_without_exporting_artifact_paths
    current = MoonshineReleases.metadata(MoonshineHost::RELEASE)
    release = MoonshineReleases.metadata('version' => '0.16.2', 'sha256' => 'b' * 64, 'filename' => 'moonshine-0.16.2-1.x86_64.rpm')
    report = {'status' => 'eligible', 'current' => current, 'release' => release, 'asset_id' => 123,
              'candidate' => {'directory' => '/untrusted/path', 'commands' => 'never execute'}}
    fields = MoonshineReleaseReport.fields(report, 'a' * 40, current)
    assert_equal %w[status base_sha release asset_id], fields.keys
    assert_equal release, JSON.parse(fields['release'])
    refute_includes JSON.generate(fields), '/untrusted/path'
    assert_raises(MoonshineReleases::Failure) { MoonshineReleaseReport.fields(report, 'bad commit', current) }
    %w[review_required skipped unknown].each do |status|
      assert_raises(MoonshineReleases::Failure) { MoonshineReleaseReport.fields(report.merge('status' => status), 'a' * 40, current) }
    end
    [nil, 0, '123', 2**80].each do |asset|
      assert_raises(MoonshineReleases::Failure) { MoonshineReleaseReport.fields(report.merge('asset_id' => asset), 'a' * 40, current) }
    end
    assert_raises(MoonshineReleases::Failure) { MoonshineReleaseReport.fields(report.merge('release' => current), 'a' * 40, current) }
    assert_raises(MoonshineReleases::Failure) { MoonshineReleaseReport.fields(report.merge('current' => release), 'a' * 40, current) }
    %w[unchanged awaiting_asset].each do |status|
      assert_equal({'status' => status, 'base_sha' => 'a' * 40}, MoonshineReleaseReport.fields(report.merge('status' => status), 'a' * 40, current))
    end
  end

  def reporter(required: ['Fixture#test_required'])
    subject = MoonshineTestGate::Reporter.new(StringIO.new, required_tests: required)
    subject.start
    subject
  end

  def result(name = 'test_required', failure = nil)
    value = Minitest::Result.new(name)
    value.klass = 'Fixture'
    value.assertions = 1
    value.failures << failure if failure
    value
  end

  def test_reporter_rejects_zero_tests_skips_failures_and_missing_required_test
    subject = reporter
    refute subject.passed?
    subject.record(result)
    subject.report
    assert subject.passed?
    subject = reporter
    subject.record(result('test_required', Minitest::Skip.new('fixture skip')))
    subject.report
    refute subject.passed?
    subject = reporter
    subject.record(result('test_required', Minitest::Assertion.new('fixture failure')))
    subject.report
    refute subject.passed?
    subject = reporter
    subject.record(result('test_other'))
    subject.report
    refute subject.passed?
  end

  def test_no_skip_plugin_sets_the_process_exit_status
    [false, true].each do |skip|
      script = <<~RUBY
        require 'minitest/autorun'
        require #{(ROOT/'lib/test_gate.rb').to_s.inspect}
        MoonshineTestGate.install!
        class HostTest < Minitest::Test
          def test_official_artifact_extraction
            #{skip ? "skip 'fixture'" : 'assert true'}
          end
        end
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, '-e', script)
      assert_equal !skip, status.success?, output + error
      assert_includes output, 'Required test gate failed' if skip
    end
  end
end

class CaskLoadingCheckTest < Minitest::Test
  ROOT = Pathname(__dir__).parent
  Status = Struct.new(:success?)

  def fixture(previous: false)
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      %w[lib/moonshine_host.rb reference/postinstall.sh reference/postremove.sh].each do |name|
        (root/name).dirname.mkpath
        FileUtils.cp(name.start_with?("reference/") ? ROOT/"tests/fixtures/#{File.basename(name)}" : ROOT/name, root/name)
      end
      if previous
        latest = MoonshineReleases.current(root)
        release = {'version' => '0.16.0', 'sha256' => 'b' * 64, 'filename' => 'moonshine-0.16.0-1.x86_64.rpm'}
        source = latest.source.sub(/^  RELEASE = [^\n]+\.freeze$/, "  RELEASE = #{release.inspect}.freeze")
        MoonshineReleases.save_previous(root, MoonshineReleases::Recipe.new(release: release, source: source, scripts: latest.scripts))
      end
      brew = root/'brew'
      brew.write('# fixture executable')
      brew.chmod(0700)
      yield root, brew.to_s
    end
  end

  def runner(calls, bad: nil)
    ->(args) do
      calls << args
      if args[1] == 'readall'
        ['', '', Status.new(bad != :readall)]
      else
        name = args.last
        release = if name.end_with?('moonshine@0.16.0')
          {'version' => '0.16.0', 'sha256' => 'b' * 64, 'filename' => 'moonshine-0.16.0-1.x86_64.rpm'}
        else
          MoonshineHost::RELEASE
        end
        data = {'token' => name.split('/').last, 'full_token' => name, 'version' => release['version'],
                'sha256' => bad == :pin ? '0' * 64 : release['sha256'], 'url' => MoonshineUpdate.download_url(release)}
        data['full_token'] = 'other/tap/moonshine' if bad == :identity
        [JSON.generate('casks' => bad == :empty ? [] : [data]), '', Status.new(bad != :info)]
      end
    end
  end

  def test_public_commands_load_all_tokens_without_installation
    fixture do |root, brew|
      calls = []
      report = MoonshineCaskCheck.run(root: root, brew: brew, tap: MoonshineTokenGuard::TAP, runner: runner(calls), euid: 1000)
      assert_equal [brew, 'readall', '--aliases', '--os=all', '--arch=all', MoonshineTokenGuard::TAP], calls.first
      assert_equal %w[readall info info], calls.map { |args| args[1] }
      assert_equal %w[moonshine moonshine@0.16.1], report['tokens_loaded']
      assert_equal false, report['host_installation']
    end
  end

  def test_three_tokens_load_their_independent_recipe_pins
    fixture(previous: true) do |root, brew|
      calls = []
      report = MoonshineCaskCheck.run(root: root, brew: brew, tap: MoonshineTokenGuard::TAP, runner: runner(calls), euid: 1000)
      assert_equal %w[readall info info info], calls.map { |args| args[1] }
      assert_equal %w[moonshine moonshine@0.16.1 moonshine@0.16.0], report['tokens_loaded']
      assert_equal '0.16.1', MoonshineHost::RELEASE['version']
    end
  end

  def test_failed_loading_empty_results_and_wrong_pins_fail_closed
    fixture do |root, brew|
      %i[readall info pin identity empty].each do |bad|
        calls = []
        assert_raises(MoonshineUpdate::Failure) do
          MoonshineCaskCheck.run(root: root, brew: brew, tap: MoonshineTokenGuard::TAP, runner: runner(calls, bad: bad), euid: 1000)
        end
        assert_equal 1, calls.length if bad == :readall
      end
    end
  end

  def test_root_and_wrong_tap_refuse_before_brew_runs
    fixture do |root, brew|
      calls = []
      assert_raises(MoonshineUpdate::Failure) do
        MoonshineCaskCheck.run(root: root, brew: brew, tap: MoonshineTokenGuard::TAP, runner: runner(calls), euid: 0)
      end
      assert_raises(MoonshineUpdate::Failure) do
        MoonshineCaskCheck.run(root: root, brew: brew, tap: 'foreign/tap', runner: runner(calls), euid: 1000)
      end
      assert_empty calls
    end
  end
end

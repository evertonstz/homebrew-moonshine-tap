require 'minitest/autorun'
require 'yaml'
require_relative '../lib/github_release'

class GitHubReleaseTest < Minitest::Test
  ROOT = Pathname(__dir__).parent
  BASE = 'a' * 40
  HEAD = 'b' * 40
  TREE = 'c' * 40
  BOT = {'login' => 'moonshine-updates[bot]', 'id' => 12, 'type' => 'Bot'}.freeze
  RELEASE = {'version' => '0.16.2', 'sha256' => 'd' * 64, 'filename' => 'moonshine-0.16.2-1.x86_64.rpm'}.freeze

  class FakeAPI
    attr_reader :writes, :reads
    attr_accessor :base, :branch, :pulls, :head_files, :parents, :commit_message, :owner, :scope, :settings, :fail_write,
                  :protection, :run, :jobs, :latest, :before_merge, :extra_directory
    def initialize(files, after, data)
      @files, @head_files, @data = files, after, data
      @base, @branch, @parents, @commit_message = BASE, nil, [BASE], MoonshineGitHub.message(data)
      @owner = BOT.dup
      @pulls, @writes, @reads = [], [], []
      @scope = {'total_count' => 1, 'repositories' => [{'full_name' => MoonshineGitHub::REPOSITORY}]}
      @settings = {'full_name' => MoonshineGitHub::REPOSITORY, 'default_branch' => 'main', 'allow_squash_merge' => true,
                   'allow_auto_merge' => true, 'delete_branch_on_merge' => true, 'archived' => false, 'disabled' => false}
      @protection = {'required_status_checks' => {'strict' => true, 'contexts' => [MoonshineCI::REQUIRED_CHECK],
        'checks' => [{'context' => MoonshineCI::REQUIRED_CHECK, 'app_id' => 15368}]},
        'enforce_admins' => {'enabled' => true}, 'allow_force_pushes' => {'enabled' => false},
        'allow_deletions' => {'enabled' => false}, 'required_pull_request_reviews' => {'bypass_pull_request_allowances' => {'users' => [], 'teams' => [], 'apps' => []}}}
      @run = {'id' => 101, 'run_attempt' => 1, 'event' => 'pull_request', 'status' => 'completed', 'conclusion' => 'success',
        'path' => '.github/workflows/ci.yml', 'head_sha' => HEAD, 'head_branch' => MoonshineGitHub::BRANCH,
        'repository' => {'full_name' => MoonshineGitHub::REPOSITORY}, 'head_repository' => {'full_name' => MoonshineGitHub::REPOSITORY},
        'pull_requests' => [{'number' => 7}]}
      @latest = {'total_count' => 1, 'workflow_runs' => [@run.dup]}
      @jobs = {'total_count' => 3, 'jobs' => MoonshineGitHub::JOB_NAMES.map do |name|
        steps = name == MoonshineCI::REQUIRED_CHECK ? ['Require all prerequisite jobs to succeed'] :
          ['Check source and all generated casks', 'Load every offered token with Homebrew',
           'Inspect and extract every retained official RPM', 'Run all regressions with mandatory official RPM extraction']
        {'name' => name, 'status' => 'completed', 'conclusion' => 'success',
         'steps' => steps.map { |step| {'name' => step, 'status' => 'completed', 'conclusion' => 'success'} }}
      end}
    end

    def pr(head = HEAD)
      {'number' => 7, 'state' => 'open', 'draft' => false, 'merged' => false, 'commits' => 1, 'user' => @owner.dup,
       'head' => {'ref' => MoonshineGitHub::BRANCH, 'sha' => head, 'repo' => {'full_name' => MoonshineGitHub::REPOSITORY}},
       'base' => {'ref' => 'main', 'sha' => BASE, 'repo' => {'full_name' => MoonshineGitHub::REPOSITORY}}}
    end

    def call(method, path, data = nil, missing: false)
      suffix = path.delete_prefix("/repos/#{MoonshineGitHub::REPOSITORY}")
      if method == 'GET'
        @reads << suffix
        case suffix
        when '/installation/repositories?per_page=100' then @scope
        when '' then @settings
        when '/git/ref/heads/main' then {'object' => {'sha' => @base}}
        when "/git/ref/heads/#{MoonshineGitHub::BRANCH}" then @branch && {'object' => {'sha' => @branch}}
        when "/git/commits/#{BASE}" then {'tree' => {'sha' => TREE}}
        when "/git/commits/#{HEAD}" then {'tree' => {'sha' => 'e' * 40}, 'parents' => @parents.map { |sha| {'sha' => sha} }, 'message' => @commit_message}
        when "/git/trees/#{TREE}?recursive=1" then tree(@files)
        when "/git/trees/#{'e' * 40}?recursive=1" then tree(@head_files)
        when "/commits/#{HEAD}" then {'author' => @owner, 'committer' => @owner}
        when '/pulls/7' then @pulls.first
        when '/branches/main/protection' then @protection
        when '/actions/runs/101' then @run
        when '/actions/runs/101/attempts/1/jobs?per_page=100' then @jobs
        else
          return @pulls if suffix.start_with?('/pulls?')
          return @latest if suffix.start_with?('/actions/workflows/ci.yml/runs?')
          raise "Unexpected fixture GET: #{suffix}"
        end
      else
        @writes << [method, suffix, data]
        raise MoonshineGitHub::Failure, 'Injected GitHub refusal' if @fail_write == suffix
        case suffix
        when '/git/trees' then {'sha' => 'e' * 40}
        when '/git/commits' then {'sha' => HEAD}
        when '/git/refs' then @branch = data['sha']; {'object' => {'sha' => @branch}}
        when '/pulls' then @pulls = [pr]; @pulls.first
        when '/pulls/7/merge'
          @before_merge&.call(self)
          raise MoonshineGitHub::Failure, 'Head moved at the server' unless data['sha'] == @branch
          raise MoonshineGitHub::Failure, 'Strict current-base protection refused' unless @base == BASE
          {'merged' => true, 'sha' => 'f' * 40}
        else raise "Unexpected fixture write: #{suffix}"
        end
      end
    end

    def tree(files)
      directories = files.keys.flat_map do |path|
        parts = path.split('/')[0...-1]
        (1..parts.length).map { |length| parts.first(length).join('/') }
      end.uniq
      directories << @extra_directory if @extra_directory && files.equal?(@head_files)
      entries = files.map { |path, metadata| {'path' => path, 'type' => 'blob'}.merge(metadata) }
      entries += directories.map { |path| {'path' => path, 'mode' => '040000', 'type' => 'tree', 'sha' => 'f' * 40} }
      {'truncated' => false, 'tree' => entries}
    end
  end

  def fixture
    before = MoonshineCandidate.tree(ROOT).transform_values { |bytes| {'sha' => MoonshineGitHub.blob(bytes), 'mode' => '100644'} }
    after = before.transform_values(&:dup)
    MoonshineCandidate.patch(ROOT, RELEASE).each do |name, bytes|
      bytes ? after[name] = {'sha' => MoonshineGitHub.blob(bytes), 'mode' => '100644'} : after.delete(name)
    end
    data = MoonshineGitHub.manifest(BASE, RELEASE, 123)
    api = FakeAPI.new(before, after, data)
    [api, MoonshineGitHub::Controller.new(api: api, root: ROOT, bot_slug: 'moonshine-updates', bot_id: 12, check_app_id: 15368)]
  end

  def publish(controller)
    controller.publish(base: BASE, release: RELEASE, asset: 123)
  end

  def test_publication_creates_one_commit_one_branch_one_pr_and_repeated_runs_do_no_writes
    api, controller = fixture
    baseline = MoonshineCandidate.tree(ROOT)
    assert_equal({'status' => 'created', 'number' => 7, 'head_sha' => HEAD}, publish(controller))
    assert_equal %w[/git/trees /git/commits /git/refs /pulls], api.writes.map { |_, path, _| path }
    assert_equal [BASE], api.writes[1].last['parents']
    assert_equal "refs/heads/#{MoonshineGitHub::BRANCH}", api.writes[2].last['ref']
    assert_includes api.writes.last.last['body'], MoonshineHost::RELEASE['sha256']
    assert_includes api.writes.last.last['body'], RELEASE['sha256']
    assert_includes api.writes.last.last['body'], 'No new host installation'
    writes = api.writes.dup
    assert_equal 'reused', publish(controller)['status']
    assert_equal writes, api.writes
    assert_equal baseline, MoonshineCandidate.tree(ROOT)
  end

  def test_unexpected_branch_patch_parents_message_or_author_is_never_overwritten
    [:patch, :parents, :message, :owner].each do |failure|
      api, controller = fixture
      api.branch = HEAD
      case failure
      when :patch then api.head_files['README.md'] = {'sha' => 'f' * 40, 'mode' => '100644'}
      when :parents then api.parents = [BASE, 'f' * 40]
      when :message then api.commit_message += 'unexpected'
      when :owner then api.owner = BOT.merge('id' => 999)
      end
      assert_raises(MoonshineGitHub::Failure) { publish(controller) }
      assert_empty api.writes
      assert_equal HEAD, api.branch
    end
  end

  def test_wrong_scope_base_settings_and_duplicate_prs_refuse_without_writes
    [:scope, :base, :settings, :duplicates].each do |failure|
      api, controller = fixture
      case failure
      when :scope then api.scope['total_count'] = 2
      when :base then api.base = 'f' * 40
      when :settings then api.settings['allow_squash_merge'] = false
      when :duplicates then api.pulls = [api.pr, api.pr]
      end
      assert_raises(MoonshineGitHub::Failure) { publish(controller) }
      assert_empty api.writes
    end
  end

  def test_closed_pr_and_unexpected_open_pr_are_not_reopened_or_replaced
    api, controller = fixture
    api.branch = HEAD
    api.pulls = [api.pr.merge('state' => 'closed')]
    assert_raises(MoonshineGitHub::Failure) { publish(controller) }
    assert_empty api.writes
    api.pulls = [api.pr.merge('user' => BOT.merge('login' => 'human'))]
    assert_raises(MoonshineGitHub::Failure) { publish(controller) }
    assert_empty api.writes
  end

  def test_partial_github_write_failure_leaves_accepted_sources_unchanged_and_can_resume
    baseline = MoonshineCandidate.tree(ROOT)
    %w[/git/trees /git/commits /git/refs /pulls].each do |path|
      api, controller = fixture
      api.fail_write = path
      assert_raises(MoonshineGitHub::Failure) { publish(controller) }
      assert_equal baseline, MoonshineCandidate.tree(ROOT)
      assert_nil api.branch unless path == '/pulls'
      assert_empty api.pulls
      api.fail_write = nil
      assert_equal 'created', publish(controller)['status']
      assert_equal 1, api.pulls.length
    end
  end

  def merge_fixture
    api, controller = fixture
    api.branch = HEAD
    api.pulls = [api.pr]
    [api, controller]
  end

  def test_merge_requires_actual_jobs_and_steps_then_requests_protected_squash_for_exact_head
    api, controller = merge_fixture
    assert_equal({'status' => 'merged', 'number' => 7, 'head_sha' => HEAD, 'merge_sha' => 'f' * 40}, controller.merge(base: BASE, run_id: 101))
    assert_equal [['PUT', '/pulls/7/merge', {'sha' => HEAD, 'merge_method' => 'squash'}]], api.writes
    assert_operator api.reads.count('/branches/main/protection'), :>=, 2
  end

  def test_skipped_failed_missing_cancelled_pending_and_neutral_ci_cannot_merge
    %w[skipped failure cancelled queued neutral].each do |outcome|
      api, controller = merge_fixture
      api.jobs['jobs'].first['conclusion'] = outcome
      assert_raises(MoonshineGitHub::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_empty api.writes
      api.jobs['jobs'].first['conclusion'] = 'success'
      api.jobs['jobs'].first['steps'].first['conclusion'] = outcome
      assert_raises(MoonshineGitHub::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_empty api.writes
    end
    api, controller = merge_fixture
    api.jobs['jobs'].pop
    assert_raises(MoonshineGitHub::Failure) { controller.merge(base: BASE, run_id: 101) }
    assert_empty api.writes
  end

  def test_changed_head_base_branch_author_patch_ci_origin_and_superseded_run_refuse
    [:base, :head, :branch, :author, :patch, :workflow, :repo, :association, :latest].each do |failure|
      api, controller = merge_fixture
      case failure
      when :base then api.base = 'f' * 40
      when :head then api.pulls.first['head']['sha'] = 'f' * 40
      when :branch then api.pulls.first['head']['ref'] = 'foreign'
      when :author then api.pulls.first['user']['id'] = 999
      when :patch then api.head_files['tools/generate_cask.rb']['mode'] = '100755'
      when :workflow then api.run['path'] = '.github/workflows/foreign.yml'
      when :repo then api.run['head_repository']['full_name'] = 'foreign/repository'
      when :association then api.run['pull_requests'] = []
      when :latest then api.latest['workflow_runs'].first['run_attempt'] = 2
      end
      assert_raises(MoonshineGitHub::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_empty api.writes
    end
  end

  def test_unexpected_empty_git_directory_is_not_an_exact_release_patch
    api, controller = merge_fixture
    api.extra_directory = 'unexpected-empty-directory'
    assert_raises(MoonshineGitHub::Failure) { controller.merge(base: BASE, run_id: 101) }
    assert_empty api.writes
  end

  def test_missing_unknown_unscoped_or_bypass_protection_cannot_merge
    [:strict, :unknown, :app, :reviews, :bypass, :missing_bypass, :admins, :force, :scope].each do |failure|
      api, controller = merge_fixture
      case failure
      when :strict then api.protection['required_status_checks']['strict'] = false
      when :unknown then api.protection['required_status_checks']['contexts'] << 'unknown'
      when :app then api.protection['required_status_checks']['checks'].first['app_id'] = -1
      when :reviews then api.protection.delete('required_pull_request_reviews')
      when :bypass then api.protection['required_pull_request_reviews']['bypass_pull_request_allowances'] = {'apps' => [BOT]}
      when :missing_bypass then api.protection['required_pull_request_reviews'].delete('bypass_pull_request_allowances')
      when :admins then api.protection['enforce_admins']['enabled'] = false
      when :force then api.protection['allow_force_pushes']['enabled'] = true
      when :scope then api.scope['repositories'] << {'full_name' => 'another/repo'}
      end
      assert_raises(MoonshineGitHub::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_empty api.writes
    end
  end

  def test_server_side_head_and_strict_base_protection_close_the_last_request_race
    [:head, :base].each do |change|
      api, controller = merge_fixture
      api.before_merge = ->(state) { change == :head ? state.branch = 'f' * 40 : state.base = 'f' * 40 }
      baseline = MoonshineCandidate.tree(ROOT)
      assert_raises(MoonshineGitHub::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_equal HEAD, api.writes.last.last['sha']
      assert_equal baseline, MoonshineCandidate.tree(ROOT)
    end
  end

  def test_commit_manifest_is_canonical_bounded_checked_data
    data = MoonshineGitHub.manifest(BASE, RELEASE, 123)
    assert_equal data, MoonshineGitHub.parse_message(MoonshineGitHub.message(data))
    ["#{MoonshineGitHub.message(data)}extra", 'arbitrary code', 'a' * 3000].each do |text|
      assert_raises(StandardError) { MoonshineGitHub.parse_message(text) }
    end
    assert_raises(StandardError) { MoonshineGitHub.manifest('bad', RELEASE, 123) }
    assert_raises(StandardError) { MoonshineGitHub.manifest(BASE, RELEASE, 0) }
    assert_raises(StandardError) { MoonshineGitHub.manifest(BASE, RELEASE.merge('version' => ';system(1)'), 123) }
  end

  def test_write_workflows_are_pinned_scoped_and_never_check_out_or_execute_pr_artifacts
    update = YAML.safe_load((ROOT/'.github/workflows/release-update.yml').read)
    merge = YAML.safe_load((ROOT/'.github/workflows/release-merge.yml').read)
    assert_equal ['Moonshine CI'], merge.dig('on', 'workflow_run', 'workflows')
    assert_equal %w[completed], merge.dig('on', 'workflow_run', 'types')
    assert_equal update['concurrency'], merge['concurrency']
    [update.dig('jobs', 'publish'), merge.dig('jobs', 'merge')].each_with_index do |job, index|
      assert_includes job['if'], "vars.MOONSHINE_RELEASE_UPDATES_ENABLED == 'true'"
      assert_includes job['if'], "github.repository == 'evertonstz/homebrew-moonshine-tap'"
      steps = job.fetch('steps')
      steps.select { |step| step['uses'] }.each { |step| assert_match(/@[0-9a-f]{40}\z/, step['uses']) }
      assert_equal false, steps.first.dig('with', 'persist-credentials')
      assert_equal index.zero? ? '${{ needs.detect.outputs.base_sha }}' : 'main', steps.first.dig('with', 'ref')
      mint = steps.find { |step| step.fetch('uses', '').start_with?('actions/create-github-app-token@') }
      assert_equal 'evertonstz', mint.dig('with', 'owner')
      assert_equal 'homebrew-moonshine-tap', mint.dig('with', 'repositories')
      permissions = mint['with'].select { |key, _| key.start_with?('permission-') }
      expected = {'permission-contents' => 'write', 'permission-pull-requests' => 'write'}
      expected.merge!('permission-actions' => 'read', 'permission-administration' => 'read') unless index.zero?
      assert_equal expected, permissions
      refute_equal true, mint.dig('with', 'skip-token-revoke')
      assert_equal '${{ secrets.MOONSHINE_APP_PRIVATE_KEY }}', mint.dig('with', 'private-key')
      assert_equal "ruby --disable=rubyopt tools/github_release.rb #{index.zero? ? 'publish' : 'merge'}", steps.last['run']
      assert_equal '${{ steps.app.outputs.token }}', steps.last.dig('env', 'MOONSHINE_APP_TOKEN')
      steps[0...-1].each { |step| refute step.fetch('env', {}).key?('MOONSHINE_APP_TOKEN') }
      text = YAML.dump(job)
      %w[download-artifact check_releases.rb check_casks.rb update_release.rb pull_request_target --admin].each { |word| refute_includes text, word }
      refute_includes steps.last['run'], '${{'
    end
    assert_includes update.dig('jobs', 'publish', 'if'), "needs.detect.outputs.status == 'eligible'"
    assert_includes merge.dig('jobs', 'merge', 'if'), "github.event.workflow_run.head_repository.full_name == 'evertonstz/homebrew-moonshine-tap'"
  end

  def test_helper_description_subprocess_does_not_receive_github_credentials
    Dir.mktmpdir do |directory|
      helper = Pathname(directory)/'helper.rb'
      helper.write((ROOT/'lib/moonshine_host.rb').read + "\nraise 'Credential reached helper' if ENV['GITHUB_TOKEN'] || ENV['MOONSHINE_APP_TOKEN']\n")
      script = "require #{(ROOT/'lib/release_catalog.rb').to_s.inspect}; puts MoonshineReleases.load_recipe(#{helper.to_s.inspect}, #{(ROOT/'reference').to_s.inspect}).release.fetch('version')"
      output, error, status = Open3.capture3({'GITHUB_TOKEN' => 'fixture-read-secret', 'MOONSHINE_APP_TOKEN' => 'fixture-write-secret'}, RbConfig.ruby, '-e', script)
      assert status.success?, error
      assert_equal MoonshineHost::RELEASE['version'], output.strip
      refute_includes output + error, 'fixture-write-secret'
    end
  end

  def test_cli_refuses_inactive_or_wrong_repository_and_hides_missing_credentials
    secret = 'fixture-secret-' + 'x' * 30
    env = {'MOONSHINE_APP_TOKEN' => secret, 'MOONSHINE_RELEASE_UPDATES_ENABLED' => 'false',
           'GITHUB_REPOSITORY' => MoonshineGitHub::REPOSITORY}
    output, error, status = Open3.capture3(env, RbConfig.ruby, (ROOT/'tools/github_release.rb').to_s, 'publish')
    refute status.success?
    refute_includes output + error, secret
    assert_includes error, 'not activated'
    env['MOONSHINE_RELEASE_UPDATES_ENABLED'] = 'true'
    env['GITHUB_REPOSITORY'] = 'foreign/repository'
    output, error, status = Open3.capture3(env, RbConfig.ruby, (ROOT/'tools/github_release.rb').to_s, 'merge')
    refute status.success?
    refute_includes output + error, secret
  end

  def test_api_writes_cannot_modify_main_or_follow_redirects_or_expose_response_credentials
    secret = 'fixture-secret-' + 'x' * 30
    calls = []
    transport = ->(method, path, data, token) { calls << [method, path, data, token]; [302, secret] }
    api = MoonshineGitHub::API.new(token: secret, transport: transport)
    refute_includes api.inspect, secret
    assert_raises(MoonshineGitHub::Failure) { api.call('POST', "/repos/#{MoonshineGitHub::REPOSITORY}/git/refs", {'ref' => 'refs/heads/main', 'sha' => HEAD}) }
    assert_raises(MoonshineGitHub::Failure) { api.call('PATCH', "/repos/#{MoonshineGitHub::REPOSITORY}/git/refs/heads/#{MoonshineGitHub::BRANCH}", {}) }
    assert_empty calls
    error = assert_raises(MoonshineGitHub::Failure) { api.call('GET', "/repos/#{MoonshineGitHub::REPOSITORY}") }
    refute_includes error.message, secret
    assert_equal 1, calls.length
    assert_raises(MoonshineGitHub::Failure) { MoonshineGitHub::API.new(token: '') }
  end
end

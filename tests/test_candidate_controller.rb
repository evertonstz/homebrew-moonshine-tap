require_relative 'test_github_release'
require_relative '../lib/promotion'

class CandidateControllerTest < Minitest::Test
  G = MoonshineGitHub
  R = MoonshineReleases
  C = MoonshineCandidates
  ROOT = Pathname(__dir__).parent
  BASE = GitHubReleaseTest::BASE
  HEAD = GitHubReleaseTest::HEAD

  def fixture(current: false)
    Dir.mktmpdir('moonshine-candidate-controller-') do |directory|
      root = Pathname(directory)
      files = MoonshineCandidate.tree(ROOT).reject { |name, _| name.start_with?('releases/candidates/') || name == 'Casks/moonshine@untested.rb' }
      files.each do |name, bytes|
        path = root/name
        path.dirname.mkpath
        path.binwrite(bytes)
      end
      MoonshineCask.generate(root: root)
      release = R.current(root).release
      if current
        initial = MoonshineCandidate::Store.new.prepare_channel(root, release: release, source: 'd' * 40, expected_current: nil)
        source_tree = MoonshineCandidate.tree(initial['directory'])
        source_tree.each do |name, bytes|
          path = root/name
          path.dirname.mkpath
          path.binwrite(bytes)
        end
        FileUtils.remove_entry_secure(initial['directory'])
        (root/'lib/moonshine_token_guard.rb').open('a') { |file| file.puts '# reviewed guard fix' }
      end
      expected = C.catalog(root)['current']
      item = C.build(root, release)
      data = G.manifest(BASE, release, 123, recipe: item.identity, expected_current: expected)
      changes = C.patch(root: root, release: release, source: BASE, expected_current: expected)
      before = MoonshineCandidate.tree(root).transform_values { |bytes| {'sha' => G.blob(bytes), 'mode' => '100644'} }
      after = before.dup
      changes.each { |name, bytes| bytes ? after[name] = {'sha' => G.blob(bytes), 'mode' => '100644'} : after.delete(name) }
      api = GitHubReleaseTest::FakeAPI.new(before, after, data)
      api.define_singleton_method(:call) do |method, path, value = nil, missing: false|
        if method == 'GET' && path.include?('/compare/')
          reads << path
          {'status' => 'ahead', 'merge_base_commit' => {'sha' => 'd' * 40}}
        else
          super(method, path, value, missing: missing)
        end
      end
      controller = G::Controller.new(api: api, root: root, bot_slug: 'moonshine-updates', bot_id: 12, check_app_id: 15368)
      yield root, api, controller, data
    end
  end

  def publish(controller, data)
    controller.publish(base: data['base_sha'], release: data['release'], asset: data['asset_id'],
                       recipe: data['recipe_sha256'], expected_current: data['expected_current'])
  end

  def test_checked_candidate_publication_preserves_stable_and_uses_exact_head_ci_for_merge
    fixture do |root, api, controller, data|
      before = MoonshineCandidate.tree(root)
      assert_equal 'created', publish(controller, data)['status']
      assert_includes api.pulls.first['head']['ref'], G::BRANCH
      assert_equal data, G.parse_message(api.commit_message)
      writes = api.writes.dup
      assert_equal 'reused', publish(controller, data)['status']
      assert_equal writes, api.writes
      assert_equal 'merged', controller.merge(base: BASE, run_id: 101)['status']
      assert_equal({'sha' => HEAD, 'merge_method' => 'squash'}, api.writes.last.last)
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_candidate_publication_can_resume_each_refused_write_without_changing_either_channel
    %w[/git/trees /git/commits /git/refs /pulls].each do |path|
      fixture(current: true) do |root, api, controller, data|
        before = MoonshineCandidate.tree(root)
        api.fail_write = path
        assert_raises(G::Failure, path) { publish(controller, data) }
        assert_equal before, MoonshineCandidate.tree(root), path
        assert_equal BASE, api.base
        assert_empty api.pulls
        path == '/pulls' ? assert_equal(HEAD, api.branch) : assert_nil(api.branch)
        api.fail_write = nil
        assert_equal 'created', publish(controller, data)['status']
        writes = api.writes.dup
        assert_equal 'reused', publish(controller, data)['status']
        assert_equal writes, api.writes
        assert_equal 1, api.pulls.length
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_candidate_publication_recovers_lost_write_responses_without_overwriting_the_branch
    %w[/git/trees /git/commits /git/refs /pulls].each do |path|
      fixture(current: true) do |root, api, controller, data|
        before = MoonshineCandidate.tree(root)
        lose_response = true
        transport = api.method(:call)
        api.define_singleton_method(:call) do |method, endpoint, value = nil, missing: false|
          result = transport.call(method, endpoint, value, missing: missing)
          if method == 'POST' && endpoint.end_with?(path) && lose_response
            lose_response = false
            raise G::Failure, 'Simulated lost GitHub response after accepting the write'
          end
          result
        end
        assert_raises(G::Failure, path) { publish(controller, data) }
        assert_equal before, MoonshineCandidate.tree(root)
        assert_equal BASE, api.base
        %w[/git/refs /pulls].include?(path) ? assert_equal(HEAD, api.branch) : assert_nil(api.branch)
        assert_equal path == '/pulls' ? 1 : 0, api.pulls.length
        resumed = publish(controller, data)
        assert_equal path == '/pulls' ? 'reused' : 'created', resumed['status']
        assert_equal 1, api.pulls.length
        assert_equal 1, api.writes.count { |method, endpoint, _| method == 'POST' && endpoint == '/git/refs' }
        writes = api.writes.dup
        assert_equal 'reused', publish(controller, data)['status']
        assert_equal writes, api.writes
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_late_candidate_job_cannot_publish_or_merge_after_main_advances
    fixture(current: true) do |root, api, controller, data|
      before = MoonshineCandidate.tree(root)
      assert_equal 'created', publish(controller, data)['status']
      writes = api.writes.dup
      api.base = 'f' * 40
      error = assert_raises(G::Failure) { publish(controller, data) }
      assert_includes error.message, 'Default branch changed'
      assert_raises(G::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_equal writes, api.writes
      assert_equal HEAD, api.branch
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_main_advancing_during_candidate_publication_never_creates_a_stale_pr
    %w[/git/trees /git/refs].each do |path|
      fixture(current: true) do |root, api, controller, data|
        before = MoonshineCandidate.tree(root)
        transport = api.method(:call)
        api.define_singleton_method(:call) do |method, endpoint, value = nil, missing: false|
          result = transport.call(method, endpoint, value, missing: missing)
          @base = 'f' * 40 if method == 'POST' && endpoint.end_with?(path)
          result
        end
        error = assert_raises(G::Failure, path) { publish(controller, data) }
        assert_includes error.message, 'Default branch changed'
        assert_empty api.pulls
        refute api.writes.any? { |_, endpoint, _| endpoint == '/pulls' }
        path == '/git/refs' ? assert_equal(HEAD, api.branch) : assert_nil(api.branch)
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_candidate_merge_refuses_changed_heads_and_superseded_ci
    %i[pr_head branch_head run_head newer_run newer_attempt].each do |fault|
      fixture(current: true) do |root, api, controller, data|
        before = MoonshineCandidate.tree(root)
        assert_equal 'created', publish(controller, data)['status']
        writes = api.writes.dup
        case fault
        when :pr_head then api.pulls.first['head']['sha'] = 'f' * 40
        when :branch_head then api.branch = 'f' * 40
        when :run_head then api.run['head_sha'] = 'f' * 40
        when :newer_run then api.latest['workflow_runs'].first['id'] = 102
        when :newer_attempt then api.latest['workflow_runs'].first['run_attempt'] = 2
        end
        assert_raises(G::Failure, fault.to_s) { controller.merge(base: BASE, run_id: 101) }
        assert_equal writes, api.writes
        assert_equal BASE, api.base
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_candidate_publication_refuses_earlier_or_unrelated_main_history
    %w[behind diverged wrong-ancestor].each do |fault|
      fixture(current: true) do |root, api, controller, data|
        before = MoonshineCandidate.tree(root)
        transport = api.method(:call)
        api.define_singleton_method(:call) do |method, endpoint, value = nil, missing: false|
          if method == 'GET' && endpoint.include?('/compare/')
            {'status' => fault == 'wrong-ancestor' ? 'ahead' : fault,
             'merge_base_commit' => {'sha' => fault == 'wrong-ancestor' ? 'f' * 40 : 'd' * 40}}
          else
            transport.call(method, endpoint, value, missing: missing)
          end
        end
        error = assert_raises(G::Failure, fault) { publish(controller, data) }
        assert_includes error.message, 'Candidate source is not forward reviewed-main history'
        assert_empty api.writes
        assert_nil api.branch
        assert_empty api.pulls
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_publication_of_the_already_selected_recipe_refuses_before_any_git_write
    fixture(current: true) do |root, api, controller, data|
      changes = C.patch(root: root, release: data['release'], source: BASE, expected_current: data['expected_current'])
      changes.each do |name, bytes|
        path = root/name
        if bytes
          path.dirname.mkpath
          path.binwrite(bytes)
        else
          path.delete
        end
      end
      MoonshineCask.generate(root: root, check: true)
      selected = C.catalog(root)['current']
      repeated = G.manifest(BASE, data['release'], 123, recipe: selected, expected_current: selected)
      before = MoonshineCandidate.tree(root)
      files = before.transform_values { |bytes| {'sha' => G.blob(bytes), 'mode' => '100644'} }
      api = GitHubReleaseTest::FakeAPI.new(files, files, repeated)
      api.define_singleton_method(:call) do |method, endpoint, value = nil, missing: false|
        if method == 'GET' && endpoint.end_with?("/compare/#{BASE}...#{BASE}")
          {'status' => 'identical', 'merge_base_commit' => {'sha' => BASE}}
        else
          super(method, endpoint, value, missing: missing)
        end
      end
      controller = G::Controller.new(api: api, root: root, bot_slug: 'moonshine-updates', bot_id: 12, check_app_id: 15368)
      error = assert_raises(G::Failure) { publish(controller, repeated) }
      assert_includes error.message, 'Candidate is already selected; do not publish a loop'
      assert_empty api.writes
      assert_nil api.branch
      assert_empty api.pulls
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_checked_main_trigger_requires_actual_successful_exact_head_jobs
    fixture do |root, api, controller, data|
      api.run.merge!('event' => 'push', 'head_branch' => 'main', 'head_sha' => BASE, 'pull_requests' => [])
      api.latest['workflow_runs'] = [api.run.dup]
      assert controller.checked_main!(BASE, 101)
      steps = api.jobs['jobs'].first['steps']
      check = steps.find { |step| step['name'] == 'Validate an isolated untested recipe with Homebrew' }
      assert check, 'The private candidate integration step must be mandatory'
      check['conclusion'] = 'skipped'
      assert_raises(G::Failure) { controller.checked_main!(BASE, 101) }
      assert_empty api.writes
    end
  end

  def test_same_version_fix_requires_verified_main_ancestry_before_any_write
    fixture(current: true) do |root, api, controller, data|
      assert_equal 'created', publish(controller, data)['status']
      assert api.reads.any? { |path| path.include?('/compare/') }
    end
    fixture(current: true) do |root, api, controller, data|
      api.define_singleton_method(:call) do |method, path, value = nil, missing: false|
        path.include?('/compare/') ? {'status' => 'diverged', 'merge_base_commit' => {'sha' => 'f' * 40}} : super(method, path, value, missing: missing)
      end
      assert_raises(G::Failure) { publish(controller, data) }
      assert_empty api.writes
    end
  end

  def test_changed_expected_current_or_recipe_refuses_without_writes
    %w[expected_current recipe_sha256].each do |key|
      fixture do |root, api, controller, data|
        data[key] = '0' * 64
        assert_raises(StandardError) { publish(controller, data) }
        assert_empty api.writes
      end
    end
  end

  def test_owner_approval_is_exact_head_latest_review_and_not_bot_self_approval
    fixture do |root, api, controller, data|
      owner = {'login' => 'evertonstz', 'id' => 42, 'type' => 'User'}
      api.settings['owner'] = owner
      reviews = [{'id' => 1, 'user' => owner, 'state' => 'APPROVED', 'commit_id' => HEAD}]
      api.define_singleton_method(:call) do |method, path, value = nil, missing: false|
        path.end_with?('/reviews?per_page=100') ? reviews : super(method, path, value, missing: missing)
      end
      controller.owner_review!(7, HEAD)
      reviews << {'id' => 2, 'user' => owner, 'state' => 'CHANGES_REQUESTED', 'commit_id' => HEAD}
      assert_raises(G::Failure) { controller.owner_review!(7, HEAD) }
      reviews.pop
      reviews.first['commit_id'] = 'f' * 40
      assert_raises(G::Failure) { controller.owner_review!(7, HEAD) }
    end
  end

  def test_unconfigured_native_policy_cannot_be_bypassed_with_claimed_successful_evidence
    fixture do |root, api, controller, data|
      (root/'reference/native-policy.json').write(JSON.generate('schema' => 1, 'state' => 'unconfigured', 'reason' => 'Policy not selected'))
      before = MoonshineCandidate.tree(root)
      error = assert_raises(R::Failure) do
        MoonshinePromotion.patch(root: root, target: data['recipe_sha256'], expected_stable: R.current(root).identity,
                                  evidence: {'passed' => true, 'owner_approved' => true})
      end
      assert_includes error.message, 'Native evidence policy is not configured'
      assert_equal before, MoonshineCandidate.tree(root)
      assert_empty api.writes
    end
  end

  def test_projection_uses_exact_retained_recipe_and_never_moves_untested_or_mutates_inputs
    fixture do |root, api, controller, data|
      release = {'version' => '0.16.2', 'sha256' => 'e' * 64, 'filename' => 'moonshine-0.16.2-1.x86_64.rpm'}
      stage = MoonshineCandidate::Store.new.prepare_channel(root, release: release, source: BASE, expected_current: nil)
      staged = Pathname(stage['directory'])
      begin
        target = C.catalog(staged)['current']
        before = MoonshineCandidate.tree(staged)
        projection = MoonshinePromotion.projection(root: staged, target: target, expected_stable: R.current(staged).identity)
        refute projection.keys.any? { |name| name.start_with?('releases/candidates/', 'lib/', 'reference/') }
        assert_equal C.recipe(staged).source, projection['releases/stable/helper.rb']
        assert_equal R.current(staged).source, projection['releases/previous/helper.rb']
        assert_includes projection['Casks/moonshine.rb'], 'version "0.16.2"'
        assert_equal before, MoonshineCandidate.tree(staged)
      ensure
        FileUtils.remove_entry_secure(stage['directory'])
      end
    end
  end
end

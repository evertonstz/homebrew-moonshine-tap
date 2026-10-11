require_relative 'test_github_release'
require_relative 'test_native_policy'

class PromotionControllerTest < Minitest::Test
  G = MoonshineGitHub
  R = MoonshineReleases
  C = MoonshineCandidates
  BASE = GitHubReleaseTest::BASE
  HEAD = GitHubReleaseTest::HEAD

  def fixture(later_candidate: false)
    native = NativePolicyTest.new('fixture')
    native.fixture do |root, _initial, evidence|
      release = {'version' => '0.16.2', 'filename' => 'moonshine-0.16.2-1.x86_64.rpm', 'sha256' => 'd' * 64}
      C.patch(root: root, release: release, source: BASE, expected_current: C.catalog(root)['current']).each do |name, bytes|
        path = root/name
        if bytes
          path.dirname.mkpath
          path.binwrite(bytes)
        else
          path.delete
        end
      end
      item = C.recipe(root)
      if later_candidate
        following = {'version' => '0.16.3', 'filename' => 'moonshine-0.16.3-1.x86_64.rpm', 'sha256' => 'e' * 64}
        C.patch(root: root, release: following, source: 'f' * 40, expected_current: item.identity).each do |name, bytes|
          path = root/name
          if bytes
            path.dirname.mkpath
            path.binwrite(bytes)
          else
            path.delete
          end
        end
      end
      (root/'releases/candidates').children.select { |path| path.directory? && path.children.empty? }.each(&:rmdir)
      evidence.merge!('recipe_sha256' => item.identity, 'rpm' => item.release,
                      'installed_version' => "#{item.release['version']}+#{item.identity}")
      origin, reader, replies = native.owner_source(evidence)
      replies.values[1]['issue_url'] = replies.values[1]['issue_url'].sub('/issues/7', '/issues/55')
      pull = replies.delete('/repos/evertonstz/homebrew-moonshine-tap/pulls/7')
      pull['number'] = 55
      replies['/repos/evertonstz/homebrew-moonshine-tap/pulls/55'] = pull
      assessment = MoonshinePromotion.assess(root: root, target: item.identity, expected_stable: R.current(root).identity,
                                            origin: origin, api: reader)
      selection = {'target' => item.identity, 'expected_stable' => R.current(root).identity,
                   'origin' => origin, 'report_sha256' => assessment['report_sha256']}
      data = {'base_sha' => BASE, 'operation' => 'promote', **selection}
      before = MoonshineCandidate.tree(root).transform_values { |bytes| {'sha' => G.blob(bytes), 'mode' => '100644'} }
      after = before.dup
      MoonshinePromotion.projection(root: root, target: item.identity, expected_stable: R.current(root).identity).each do |name, bytes|
        bytes ? after[name] = {'sha' => G.blob(bytes), 'mode' => '100644'} : after.delete(name)
      end
      api = GitHubReleaseTest::FakeAPI.new(before, after, data)
      api.settings.merge!(replies.values.first)
      reviews = []
      transport = api.method(:call)
      api.define_singleton_method(:call) do |method, path, value = nil, missing: false|
        if method == 'GET' && path.end_with?('/reviews?per_page=100')
          reviews
        elsif method == 'GET' && (path.end_with?('/issues/comments/91') || path.end_with?('/pulls/55'))
          reader.call(method, path)
        else
          transport.call(method, path, value, missing: missing)
        end
      end
      controller = G::Controller.new(api: api, root: root, bot_slug: 'moonshine-updates', bot_id: 12, check_app_id: 15368, promotions_enabled: true)
      yield root, item, api, controller, selection, replies, reviews
    end
  end

  def approve(replies, reviews)
    reviews << {'id' => 1, 'user' => replies.values.first.fetch('owner').dup, 'state' => 'APPROVED', 'commit_id' => HEAD}
  end

  def test_promotion_requires_latest_numeric_owner_approval_of_the_exact_final_head
    fixture do |root, _item, api, controller, selection, replies, reviews|
      controller.publish(base: BASE, promotion: selection)
      writes = api.writes.dup
      assert_raises(G::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_equal writes, api.writes
      approve(replies, reviews)
      reviews.first['user']['id'] = 71.0
      assert_raises(G::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_equal writes, api.writes
      reviews.first['user']['id'] = 71
      reviews.first['commit_id'] = 'f' * 40
      assert_raises(G::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_equal writes, api.writes
      reviews.first['commit_id'] = HEAD
      reviews << reviews.first.merge('id' => 2, 'state' => 'CHANGES_REQUESTED')
      assert_raises(G::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_equal writes, api.writes
      reviews.pop
      before = MoonshineCandidate.tree(root)
      assert_equal 'merged', controller.merge(base: BASE, run_id: 101)['status']
      assert_equal ['PUT', '/pulls/7/merge', {'sha' => HEAD, 'merge_method' => 'squash'}], api.writes.last
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_native_source_changing_during_ci_validation_refuses_before_merge
    fixture do |_root, _item, api, controller, selection, replies, reviews|
      controller.publish(base: BASE, promotion: selection)
      approve(replies, reviews)
      writes = api.writes.dup
      transport = api.method(:call)
      api.define_singleton_method(:call) do |method, path, value = nil, missing: false|
        result = transport.call(method, path, value, missing: missing)
        replies.values[1]['body'] += ' ' if method == 'GET' && path.end_with?('/jobs?per_page=100')
        result
      end
      assert_raises(R::Failure) { controller.merge(base: BASE, run_id: 101) }
      assert_equal writes, api.writes
    end
  end

  def test_explicit_retained_target_does_not_follow_a_later_moving_candidate
    fixture(later_candidate: true) do |root, item, api, controller, selection, _replies, _reviews|
      moving = C.catalog(root)['current']
      refute_equal item.identity, moving
      assert_equal 'created', controller.publish(base: BASE, promotion: selection)['status']
      entries = api.writes.first.last.fetch('tree').to_h { |entry| [entry['path'], entry] }
      assert_includes entries.fetch('Casks/moonshine.rb').fetch('content'), "version \"0.16.2+#{item.identity}\""
      assert_includes entries.fetch('Casks/moonshine@untested.rb').fetch('content'), "version \"0.16.3+#{moving}\""
      assert_equal moving, C.catalog(root)['current']
      refute entries.keys.any? { |path| path.start_with?('releases/candidates/') }
    end
  end

  def test_bad_digest_target_baseline_policy_and_source_refuse_without_any_write
    %i[digest target baseline owner source policy observation].each do |fault|
      fixture do |root, _item, api, controller, selection, replies, _reviews|
        case fault
        when :digest then selection['report_sha256'] = '0' * 64
        when :target then selection['target'] = '0' * 64
        when :baseline then selection['expected_stable'] = '0' * 64
        when :owner then replies.values[1]['user']['id'] = 72
        when :source then replies.values[1]['body'] += ' '
        when :policy then (root/'reference/native-policy.json').write('{}')
        when :observation
          report = JSON.parse(replies.values[1]['body'].delete_prefix(MoonshineNativeOrigin::PREFIX))
          report['checks']['video'] = 'failed'
          replies.values[1]['body'] = MoonshineNativeOrigin::PREFIX + JSON.generate(report)
          selection['origin']['body_sha256'] = Digest::SHA256.hexdigest(replies.values[1]['body'])
        end
        before = MoonshineCandidate.tree(root)
        assert_raises(G::Failure, R::Failure) { controller.publish(base: BASE, promotion: selection) }
        assert_empty api.writes
        assert_nil api.branch
        assert_empty api.pulls
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_insufficient_protection_and_foreign_candidate_arguments_refuse_before_publication
    fixture do |_root, _item, api, controller, selection, _replies, _reviews|
      api.protection['required_status_checks']['strict'] = false
      assert_raises(G::Failure) { controller.publish(base: BASE, promotion: selection) }
      assert_empty api.writes
      api.protection['required_status_checks']['strict'] = true
      assert_raises(G::Failure) { controller.publish(base: BASE, promotion: selection, release: GitHubReleaseTest::RELEASE) }
      assert_empty api.writes
    end
  end

  def test_failed_superseded_ci_changed_base_head_patch_and_source_never_merge
    %i[ci skipped latest base head patch mode source report_digest].each do |fault|
      fixture do |_root, _item, api, controller, selection, replies, reviews|
        controller.publish(base: BASE, promotion: selection)
        approve(replies, reviews)
        writes = api.writes.dup
        case fault
        when :ci then api.jobs['jobs'].first['conclusion'] = 'failure'
        when :skipped then api.jobs['jobs'].first['steps'].first['conclusion'] = 'skipped'
        when :latest then api.latest['workflow_runs'].first['id'] = 102
        when :base then api.base = 'f' * 40
        when :head then api.branch = 'f' * 40
        when :patch then api.head_files['README.md']['sha'] = 'f' * 40
        when :mode then api.head_files['releases/stable/helper.rb']['mode'] = '100755'
        when :source then replies.values[1]['body'] += ' '
        when :report_digest
          manifest = G.parse_message(api.commit_message)
          api.commit_message = G.message(manifest.merge('report_sha256' => '0' * 64))
        end
        assert_raises(G::Failure, R::Failure) { controller.merge(base: BASE, run_id: 101) }
        assert_equal writes, api.writes
      end
    end
  end

  def test_same_version_delivery_requires_checked_provenance_even_for_an_authenticated_bound_report
    native = NativePolicyTest.new('fixture')
    native.fixture do |root, item, evidence|
      origin, api, _replies = native.owner_source(evidence)
      assessed = MoonshinePromotion.assess(root: root, target: item.identity, expected_stable: R.current(root).identity, origin: origin, api: api)
      before = MoonshineCandidate.tree(root)
      transport = api.method(:call)
      api.define_singleton_method(:call) do |method, path, *args, **options|
        raise G::Failure, 'GitHub provenance access refused' if path.include?('/git/') || path.include?('/compare/')
        transport.call(method, path, *args, **options)
      end
      error = assert_raises(G::Failure) do
        MoonshinePromotion.patch(root: root, target: item.identity, expected_stable: R.current(root).identity,
                                origin: origin, api: api, report_sha256: assessed['report_sha256'])
      end
      assert_includes error.message, 'provenance access refused'
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_source_changes_during_publication_do_not_create_a_stale_bound_branch
    fixture do |_root, _item, api, controller, selection, replies, _reviews|
      transport = api.method(:call)
      api.define_singleton_method(:call) do |method, path, value = nil, missing: false|
        result = transport.call(method, path, value, missing: missing)
        replies.values[1]['body'] += ' ' if method == 'POST' && path.end_with?('/git/commits')
        result
      end
      assert_raises(R::Failure) { controller.publish(base: BASE, promotion: selection) }
      assert_nil api.branch
      assert_empty api.pulls
    end
  end

  def test_candidate_activation_alone_cannot_publish_or_merge_stable_promotion
    fixture do |root, _item, api, enabled, selection, replies, reviews|
      disabled = G::Controller.new(api: api, root: root, bot_slug: 'moonshine-updates', bot_id: 12, check_app_id: 15368)
      assert_raises(G::Failure) { disabled.publish(base: BASE, promotion: selection) }
      assert_empty api.writes
      enabled.publish(base: BASE, promotion: selection)
      approve(replies, reviews)
      writes = api.writes.dup
      assert_raises(G::Failure) { disabled.merge(base: BASE, run_id: 101) }
      assert_equal writes, api.writes
    end
  end

  def test_partial_promotion_writes_resume_without_overwriting_any_branch_or_local_recipe
    %w[/git/trees /git/commits /git/refs /pulls].each do |path|
      fixture do |root, _item, api, controller, selection, _replies, _reviews|
        before = MoonshineCandidate.tree(root)
        api.fail_write = path
        assert_raises(G::Failure) { controller.publish(base: BASE, promotion: selection) }
        assert_empty api.pulls
        assert_equal before, MoonshineCandidate.tree(root)
        api.fail_write = nil
        assert_equal 'created', controller.publish(base: BASE, promotion: selection)['status']
        writes = api.writes.dup
        assert_equal 'reused', controller.publish(base: BASE, promotion: selection)['status']
        assert_equal writes, api.writes
        assert_equal 1, api.writes.count { |method, endpoint, _| method == 'POST' && endpoint == '/git/refs' } if path == '/pulls'
      end
    end
  end

  def test_matching_offline_claims_and_digest_cannot_authorize_a_positive_patch
    fixture do |root, item, _api, _controller, selection, replies, _reviews|
      report = replies.values[1]['body'].delete_prefix(MoonshineNativeOrigin::PREFIX)
      before = MoonshineCandidate.tree(root)
      assert_raises(R::Failure) do
        MoonshinePromotion.patch(root: root, target: item.identity, expected_stable: R.current(root).identity,
                                evidence: report, report_sha256: selection['report_sha256'])
      end
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_authenticated_promotion_creates_one_checked_pr_without_rotating_the_local_channels
    fixture do |root, item, api, controller, selection, _replies, _reviews|
      before = MoonshineCandidate.tree(root)
      result = controller.publish(base: BASE, promotion: selection)
      assert_equal 'created', result['status']
      assert_equal HEAD, result['head_sha']
      assert_equal %w[/git/trees /git/commits /git/refs /pulls], api.writes.map { |_, path, _| path }
      entries = api.writes.first.last.fetch('tree').to_h { |entry| [entry['path'], entry] }
      assert_equal item.source, entries.fetch('releases/stable/helper.rb').fetch('content')
      assert_equal R.current(root).source, entries.fetch('releases/previous/helper.rb').fetch('content')
      assert_includes entries.fetch("Casks/moonshine@0.16.2-#{item.identity}.rb").fetch('content'), "version \"0.16.2+#{item.identity}\""
      assert_nil entries.fetch('Casks/moonshine@0.16.0.rb')['sha']
      refute entries.keys.any? { |name| name.start_with?('releases/candidates/', 'lib/', 'reference/', 'docs/') }
      assert_equal before, MoonshineCandidate.tree(root)
      assert_equal item.identity, C.catalog(root)['current']
      assert_equal selection, G.parse_message(api.commit_message).reject { |key, _| %w[base_sha operation].include?(key) }
      assert_includes api.writes.last.last.fetch('body'), 'Owner attestation'
      writes = api.writes.dup
      assert_equal 'reused', controller.publish(base: BASE, promotion: selection)['status']
      assert_equal writes, api.writes
    end
  end
end

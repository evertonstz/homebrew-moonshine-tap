require_relative 'test_promotion_workflow'

class PromotionFlowTest < Minitest::Test
  def helper
    PromotionWorkflowTest.new('fixture')
  end

  def fixture(later_candidate: false, &block)
    PromotionControllerTest.new('fixture').fixture(later_candidate: later_candidate, &block)
  end

  def prerequisites(root, api, selection, output)
    code = nil
    stdout, stderr = capture_io do
      code = MoonshinePromotionReport.main(['/usr/bin/tar'],
        helper.environment(selection).merge('GITHUB_OUTPUT' => output.to_s), api: api, root: root,
        client: helper.download_client, runner: helper.process_runner([]))
    end
    [code, stdout, stderr]
  end

  def publisher(fields)
    # Consume actual prerequisite outputs. No receipt file, package path or report body crosses this boundary.
    {'GITHUB_REPOSITORY' => MoonshineGitHub::REPOSITORY, 'GITHUB_REF' => 'refs/heads/main',
     'GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_ACTOR' => 'evertonstz', 'GITHUB_TRIGGERING_ACTOR' => 'evertonstz',
     'MOONSHINE_STABLE_PROMOTION_ENABLED' => 'true', 'MOONSHINE_RELEASE_UPDATES_ENABLED' => 'false',
     'MOONSHINE_APP_SLUG' => 'moonshine-updates', 'MOONSHINE_TOKEN_APP_SLUG' => 'moonshine-updates',
     'MOONSHINE_BOT_ID' => '12', 'MOONSHINE_CHECK_APP_ID' => '15368',
     'MOONSHINE_BASE_SHA' => fields.fetch('base_sha'), 'MOONSHINE_PROMOTION_TARGET' => fields.fetch('target'),
     'MOONSHINE_EXPECTED_STABLE' => fields.fetch('expected_stable'),
     'MOONSHINE_NATIVE_COMMENT_ID' => fields.fetch('comment_id'),
     'MOONSHINE_NATIVE_COMMENT_SHA256' => fields.fetch('comment_sha256'),
     'MOONSHINE_NATIVE_COMMENT_UPDATED_AT' => fields.fetch('comment_updated_at'),
     'MOONSHINE_NATIVE_REPORT_SHA256' => fields.fetch('report_sha256')}
  end

  def invoke(root, api, env, command)
    code = nil
    stdout, stderr = capture_io do
      code = MoonshineGitHubCLI.main([command], env, api: api, root: root, runner: helper.process_runner([]))
    end
    [code, stdout, stderr]
  end

  def checked_fields(root, api, selection)
    Dir.mktmpdir('moonshine-flow-output-') do |directory|
      output = Pathname(directory)/'outputs'
      code, stdout, stderr = prerequisites(root, api, selection, output)
      assert_equal 0, code, stderr
      assert_empty stderr
      summary = JSON.parse(stdout)
      assert_equal false, summary['publication_enabled']
      assert_equal false, summary['native_acceptance_verified']
      assert_equal false, summary['host_installation']
      assert_equal true, summary.dig('packages', 'contract_compared')
      yield output.read.lines.to_h { |line| line.chomp.split('=', 2) }
    end
  end

  def test_failed_owner_observations_never_export_a_publishable_request
    %w[video upgrade personal_data].each do |observation|
      fixture do |root, _item, api, _controller, selection, replies, _reviews|
        report = JSON.parse(replies.values[1]['body'].delete_prefix(MoonshineNativeOrigin::PREFIX))
        report['checks'][observation] = 'failed'
        replies.values[1]['body'] = MoonshineNativeOrigin::PREFIX + JSON.generate(report)
        selection['origin']['body_sha256'] = Digest::SHA256.hexdigest(replies.values[1]['body'])
        before = MoonshineCandidate.tree(root)
        Dir.mktmpdir do |directory|
          output = Pathname(directory)/'outputs'
          code, stdout, stderr = prerequisites(root, api, selection, output)
          assert_equal 1, code
          assert_empty stdout
          refute output.exist?
          assert_includes stderr, 'observations did not pass'
          assert_empty api.writes
          assert_equal before, MoonshineCandidate.tree(root)
        end
      end
    end
  end

  def test_exported_scalars_cannot_authorize_changed_source_target_report_or_base
    %i[source target digest stable base].each do |fault|
      fixture do |root, _item, api, _controller, selection, replies, _reviews|
        checked_fields(root, api, selection) do |fields|
          env = publisher(fields)
          case fault
          when :source then replies.values[1]['body'] += ' '
          when :target then env['MOONSHINE_PROMOTION_TARGET'] = 'f' * 64
          when :digest then env['MOONSHINE_NATIVE_REPORT_SHA256'] = '0' * 64
          when :stable then env['MOONSHINE_EXPECTED_STABLE'] = 'f' * 64
          when :base then api.base = 'f' * 40
          end
          before = MoonshineCandidate.tree(root)
          code, stdout, stderr = invoke(root, api, env, 'promote')
          assert_equal 1, code
          assert_empty stdout
          refute_empty stderr
          assert_empty api.writes
          assert_nil api.branch
          assert_empty api.pulls
          assert_equal before, MoonshineCandidate.tree(root)
        end
      end
    end
  end

  def test_repeated_requests_and_old_owner_approval_cannot_reuse_a_changed_source_or_ci_head
    %i[source head ci review].each do |fault|
      fixture do |root, _item, api, _controller, selection, replies, reviews|
        checked_fields(root, api, selection) do |fields|
          env = publisher(fields)
          code, _stdout, stderr = invoke(root, api, env, 'promote')
          assert_equal 0, code, stderr
          PromotionControllerTest.new('approve').approve(replies, reviews)
          writes = api.writes.dup
          before = MoonshineCandidate.tree(root)
          case fault
          when :source
            replies.values[1]['body'] += ' '
            2.times do
              code, stdout, stderr = invoke(root, api, env, 'promote')
              assert_equal 1, code
              assert_empty stdout
              refute_empty stderr
              assert_equal writes, api.writes
            end
          when :head then api.branch = 'f' * 40
          when :ci then api.jobs['jobs'].first['steps'].first['conclusion'] = 'skipped'
          when :review then reviews.first['commit_id'] = 'f' * 40
          end
          merge_env = env.merge('GITHUB_EVENT_NAME' => 'workflow_run', 'MOONSHINE_CI_RUN_ID' => '101')
          code, stdout, stderr = invoke(root, api, merge_env, 'merge')
          assert_equal 1, code
          assert_empty stdout
          refute_empty stderr
          assert_equal writes, api.writes
          assert_equal before, MoonshineCandidate.tree(root)
        end
      end
    end
  end

  def test_checked_outputs_never_waive_scope_or_current_base_protection
    %i[scope strict bypass].each do |fault|
      fixture do |root, _item, api, _controller, selection, _replies, _reviews|
        checked_fields(root, api, selection) do |fields|
          case fault
          when :scope then api.scope['total_count'] = 2
          when :strict then api.protection['required_status_checks']['strict'] = false
          when :bypass then api.protection['required_pull_request_reviews']['bypass_pull_request_allowances']['apps'] = [{'id' => 12}]
          end
          before = MoonshineCandidate.tree(root)
          code, stdout, stderr = invoke(root, api, publisher(fields), 'promote')
          assert_equal 1, code
          assert_empty stdout
          refute_empty stderr
          assert_empty api.writes
          assert_equal before, MoonshineCandidate.tree(root)
        end
      end
    end
  end

  def test_complete_scalar_handoff_promotes_only_the_retained_target_and_rotates_once
    fixture(later_candidate: true) do |root, item, api, _controller, selection, replies, reviews|
      before = MoonshineCandidate.tree(root)
      stable = MoonshineReleases.current(root)
      moving = MoonshineCandidates.recipe(root)
      refute_equal item.identity, moving.identity
      checked_fields(root, api, selection) do |fields|
        assert_equal 'eligible', fields['status']
        assert_equal item.identity, fields['target']
        env = publisher(fields)
        code, stdout, stderr = invoke(root, api, env, 'promote')
        assert_equal 0, code, stderr
        assert_empty stderr
        assert_equal 'created', JSON.parse(stdout)['status']
        entries = api.writes.first.last.fetch('tree').to_h { |entry| [entry['path'], entry] }
        assert_equal item.source, entries.fetch('releases/stable/helper.rb').fetch('content')
        assert_equal stable.source, entries.fetch('releases/previous/helper.rb').fetch('content')
        assert_equal item.identity, JSON.parse(entries.fetch('releases/stable/release.json').fetch('content'))['recipe_sha256']
        assert_equal stable.identity, JSON.parse(entries.fetch('releases/previous/release.json').fetch('content'))['recipe_sha256']
        assert_includes entries.fetch('Casks/moonshine@0.16.2.rb').fetch('content'), 'version "0.16.2"'
        assert_includes entries.fetch('Casks/moonshine@untested.rb').fetch('content'), "version \"0.16.3+#{moving.identity}\""
        assert_nil entries.fetch('Casks/moonshine@0.16.0.rb')['sha']
        refute entries.keys.any? { |name| name.start_with?('lib/', 'reference/', 'docs/', 'releases/candidates/') }
        writes = api.writes.dup
        code, stdout, stderr = invoke(root, api, env, 'promote')
        assert_equal 0, code, stderr
        assert_equal 'reused', JSON.parse(stdout)['status']
        assert_equal writes, api.writes
        merge_env = env.merge('GITHUB_EVENT_NAME' => 'workflow_run', 'MOONSHINE_CI_RUN_ID' => '101')
        code, stdout, stderr = invoke(root, api, merge_env, 'merge')
        assert_equal 1, code
        assert_empty stdout
        assert_includes stderr, 'owner approval'
        assert_equal writes, api.writes
        PromotionControllerTest.new('approve').approve(replies, reviews)
        code, stdout, stderr = invoke(root, api, merge_env, 'merge')
        assert_equal 0, code, stderr
        assert_equal 'merged', JSON.parse(stdout)['status']
        assert_equal ['PUT', '/pulls/7/merge', {'sha' => PromotionControllerTest::HEAD, 'merge_method' => 'squash'}], api.writes.last
        assert_equal 1, api.writes.count { |method, _path, _value| method == 'PUT' }
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end
end

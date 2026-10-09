require_relative 'test_promotion_controller'
require_relative 'test_candidate_controller'
require_relative '../tools/promotion_report'
require_relative '../tools/github_release'

class PromotionWorkflowTest < Minitest::Test
  Status = Struct.new(:success?)
  def environment(selection)
    {'GITHUB_REPOSITORY' => MoonshineGitHub::REPOSITORY, 'GITHUB_REF' => 'refs/heads/main',
     'GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_ACTOR' => 'evertonstz', 'GITHUB_TRIGGERING_ACTOR' => 'evertonstz',
     'MOONSHINE_PROMOTION_TARGET' => selection['target'], 'MOONSHINE_EXPECTED_STABLE' => selection['expected_stable'],
     'MOONSHINE_NATIVE_COMMENT_ID' => selection['origin']['comment_id'].to_s,
     'MOONSHINE_NATIVE_COMMENT_SHA256' => selection['origin']['body_sha256'],
     'MOONSHINE_NATIVE_COMMENT_UPDATED_AT' => selection['origin']['updated_at']}
  end

  def fixture(&block)
    PromotionControllerTest.new('fixture').fixture(&block)
  end

  def process_runner(calls, bad: false)
    lambda do |*args|
      calls << args
      if args.first == 'git'
        [PromotionControllerTest::BASE + "\n", '', Status.new(true)]
      else
        # External helper process boundary; real RPM extraction is separately mandatory in CI.
        contract = {'dependencies' => [], 'inventory' => {}, 'protected' => {}, 'tags' => {}}
        [JSON.generate(contract), 'inspection refused', Status.new(!bad)]
      end
    end
  end

  def download_client
    client = Object.new
    client.define_singleton_method(:download) { |_url, path| path.binwrite('synthetic external package bytes') }
    client
  end

  def test_package_gate_refuses_write_credentials_offline_claims_and_missing_tool_without_outputs
    fixture do |root, _item, api, _controller, selection, replies, _reviews|
      changes = [
        [['/usr/bin/tar'], {'MOONSHINE_APP_TOKEN' => 'private-write-token'}],
        [['/missing-extractor'], {}],
        [['/usr/bin/tar'], {'MOONSHINE_NATIVE_COMMENT_ID' => nil, 'MOONSHINE_NATIVE_COMMENT_SHA256' => nil,
          'MOONSHINE_NATIVE_COMMENT_UPDATED_AT' => nil, 'MOONSHINE_NATIVE_EVIDENCE' => replies.values[1]['body'].delete_prefix(MoonshineNativeOrigin::PREFIX)}]
      ]
      changes.each do |argv, change|
        Dir.mktmpdir do |dir|
          output = Pathname(dir)/'outputs'
          env = environment(selection).merge(change).compact.merge('GITHUB_OUTPUT' => output.to_s)
          stdout, stderr = capture_io do
            assert_equal 1, MoonshinePromotionReport.main(argv, env, api: api, root: root,
              client: download_client, runner: process_runner([]))
          end
          assert_empty stdout
          refute output.exist?
          refute_includes stderr, 'private-write-token'
          assert_empty api.writes
        end
      end
    end
  end

  def test_workflow_keeps_package_loading_credential_free_and_publisher_independently_gated
    require 'yaml'
    workflow = YAML.safe_load((NativePolicyTest::ROOT/'.github/workflows/release-promote.yml').read)
    assert_equal({'contents' => 'read', 'pull-requests' => 'read'}, workflow['permissions'])
    assert_equal ['workflow_dispatch'], workflow['on'].keys
    read_only = workflow.dig('jobs', 'prerequisites')
    publish = workflow.dig('jobs', 'publish')
    assert publish, 'A scoped publisher must follow successful read-only prerequisites'
    assert_equal ['prerequisites'], publish['needs']
    assert_includes publish['if'], "vars.MOONSHINE_STABLE_PROMOTION_ENABLED == 'true'"
    assert_includes publish['if'], "needs.prerequisites.outputs.status == 'eligible'"
    assert_includes publish['if'], "github.triggering_actor == 'evertonstz'"
    refute_includes publish['if'], 'MOONSHINE_RELEASE_UPDATES_ENABLED'
    refute_includes JSON.generate(read_only), 'secrets.'
    refute_includes JSON.generate(read_only), 'create-github-app-token'
    assert_equal 'main', read_only['steps'].find { |step| step['uses'].to_s.start_with?('actions/checkout@') }.dig('with', 'ref')
    assert read_only['steps'].any? { |step| step['run'].to_s.include?('tools/check_casks.rb') }
    assert read_only['steps'].any? { |step| step['run'].to_s.include?('tools/promotion_report.rb /usr/bin/bsdtar') }
    assert_equal %w[base_sha comment_id comment_sha256 comment_updated_at expected_stable report_sha256 status target], read_only['outputs'].keys.sort
    checkout = publish['steps'].find { |step| step['uses'].to_s.start_with?('actions/checkout@') }
    assert_equal '${{ needs.prerequisites.outputs.base_sha }}', checkout.dig('with', 'ref')
    assert_equal false, checkout.dig('with', 'persist-credentials')
    app = publish['steps'].find { |step| step['uses'].to_s.start_with?('actions/create-github-app-token@') }
    assert_equal 'evertonstz', app.dig('with', 'owner')
    assert_equal 'homebrew-moonshine-tap', app.dig('with', 'repositories')
    assert_equal 'read', app.dig('with', 'permission-administration')
    assert_equal 'write', app.dig('with', 'permission-contents')
    assert_equal 'write', app.dig('with', 'permission-pull-requests')
    assert_equal 'read', app.dig('with', 'permission-actions')
    step = publish['steps'].find { |item| item['run'] == 'ruby --disable=rubyopt tools/github_release.rb promote' }
    assert step
    assert_equal '${{ needs.prerequisites.outputs.report_sha256 }}', step.dig('env', 'MOONSHINE_NATIVE_REPORT_SHA256')
    assert_equal '${{ vars.MOONSHINE_STABLE_PROMOTION_ENABLED }}', step.dig('env', 'MOONSHINE_STABLE_PROMOTION_ENABLED')
    refute_includes JSON.generate(publish), 'tools/check_casks.rb'
    refute_includes JSON.generate(publish), 'bsdtar'
    refute_includes JSON.generate(workflow), 'download-artifact'
    workflow['jobs'].each_value do |job|
      assert_equal 10, job['timeout-minutes']
      job['steps'].select { |item| item['uses'] }.each { |item| assert_match(/@[0-9a-f]{40}\z/, item['uses']) }
    end
    merge = YAML.safe_load((NativePolicyTest::ROOT/'.github/workflows/release-merge.yml').read).dig('jobs', 'merge')
    assert_includes merge['if'], "vars.MOONSHINE_STABLE_PROMOTION_ENABLED == 'true'"
    assert_equal '${{ vars.MOONSHINE_STABLE_PROMOTION_ENABLED }}', merge['steps'].last.dig('env', 'MOONSHINE_STABLE_PROMOTION_ENABLED')
  end

  def publisher_environment(selection)
    environment(selection).merge('MOONSHINE_STABLE_PROMOTION_ENABLED' => 'true',
      'MOONSHINE_RELEASE_UPDATES_ENABLED' => 'false', 'MOONSHINE_APP_SLUG' => 'moonshine-updates',
      'MOONSHINE_TOKEN_APP_SLUG' => 'moonshine-updates', 'MOONSHINE_BOT_ID' => '12',
      'MOONSHINE_CHECK_APP_ID' => '15368', 'MOONSHINE_BASE_SHA' => PromotionControllerTest::BASE,
      'MOONSHINE_NATIVE_REPORT_SHA256' => selection['report_sha256'])
  end

  def test_publisher_cli_reconstructs_exact_promotion_and_merge_requires_head_approval
    fixture do |root, _item, api, _controller, selection, replies, reviews|
      env = publisher_environment(selection)
      runner = process_runner([])
      before = MoonshineCandidate.tree(root)
      stdout, stderr = capture_io do
        assert_equal 0, MoonshineGitHubCLI.main(['promote'], env, api: api, root: root, runner: runner)
      end
      assert_empty stderr
      assert_equal 'created', JSON.parse(stdout)['status']
      assert_equal selection, MoonshineGitHub.parse_message(api.commit_message).reject { |key, _| %w[base_sha operation].include?(key) }
      writes = api.writes.dup
      merge_env = env.merge('GITHUB_EVENT_NAME' => 'workflow_run', 'MOONSHINE_CI_RUN_ID' => '101')
      stdout, stderr = capture_io do
        assert_equal 1, MoonshineGitHubCLI.main(['merge'], merge_env, api: api, root: root, runner: runner)
      end
      assert_empty stdout
      assert_includes stderr, 'owner approval'
      assert_equal writes, api.writes
      PromotionControllerTest.new('approve').approve(replies, reviews)
      stdout, stderr = capture_io do
        assert_equal 0, MoonshineGitHubCLI.main(['merge'], merge_env, api: api, root: root, runner: runner)
      end
      assert_empty stderr
      assert_equal 'merged', JSON.parse(stdout)['status']
      assert_equal ['PUT', '/pulls/7/merge', {'sha' => PromotionControllerTest::HEAD, 'merge_method' => 'squash'}], api.writes.last
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_cli_refuses_independent_activation_actor_baseline_digest_and_foreign_inputs_before_writes
    changes = [
      {'MOONSHINE_STABLE_PROMOTION_ENABLED' => 'false', 'MOONSHINE_RELEASE_UPDATES_ENABLED' => 'true'},
      {'MOONSHINE_STABLE_PROMOTION_ENABLED' => 'TRUE'}, {'GITHUB_ACTOR' => 'someone-else'},
      {'GITHUB_TRIGGERING_ACTOR' => 'someone-else'}, {'GITHUB_EVENT_NAME' => 'schedule'},
      {'GITHUB_REF' => 'refs/heads/feature'}, {'GITHUB_REPOSITORY' => 'attacker/tap'},
      {'MOONSHINE_BASE_SHA' => 'f' * 40}, {'MOONSHINE_NATIVE_REPORT_SHA256' => '0' * 64},
      {'MOONSHINE_NATIVE_COMMENT_ID' => '91.0'}, {'MOONSHINE_NATIVE_COMMENT_ID' => '091'},
      {'MOONSHINE_EXPECTED_STABLE' => 'f' * 64}, {'MOONSHINE_PROMOTION_TARGET' => 'f' * 64},
      {'MOONSHINE_NATIVE_COMMENT_SHA256' => 'f' * 64}, {'MOONSHINE_NATIVE_COMMENT_UPDATED_AT' => '2026-01-01T12:00:02Z'},
      {'MOONSHINE_RELEASE' => '{}'}, {'MOONSHINE_NATIVE_EVIDENCE' => '{}'}, {'MOONSHINE_OPERATION' => 'rollback'},
      {'MOONSHINE_TOKEN_APP_SLUG' => 'foreign-app'}
    ]
    fixture do |root, _item, api, _controller, selection, _replies, _reviews|
      before = MoonshineCandidate.tree(root)
      changes.each do |change|
        stdout, stderr = capture_io do
          assert_equal 1, MoonshineGitHubCLI.main(['promote'], publisher_environment(selection).merge(change),
            api: api, root: root, runner: process_runner([]))
        end
        assert_empty stdout
        refute_empty stderr
        assert_empty api.writes
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_promotion_activation_does_not_enable_candidate_publication
    fixture do |root, _item, api, _controller, selection, _replies, _reviews|
      stdout, stderr = capture_io do
        assert_equal 1, MoonshineGitHubCLI.main(['publish'], publisher_environment(selection),
          api: api, root: root, runner: process_runner([]))
      end
      assert_empty stdout
      assert_includes stderr, 'not activated'
      assert_empty api.writes
    end
    candidate = CandidateControllerTest.new('fixture')
    candidate.fixture do |root, api, controller, data|
      candidate.publish(controller, data)
      writes = api.writes.dup
      stable_only = MoonshineGitHub::Controller.new(api: api, root: root, bot_slug: 'moonshine-updates', bot_id: 12,
        check_app_id: 15368, promotions_enabled: true, candidates_enabled: false)
      assert_raises(MoonshineGitHub::Failure) { stable_only.merge(base: GitHubReleaseTest::BASE, run_id: 101) }
      assert_equal writes, api.writes
    end
  end

  def test_changed_contract_or_local_tree_cannot_export_promotion_eligibility
    %i[contract tree].each do |fault|
      fixture do |root, _item, api, _controller, selection, _replies, _reviews|
        Dir.mktmpdir do |dir|
          output = Pathname(dir)/'outputs'
          env = environment(selection).merge('GITHUB_OUTPUT' => output.to_s)
          external = process_runner([])
          runner = lambda do |*args|
            result = external.call(*args)
            unless args.first == 'git'
              if fault == :contract && JSON.parse(args.last)['version'] == '0.16.2'
                result[0] = JSON.generate('dependencies' => [], 'inventory' => {}, 'protected' => {'/etc/unsafe' => 'changed'}, 'tags' => {})
              elsif fault == :tree
                (root/'README.md').write('changed while inspecting packages')
              end
            end
            result
          end
          stdout, stderr = capture_io do
            assert_equal 1, MoonshinePromotionReport.main(['/usr/bin/tar'], env, api: api, root: root,
              client: download_client, runner: runner)
          end
          assert_empty stdout
          refute output.exist?
          assert_includes stderr, fault == :contract ? 'review required' : 'inputs changed'
          assert_empty api.writes
        end
      end
    end
  end

  def test_failed_inspection_source_edit_or_advancing_base_exports_no_positive_outputs
    %i[inspection source base].each do |fault|
      fixture do |root, _item, api, _controller, selection, replies, _reviews|
        Dir.mktmpdir do |dir|
          output = Pathname(dir)/'outputs'
          env = environment(selection).merge('GITHUB_OUTPUT' => output.to_s)
          calls = []
          client = download_client
          download = client.method(:download)
          client.define_singleton_method(:download) do |url, path|
            download.call(url, path)
            replies.values[1]['body'] += ' ' if fault == :source
            api.base = 'f' * 40 if fault == :base
          end
          before = MoonshineCandidate.tree(root)
          stdout, stderr = capture_io do
            assert_equal 1, MoonshinePromotionReport.main(['/usr/bin/tar'], env, api: api, root: root,
              client: client, runner: process_runner(calls, bad: fault == :inspection))
          end
          assert_empty stdout
          refute output.exist?
          assert_includes stderr, 'Promotion refused before write credentials'
          assert_empty api.writes
          assert_equal before, MoonshineCandidate.tree(root)
        end
      end
    end
  end

  def test_read_only_package_gate_exports_bound_scalars_without_rotating_local_recipes
    fixture do |root, _item, api, _controller, selection, _replies, _reviews|
      calls = []
      Dir.mktmpdir do |dir|
        output = Pathname(dir)/'outputs'
        env = environment(selection).merge('GITHUB_OUTPUT' => output.to_s)
        before = MoonshineCandidate.tree(root)
        stdout, stderr = capture_io do
          assert_equal 0, MoonshinePromotionReport.main(['/usr/bin/tar'], env, api: api, root: root,
            client: download_client, runner: process_runner(calls))
        end
        assert_empty stderr
        fields = output.read.lines.to_h { |line| line.chomp.split('=', 2) }
        assert_equal %w[base_sha comment_id comment_sha256 comment_updated_at expected_stable report_sha256 status target], fields.keys.sort
        assert_equal 'eligible', fields['status']
        assert_equal PromotionControllerTest::BASE, fields['base_sha']
        assert_equal selection['target'], fields['target']
        assert_equal selection['report_sha256'], fields['report_sha256']
        assert_equal '91', fields['comment_id']
        result = JSON.parse(stdout)
        assert_equal false, result['publication_enabled']
        assert_equal false, result['native_acceptance_verified']
        assert_equal false, result['packages']['host_installation']
        assert_equal true, result['packages']['contract_compared']
        assert_equal 5, calls.length # Checkout identity and four retained recipe inspections.
        calls.drop(1).each do |args|
          assert args.first.key?('GH_TOKEN')
          assert args.first.key?('MOONSHINE_APP_TOKEN')
          assert_nil args.first['GH_TOKEN']
          assert_nil args.first['MOONSHINE_APP_TOKEN']
        end
        assert_empty api.writes
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end
end

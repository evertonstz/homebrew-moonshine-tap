require_relative 'test_promotion_controller'
require_relative '../tools/check_casks'
require_relative '../tools/check_candidate'
require_relative 'test_promotion_flow'

class StableDeliveryTest < Minitest::Test
  def provenance_api(root, source:, main:, reader: nil, comparison: nil)
    files = MoonshineCandidate.tree(root).map do |name, body|
      {'path' => name, 'type' => 'blob', 'mode' => '100644', 'sha' => MoonshineGitHub.blob(body)}
    end
    responses = {
      '/git/ref/heads/main' => {'object' => {'sha' => main}},
      "/compare/#{source}...#{main}" => {'status' => source == main ? 'identical' : 'ahead', 'merge_base_commit' => {'sha' => source}},
      "/git/commits/#{source}" => {'sha' => source, 'tree' => {'sha' => 'c' * 40}},
      "/git/trees/#{'c' * 40}?recursive=1" => {'truncated' => false, 'tree' => files}
    }
    responses.merge!(comparison || {})
    api = Object.new
    api.define_singleton_method(:call) do |method, path, *args, **options|
      raise 'Unexpected write at provenance boundary' unless method == 'GET'
      suffix = path.delete_prefix('/repos/evertonstz/homebrew-moonshine-tap')
      responses.key?(suffix) ? Marshal.load(Marshal.dump(responses.fetch(suffix))) : reader.call(method, path, *args, **options)
    end
    [api, responses]
  end

  def test_authenticated_same_version_promotion_requires_reviewed_provenance_and_preserves_legacy_token
    native = NativePolicyTest.new('fixture')
    native.fixture do |root, target, evidence|
      stable = MoonshineReleases.current(root)
      origin, reader, _replies = native.owner_source(evidence)
      assessment = MoonshinePromotion.assess(root: root, target: target.identity, expected_stable: stable.identity,
                                             origin: origin, api: reader)
      api, _responses = provenance_api(root, source: 'a' * 40, main: 'b' * 40, reader: reader)
      before = MoonshineCandidate.tree(root)
      error = nil
      begin
        changes = MoonshinePromotion.patch(root: root, target: target.identity, expected_stable: stable.identity,
                                           origin: origin, api: api, report_sha256: assessment.fetch('report_sha256'))
      rescue MoonshineReleases::Failure => caught
        error = caught
      end
      assert_nil error, error&.message
      assert_equal before, MoonshineCandidate.tree(root)
      apply(root, changes)
      assert_equal target.identity, MoonshineReleases.current(root).identity
      assert_equal stable.identity, MoonshineReleases.previous(root).identity
      assert_equal stable.release, MoonshineReleases.current(root).release
      assert_equal ['moonshine', 'moonshine@0.16.1', "moonshine@0.16.1-#{target.identity}", 'moonshine@untested'].sort,
                   MoonshineReleases.tokens(root).sort
      assert MoonshineCask.generate(root: root, check: true)
    end
  end

  def apply(root, changes)
    changes.each do |name, bytes|
      path = root/name
      if bytes
        path.dirname.mkpath
        path.binwrite(bytes)
      else
        path.delete
      end
    end
  end

  def test_second_same_version_fix_rotates_independent_recipes_and_expires_only_offered_legacy_token
    native = NativePolicyTest.new('fixture')
    native.fixture do |root, first, evidence|
      legacy = MoonshineReleases.current(root)
      first_api, _ = provenance_api(root, source: 'a' * 40, main: 'b' * 40)
      apply(root, MoonshinePromotion.projection(root: root, target: first.identity, expected_stable: legacy.identity, api: first_api))
      source = (root/'lib/moonshine_host.rb').read
      replacement = source.sub('MAX_PACKAGE = 128 * 1024 * 1024', 'MAX_PACKAGE = 127 * 1024 * 1024')
      refute_equal source, replacement
      (root/'lib/moonshine_host.rb').write(replacement)
      apply(root, MoonshineCandidates.patch(root: root, release: first.release, source: 'f' * 40, expected_current: first.identity))
      second = MoonshineCandidates.recipe(root)
      refute_equal first.identity, second.identity
      evidence.merge!('recipe_sha256' => second.identity, 'rpm' => second.release,
                      'installed_version' => "0.16.1+#{second.identity}", 'baseline_recipe_sha256' => first.identity)
      origin, reader, _ = native.owner_source(evidence)
      api, _ = provenance_api(root, source: 'f' * 40, main: 'f' * 40, reader: reader,
        comparison: {"/compare/#{'a' * 40}...#{'f' * 40}" => {'status' => 'ahead', 'merge_base_commit' => {'sha' => 'a' * 40}}})
      assessment = MoonshinePromotion.assess(root: root, target: second.identity, expected_stable: first.identity, origin: origin, api: api)
      changes = MoonshinePromotion.patch(root: root, target: second.identity, expected_stable: first.identity,
                                         origin: origin, api: api, report_sha256: assessment.fetch('report_sha256'))
      assert_nil changes.fetch('Casks/moonshine@0.16.1.rb')
      assert_equal first.source, changes.fetch('releases/previous/helper.rb')
      apply(root, changes)
      assert_equal second.identity, MoonshineReleases.current(root).identity
      assert_equal first.identity, MoonshineReleases.previous(root).identity
      assert_equal ["moonshine@0.16.1-#{second.identity}", "moonshine@0.16.1-#{first.identity}"].sort,
                   MoonshineReleases.recipes(root).map { |recipe| MoonshineReleases.exact_token(recipe) }.sort
      assert MoonshineCask.generate(root: root, check: true)
      assert_equal({}, MoonshinePromotion.projection(root: root, target: second.identity, expected_stable: second.identity))
    end
  end

  def test_modern_same_version_promotion_never_accepts_old_unrelated_or_identical_source_history
    %i[behind diverged identical wrong_base].each do |fault|
      NativePolicyTest.new('fixture').fixture do |root, first, _evidence|
        stable = MoonshineReleases.current(root)
        api, _ = provenance_api(root, source: 'a' * 40, main: 'b' * 40)
        apply(root, MoonshinePromotion.projection(root: root, target: first.identity, expected_stable: stable.identity, api: api))
        (root/'lib/moonshine_host.rb').write((root/'lib/moonshine_host.rb').read.sub('MAX_PACKAGE = 128 * 1024 * 1024', 'MAX_PACKAGE = 127 * 1024 * 1024'))
        apply(root, MoonshineCandidates.patch(root: root, release: first.release, source: 'f' * 40, expected_current: first.identity))
        target = MoonshineCandidates.recipe(root)
        comparison = {'status' => fault == :wrong_base ? 'ahead' : fault.to_s,
                      'merge_base_commit' => {'sha' => fault == :wrong_base ? 'b' * 40 : 'a' * 40}}
        api, _ = provenance_api(root, source: 'f' * 40, main: 'f' * 40,
          comparison: {"/compare/#{'a' * 40}...#{'f' * 40}" => comparison})
        before = MoonshineCandidate.tree(root)
        assert_raises(MoonshineReleases::Failure) do
          MoonshinePromotion.projection(root: root, target: target.identity, expected_stable: first.identity, api: api)
        end
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_legacy_provenance_must_bind_complete_frozen_baseline_in_current_reviewed_main_history
    %i[absent truncated digest mode duplicate main_history source_commit].each do |fault|
      NativePolicyTest.new('fixture').fixture do |root, target, _evidence|
        stable = MoonshineReleases.current(root)
        api, responses = provenance_api(root, source: 'a' * 40, main: 'b' * 40)
        tree = responses.fetch("/git/trees/#{'c' * 40}?recursive=1")
        entry = tree['tree'].find { |file| file['path'] == 'releases/stable/helper.rb' }
        case fault
        when :absent then tree['tree'].delete(entry)
        when :truncated then tree['truncated'] = true
        when :digest then entry['sha'] = 'f' * 40
        when :mode then entry['mode'] = '100755'
        when :duplicate then tree['tree'] << entry.dup
        when :main_history then responses.fetch("/compare/#{'a' * 40}...#{'b' * 40}")['status'] = 'diverged'
        when :source_commit then responses.fetch("/git/commits/#{'a' * 40}")['sha'] = 'f' * 40
        end
        before = MoonshineCandidate.tree(root)
        assert_raises(MoonshineReleases::Failure) do
          MoonshinePromotion.projection(root: root, target: target.identity, expected_stable: stable.identity, api: api)
        end
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_delivery_catalog_rejects_wrong_identity_style_source_duplicate_keys_and_float_schema
    %i[identity style source slot legacy_source duplicate schema].each do |fault|
      PromotionControllerTest.new('fixture').fixture do |root, target, _api, _controller, selection, _replies, _reviews|
        apply(root, MoonshinePromotion.projection(root: root, target: target.identity, expected_stable: selection.fetch('expected_stable')))
        path = root/'releases/catalog.json'
        data = JSON.parse(path.read)
        case fault
        when :identity then data['deliveries']['stable']['identity'] = '0' * 64
        when :style then data['deliveries']['stable']['style'] = 'arbitrary'
        when :source then data['deliveries']['stable']['source_sha'] = 'f' * 40
        when :slot then data['deliveries']['foreign'] = data['deliveries']['stable'].dup
        when :legacy_source then data['deliveries']['previous']['source_sha'] = 'a' * 40
        when :schema then data['schema'] = 2.0
        end
        text = JSON.generate(data)
        text = text.sub('"schema":2', '"schema":2,"schema":2') if fault == :duplicate
        path.write(text)
        before = MoonshineCandidate.tree(root)
        assert_raises(MoonshineReleases::Failure) { MoonshineCask.generate(root: root, check: true) }
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_same_version_scalar_gate_publisher_and_exact_head_owner_approved_merge
    native = NativePolicyTest.new('fixture')
    native.fixture do |root, target, evidence|
      stable = MoonshineReleases.current(root)
      origin, reader, replies = native.owner_source(evidence)
      replies.values[1]['issue_url'] = replies.values[1]['issue_url'].sub('/issues/7', '/issues/55')
      pull = replies.delete('/repos/evertonstz/homebrew-moonshine-tap/pulls/7')
      pull['number'] = 55
      replies['/repos/evertonstz/homebrew-moonshine-tap/pulls/55'] = pull
      assessment = MoonshinePromotion.assess(root: root, target: target.identity, expected_stable: stable.identity,
                                             origin: origin, api: reader)
      selection = {'target' => target.identity, 'expected_stable' => stable.identity, 'origin' => origin,
                   'report_sha256' => assessment.fetch('report_sha256')}
      proof, _ = provenance_api(root, source: 'a' * 40, main: 'a' * 40)
      files = MoonshineCandidate.tree(root).transform_values { |bytes| {'sha' => MoonshineGitHub.blob(bytes), 'mode' => '100644'} }
      after = files.dup
      MoonshinePromotion.projection(root: root, target: target.identity, expected_stable: stable.identity, api: proof).each do |name, bytes|
        bytes ? after[name] = {'sha' => MoonshineGitHub.blob(bytes), 'mode' => '100644'} : after.delete(name)
      end
      api = GitHubReleaseTest::FakeAPI.new(files, after, MoonshineGitHub.promotion_manifest('a' * 40, selection))
      api.settings.merge!(replies.values.first)
      reviews = []
      transport = api.method(:call)
      api.define_singleton_method(:call) do |method, path, value = nil, missing: false|
        if method == 'GET' && path.include?('/compare/')
          proof.call(method, path)
        elsif method == 'GET' && path.end_with?('/reviews?per_page=100')
          reviews
        elsif method == 'GET' && (path.end_with?('/issues/comments/91') || path.end_with?('/pulls/55'))
          reader.call(method, path)
        else
          result = transport.call(method, path, value, missing: missing)
          result['sha'] = 'a' * 40 if method == 'GET' && path.end_with?("/git/commits/#{'a' * 40}")
          result
        end
      end
      flow = PromotionFlowTest.new('fixture')
      before = MoonshineCandidate.tree(root)
      flow.checked_fields(root, api, selection) do |fields|
        env = flow.publisher(fields)
        code, stdout, stderr = flow.invoke(root, api, env, 'promote')
        assert_equal 0, code, stderr
        assert_equal 'created', JSON.parse(stdout)['status']
        entries = api.writes.first.last.fetch('tree').to_h { |entry| [entry['path'], entry] }
        assert_includes entries.fetch("Casks/moonshine@0.16.1-#{target.identity}.rb").fetch('content'), "version \"0.16.1+#{target.identity}\""
        PromotionControllerTest.new('approve').approve(replies, reviews)
        code, stdout, stderr = flow.invoke(root, api, env.merge('GITHUB_EVENT_NAME' => 'workflow_run', 'MOONSHINE_CI_RUN_ID' => '101'), 'merge')
        assert_equal 0, code, stderr
        assert_equal 'merged', JSON.parse(stdout)['status']
        assert_equal ['PUT', '/pulls/7/merge', {'sha' => 'b' * 40, 'merge_method' => 'squash'}], api.writes.last
        assert_equal before, MoonshineCandidate.tree(root)
      end
    end
  end

  def test_hosted_private_check_loads_hash_deliveries_and_restores_the_entire_checkout
    NativePolicyTest.new('fixture').fixture do |root, target, _evidence|
      before = MoonshineCandidate.tree(root)
      # A fresh process must load only the shipping tool's own entrypoint.
      # Loading controller test fixtures first would conceal missing requires.
      script = <<~'RUBY'
        require ARGV.fetch(0)
        root = Pathname(ARGV.fetch(1))
        loaded = []
        runner = lambda do |*args|
          if args.first.is_a?(Array)
            command = args.first
            if command[1] == 'readall'
              ['', '', Struct.new(:success?).new(true)]
            else
              token = command.last.delete_prefix('evertonstz/moonshine-tap/')
              body = (root/"Casks/#{token}.rb").read
              data = {'token' => token, 'full_token' => command.last,
                      'version' => body[/^  version "([^"\n]+)"$/, 1], 'sha256' => body[/^  sha256 "([^"\n]+)"$/, 1],
                      'url' => body[/^  url "([^"\n]+)"$/, 1]}
              data['url'] = data['url'].gsub('#{version}', data['version'])
              loaded << token
              [JSON.generate('casks' => [data]), '', Struct.new(:success?).new(true)]
            end
          else
            [JSON.generate('dependencies' => {}, 'inventory' => {}, 'protected' => {}, 'tags' => {}), '', Struct.new(:success?).new(true)]
          end
        end
        client = Object.new
        client.define_singleton_method(:download) { |_url, path| path.binwrite('external package fixture') }
        report = MoonshineCandidateCheck.run(root: root, brew: RbConfig.ruby, tap: 'evertonstz/moonshine-tap',
          bsdtar: '/usr/bin/tar', source: 'b' * 40, runner: runner, client: client)
        puts JSON.generate('report' => report, 'loaded' => loaded)
      RUBY
      output, error, status = Open3.capture3({'RUBYOPT' => nil, 'RUBYLIB' => nil}, RbConfig.ruby, '--disable=rubyopt',
        '-e', script, (root/'tools/check_candidate.rb').to_s, root.to_s)
      assert status.success?, error
      result = JSON.parse(output)
      loaded, report = result.values_at('loaded', 'report')
      assert_includes loaded, "moonshine@0.16.1-#{target.identity}"
      assert_equal false, report.dig('delivery_preview', 'publication_enabled')
      assert_equal false, report.dig('delivery_preview', 'native_acceptance_verified')
      assert_equal false, report.dig('delivery_preview', 'host_installation')
      assert_equal true, report.dig('delivery_preview', 'packages', 'contract_compared')
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_read_only_homebrew_boundary_checks_recipe_qualified_versions_and_numeric_rpm_pins
    PromotionControllerTest.new('fixture').fixture do |root, target, _api, _controller, selection, _replies, _reviews|
      legacy = MoonshineReleases.current(root)
      apply(root, MoonshinePromotion.projection(root: root, target: target.identity, expected_stable: selection.fetch('expected_stable')))
      entries = {'moonshine' => [target, "0.16.2+#{target.identity}"],
                 "moonshine@0.16.2-#{target.identity}" => [target, "0.16.2+#{target.identity}"],
                 'moonshine@0.16.1' => [legacy, '0.16.1'], 'moonshine@untested' => [target, "0.16.2+#{target.identity}"]}
      calls = []
      runner = lambda do |args|
        calls << args
        if args[1] == 'readall'
          ['', '', Struct.new(:success?).new(true)]
        else
          token = args.last.delete_prefix('evertonstz/moonshine-tap/')
          recipe, version = entries.fetch(token)
          data = {'token' => token, 'full_token' => args.last, 'version' => version,
                  'sha256' => recipe.release['sha256'], 'url' => "https://github.com/hgaiser/moonshine/releases/download/v#{recipe.release['version']}/#{recipe.release['filename']}"}
          [JSON.generate('casks' => [data]), '', Struct.new(:success?).new(true)]
        end
      end
      error = nil
      begin
        report = MoonshineCaskCheck.run(root: root, brew: RbConfig.ruby, tap: 'evertonstz/moonshine-tap', runner: runner, euid: 1000)
      rescue StandardError => caught
        error = caught
      end
      assert_nil error, error&.message
      assert_equal entries.keys.sort, report.fetch('tokens_loaded').sort
      assert_equal false, report.fetch('host_installation')
      assert_equal 5, calls.length
    end
  end

  def test_committed_delivery_is_loadable_without_changing_recipe_identity_or_candidate_selection
    PromotionControllerTest.new('fixture').fixture do |root, target, _api, _controller, selection, _replies, _reviews|
      stable = MoonshineReleases.current(root)
      candidates = MoonshineCandidates.catalog(root)
      apply(root, MoonshinePromotion.projection(root: root, target: target.identity,
                                               expected_stable: stable.identity))
      assert_equal target.identity, MoonshineReleases.current(root).identity
      assert_equal stable.identity, MoonshineReleases.previous(root).identity
      assert_equal candidates, MoonshineCandidates.catalog(root)
      outputs = MoonshineCask.generate(root: root, check: true)
      assert_equal ['Casks/moonshine.rb', 'Casks/moonshine@0.16.1.rb',
                    "Casks/moonshine@0.16.2-#{target.identity}.rb", 'Casks/moonshine@untested.rb'].sort, outputs.keys.sort
      before = MoonshineCandidate.tree(root)
      assert_equal({}, MoonshinePromotion.projection(root: root, target: target.identity,
                                                     expected_stable: target.identity))
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end

  def test_new_protected_delivery_uses_full_recipe_version_and_preserves_legacy_predecessor
    PromotionControllerTest.new('fixture').fixture do |root, target, _api, _controller, selection, _replies, _reviews|
      before = MoonshineCandidate.tree(root)
      legacy = before.fetch('Casks/moonshine@0.16.1.rb')
      patch = MoonshinePromotion.projection(root: root, target: target.identity,
                                            expected_stable: selection.fetch('expected_stable'))
      assert_equal "  version \"0.16.2+#{target.identity}\"\n",
                   patch.fetch('Casks/moonshine.rb').lines.find { |line| line.start_with?('  version ') }
      exact = patch.fetch("Casks/moonshine@0.16.2-#{target.identity}.rb")
      assert_includes exact, "  version \"0.16.2+#{target.identity}\"\n"
      assert_includes exact, 'https://github.com/hgaiser/moonshine/releases/download/v0.16.2/moonshine-0.16.2-1.x86_64.rpm'
      refute patch.key?('Casks/moonshine@0.16.2.rb')
      if (updated = patch['Casks/moonshine@0.16.1.rb'])
        normalize = ->(body) { body.lines.reject { |line| line.start_with?('  conflicts_with ') }.join }
        assert_equal normalize.call(legacy), normalize.call(updated)
      end
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end
end

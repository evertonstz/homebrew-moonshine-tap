# Exact retained-candidate projection. Positive publication requires a protected publisher.
require_relative 'native_origin'

module MoonshinePromotion
  extend self

  def snapshot(slot, recipe)
    fields = MoonshineReleases.recipe_fields(recipe.release, recipe.source, recipe.scripts, recipe.template, approvals: recipe.approvals)
    MoonshineReleases.check(MoonshineReleases.recipe_digest(fields) == recipe.identity, 'Promotion recipe identity differs')
    prefix = "releases/#{slot}"
    result = {"#{prefix}/helper.rb" => recipe.source, "#{prefix}/cask.rb" => recipe.template,
              "#{prefix}/release.json" => JSON.pretty_generate(fields.merge('recipe_sha256' => recipe.identity)) + "\n"}
    recipe.scripts&.each { |name, body| result["#{prefix}/#{name}.sh"] = body + "\n" }
    result
  end

  def ancestry!(api, ancestor, descendant, strict: false)
    MoonshineCandidates.source_sha(ancestor)
    MoonshineCandidates.source_sha(descendant)
    data = api.call('GET', "/repos/#{MoonshineGitHub::REPOSITORY}/compare/#{ancestor}...#{descendant}")
    statuses = strict ? ['ahead'] : %w[ahead identical]
    MoonshineReleases.check(data.is_a?(Hash) && statuses.include?(data['status']) &&
      data.dig('merge_base_commit', 'sha') == ancestor, 'Same-version stable source is not forward reviewed-main history')
  end

  def same_version_source!(root, stable, source, api)
    MoonshineReleases.check(api, 'Same-version stable delivery requires checked provenance')
    prefix = "/repos/#{MoonshineGitHub::REPOSITORY}"
    main = api.call('GET', prefix + '/git/ref/heads/main').dig('object', 'sha')
    ancestry!(api, source, main)
    if stable.delivery&.fetch('style') == 'recipe'
      ancestry!(api, stable.delivery.fetch('source_sha'), source, strict: true)
    else
      # A legacy seed has no invented Git provenance. Its exact frozen stable snapshot
      # must already exist in the target's reviewed-main source tree.
      commit = api.call('GET', prefix + "/git/commits/#{source}")
      MoonshineReleases.check(commit.is_a?(Hash) && commit['sha'] == source, 'Legacy baseline source commit differs')
      tree = api.call('GET', prefix + "/git/trees/#{MoonshineGitHub.sha(commit.dig('tree', 'sha'))}?recursive=1")
      MoonshineReleases.check(tree.is_a?(Hash) && tree['truncated'] == false && tree['tree'].is_a?(Array) &&
        tree['tree'].length <= 1000, 'Legacy baseline source tree is incomplete')
      paths = tree['tree'].map { |entry| entry.is_a?(Hash) && entry['path'] }
      MoonshineReleases.check(paths.all? { |path| path.is_a?(String) } && paths.uniq == paths,
                              'Legacy baseline source tree has duplicate or invalid paths')
      baseline = MoonshineCandidate.tree(root).select { |name, _| name.start_with?('releases/stable/') }
      entries = tree['tree'].select { |entry| entry['path'].start_with?('releases/stable/') && entry['type'] != 'tree' }
      MoonshineReleases.check(entries.length == baseline.length && entries.all? do |entry|
        bytes = baseline[entry['path']]
        bytes && entry['type'] == 'blob' && entry['mode'] == '100644' && entry['sha'] == MoonshineGitHub.blob(bytes)
      end, 'Legacy accepted baseline is not present in reviewed candidate source')
    end
  end

  # Preview only. Does not approve evidence, write files, publish a PR or rotate installed hosts.
  def projection(root:, target:, expected_stable:, api: nil)
    MoonshineCask.generate(root: root, check: true)
    stable = MoonshineReleases.current(root)
    MoonshineReleases.check(stable.identity == expected_stable, 'Accepted recipe changed; fresh promotion review required')
    candidate = MoonshineCandidates.recipe(root, target)
    MoonshineReleases.check(candidate && candidate.identity == target, 'Exact retained promotion target is missing')
    return {} if stable.identity == candidate.identity
    order = MoonshineReleases.version(candidate.release['version']) <=> MoonshineReleases.version(stable.release['version'])
    MoonshineReleases.check(order >= 0, 'Backwards stable replacement is not permitted')
    record = MoonshineCandidates.catalog(root)['history'].find { |item| item['identity'] == target }
    same_version_source!(root, stable, record.fetch('source_sha'), api) if order == 0
    delivery = {'style' => 'recipe', 'identity' => candidate.identity, 'source_sha' => record.fetch('source_sha')}
    candidate = MoonshineReleases::Recipe.new(**candidate.to_h, delivery: delivery.freeze).freeze
    previous_delivery = stable.delivery || {'style' => 'legacy', 'identity' => stable.identity, 'source_sha' => nil}
    before = MoonshineCandidate.tree(root)
    accepted_paths = MoonshineReleases.tokens(root).reject { |token| token == 'moonshine@untested' }.map { |token| "Casks/#{token}.rb" }
    after = before.reject { |name, _| name.start_with?('releases/stable/', 'releases/previous/') || accepted_paths.include?(name) }
    after.merge!(snapshot('stable', candidate)).merge!(snapshot('previous', stable))
    after['releases/catalog.json'] = JSON.pretty_generate('schema' => 2, 'stable' => 'stable', 'previous' => 'previous',
      'deliveries' => {'stable' => delivery, 'previous' => previous_delivery}) + "\n"
    untested = MoonshineCandidates.recipe(root)
    tokens = ['moonshine', MoonshineReleases.exact_token(candidate), MoonshineReleases.exact_token(stable), *('moonshine@untested' if untested)]
    tokens.each do |token|
      item = token == 'moonshine@untested' ? untested : token == MoonshineReleases.exact_token(stable) ? stable : candidate
      after["Casks/#{token}.rb"] = MoonshineCask.render(recipe: item, token: token, tokens: tokens, root: root)
    end
    (before.keys | after.keys).sort.filter_map { |name| [name, after[name]] unless before[name] == after[name] }.to_h
  end

  def assess(root:, target:, expected_stable:, evidence: nil, origin: nil, api: nil)
    MoonshineReleases.check(origin.nil? || evidence.nil?, 'Cannot mix local claims with an authenticated report origin')
    if origin
      MoonshineNativeOrigin.assess(root: root, target: target, expected_stable: expected_stable, origin: origin, api: api)
    else
      MoonshineNativeEvidence.assess(root: root, target: target, expected_stable: expected_stable, evidence: evidence)
                            .merge('owner_report_authenticated' => false)
    end
  end

  def patch(root:, target:, expected_stable:, evidence: nil, origin: nil, api: nil, report_sha256: nil)
    result = assess(root: root, target: target, expected_stable: expected_stable, evidence: evidence, origin: origin, api: api)
    MoonshineReleases.check(result['owner_report_authenticated'] == true && report_sha256,
                            'Protected promotion requires authenticated source and report digest; report matching cannot authorize publication')
    MoonshineNativeEvidence.digest(report_sha256, 'Invalid bound native report digest')
    MoonshineReleases.check(result['report_sha256'] == report_sha256, 'Native report digest changed; fresh promotion review required')
    # Reconstruct data only. The controller still requires protection, CI and exact-head owner approval.
    projection(root: root, target: target, expected_stable: expected_stable, api: api)
  end
end

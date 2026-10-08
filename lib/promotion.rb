# Exact retained-candidate projection. Positive publication stays disabled until native policy exists.
require_relative 'release_candidate'

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

  # Preview only. Does not approve evidence, write files, publish a PR or rotate installed hosts.
  def projection(root:, target:, expected_stable:)
    MoonshineCask.generate(root: root, check: true)
    stable = MoonshineReleases.current(root)
    MoonshineReleases.check(stable.identity == expected_stable, 'Accepted recipe changed; fresh promotion review required')
    candidate = MoonshineCandidates.recipe(root, target)
    MoonshineReleases.check(candidate && candidate.identity == target, 'Exact retained promotion target is missing')
    return {} if stable.identity == candidate.identity
    MoonshineReleases.check((MoonshineReleases.version(candidate.release['version']) <=> MoonshineReleases.version(stable.release['version'])) == 1,
                            'Same-version or backwards stable replacement requires an explicit delivery policy')
    before = MoonshineCandidate.tree(root)
    after = before.reject { |name, _| name.start_with?('releases/stable/', 'releases/previous/') || name.match?(%r{\ACasks/moonshine(?:@[0-9.]+)?\.rb\z}) }
    after.merge!(snapshot('stable', candidate)).merge!(snapshot('previous', stable))
    after['releases/catalog.json'] = JSON.pretty_generate('schema' => 1, 'stable' => 'stable', 'previous' => 'previous') + "\n"
    untested = MoonshineCandidates.recipe(root)
    tokens = ['moonshine', "moonshine@#{candidate.release['version']}", "moonshine@#{stable.release['version']}", *('moonshine@untested' if untested)]
    tokens.each do |token|
      item = token == 'moonshine@untested' ? untested : token == "moonshine@#{stable.release['version']}" ? stable : candidate
      after["Casks/#{token}.rb"] = MoonshineCask.render(recipe: item, token: token, tokens: tokens, root: root)
    end
    (before.keys | after.keys).sort.filter_map { |name| [name, after[name]] unless before[name] == after[name] }.to_h
  end

  def patch(root:, target:, expected_stable:, evidence:)
    # Fail before any projection/publication. Approval never manufactures native acceptance.
    policy = JSON.parse(MoonshineReleases.read_file(Pathname(root)/'reference/native-policy.json', 8192), max_nesting: 10)
    MoonshineReleases.check(policy.is_a?(Hash) && policy.keys.sort == %w[reason schema state] &&
                            policy['schema'].is_a?(Integer) && policy['schema'] == 1 && policy['state'] == 'unconfigured',
                            'Unsupported native evidence policy; owner policy review required')
    raise MoonshineReleases::Failure, 'Native evidence policy is not configured; stable promotion is disabled'
  end
end

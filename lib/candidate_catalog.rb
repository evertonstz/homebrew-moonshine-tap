# Immutable candidate payloads and compact selection history. No helper execution here.
require_relative 'release_catalog'

module MoonshineCandidates
  extend self
  MAX_CATALOG = 1024 * 1024
  MAX_HISTORY = 4096
  KEYS = %w[current history previous schema selections].freeze

  def check(value, message)
    MoonshineReleases.check(value, message)
  end

  def identity(value)
    check(value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/), 'Invalid candidate recipe identity')
    value
  end

  def source_sha(value)
    check(value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/), 'Invalid candidate source commit')
    value
  end

  def empty
    {'schema' => 1, 'current' => nil, 'previous' => nil, 'history' => [], 'selections' => []}
  end

  def catalog(root)
    parent = Pathname(root)/'releases/candidates'
    return empty unless parent.exist? || parent.symlink?
    check(parent.directory? && !parent.symlink?, 'Unsafe candidate catalog directory')
    data = JSON.parse(MoonshineReleases.read_file(parent/'catalog.json', MAX_CATALOG), max_nesting: 12)
    check(data.is_a?(Hash) && data.keys.sort == KEYS && data['schema'].is_a?(Integer) && data['schema'] == 1,
          'Unsupported candidate catalog schema')
    %w[current previous].each { |key| identity(data[key]) if data[key] }
    check(data['current'] || data['previous'].nil?, 'Candidate predecessor has no current selection')
    check(!data['previous'] || data['previous'] != data['current'], 'Duplicate retained candidate selection')
    history, selections = data.values_at('history', 'selections')
    check(history.is_a?(Array) && selections.is_a?(Array) && history.length <= MAX_HISTORY && selections.length <= MAX_HISTORY,
          'Candidate history exceeds its checked bound; owner review required')
    ids = history.map do |record|
      check(record.is_a?(Hash) && record.keys.sort == %w[identity release source_sha], 'Invalid candidate identity record')
      identity(record['identity'])
      source_sha(record['source_sha'])
      MoonshineReleases.metadata(record['release'])
      record['identity']
    end
    check(ids.uniq == ids, 'Duplicate candidate identity record')
    cursor = nil
    prior = nil
    seen = {}
    selections.each do |selection|
      check(selection.is_a?(Hash) && selection.keys.sort == %w[from operation reason to] &&
            selection['from'] == cursor && ids.include?(selection['to']) && selection['to'] != cursor &&
            %w[forward rollback].include?(selection['operation']), 'Invalid candidate selection chain')
      if selection['operation'] == 'forward'
        check(selection['reason'].nil? && !seen[selection['to']],
              'Automatic reselection of superseded candidate')
      else
        reason!(selection['reason'])
      end
      seen[selection['to']] = true
      prior, cursor = cursor, selection['to']
    end
    check(cursor == data['current'] && prior == data['previous'], 'Candidate pointers differ from selection history')
    retained = data.values_at('current', 'previous').compact
    check(parent.children.map { |path| path.basename.to_s }.sort == ['catalog.json', *retained].sort,
          'Unexpected or expired candidate payloads')
    retained.each do |id|
      record = history.find { |item| item['identity'] == id }
      check(record, 'Retained candidate identity record is missing')
      recipe = MoonshineReleases.load_snapshot(parent/id, 'Candidate')
      check(recipe.identity == id && recipe.release == MoonshineReleases.metadata(record['release']) && recipe.approvals,
            'Candidate payload and recorded identity differ')
      url = "https://github.com/hgaiser/moonshine/releases/download/v#{recipe.release['version']}/#{recipe.release['filename']}"
      check(recipe.template.include?("  url \"#{url}\"\n"), 'Candidate RPM URL is not independently pinned')
    end
    data
  rescue JSON::ParserError => e
    raise MoonshineReleases::Failure, "Invalid candidate catalog: #{e.message}"
  end

  def recipe(root, id = nil)
    data = catalog(root)
    id ||= data['current']
    return nil unless id
    identity(id)
    check(data.values_at('current', 'previous').include?(id), 'Candidate target expired or was never retained')
    MoonshineReleases.load_snapshot(Pathname(root)/'releases/candidates'/id, 'Candidate')
  end

  def retained(root)
    data = catalog(root)
    data.values_at('current', 'previous').compact.map { |id| recipe(root, id) }
  end

  def build(root, release)
    release = MoonshineReleases.metadata(release)
    development = MoonshineReleases.development(root)
    source = development.source.sub(/^  RELEASE = [^\n]+\.freeze$/) { "  RELEASE = #{release.inspect}.freeze" }
    fresh = MoonshineReleases::Recipe.new(release: release, source: source.freeze, approvals: development.approvals).freeze
    text = MoonshineCask.render(recipe: fresh, token: 'moonshine', tokens: %w[moonshine moonshine@untested], root: root)
    text = text.sub(/^  url [^\n]+$/) { "  url \"https://github.com/hgaiser/moonshine/releases/download/v#{release['version']}/#{release['filename']}\"" }
    template = text.sub('cask "moonshine" do', 'cask "__MOONSHINE_TOKEN__" do')
      .sub("  version #{release['version'].inspect}", '  version "__MOONSHINE_VERSION__"')
      .sub(/^  conflicts_with cask: \[[^\n]*\]$/, '  conflicts_with cask: [__MOONSHINE_CONFLICTS__]')
      .sub('"evertonstz/moonshine-tap/moonshine"', '"evertonstz/moonshine-tap/__MOONSHINE_TOKEN__"')
    MoonshineReleases.validate_template(template, release, source)
    fields = MoonshineReleases.recipe_fields(release, source, nil, template, approvals: fresh.approvals)
    MoonshineReleases::Recipe.new(release: release, source: source, approvals: fresh.approvals,
      template: template.freeze, identity: MoonshineReleases.recipe_digest(fields).freeze).freeze
  end

  def payload(recipe)
    identity(recipe.identity)
    fields = MoonshineReleases.recipe_fields(recipe.release, recipe.source, nil, recipe.template, approvals: recipe.approvals)
    check(MoonshineReleases.recipe_digest(fields) == recipe.identity, 'Candidate recipe identity differs')
    prefix = "releases/candidates/#{recipe.identity}"
    {"#{prefix}/helper.rb" => recipe.source, "#{prefix}/cask.rb" => recipe.template,
     "#{prefix}/release.json" => JSON.pretty_generate(fields.merge('recipe_sha256' => recipe.identity)) + "\n"}
  end

  def reason!(value)
    check(value.is_a?(String) && value.bytesize.between?(1, 500) && !value.strip.empty? && !value.match?(/[\x00-\x1f\x7f]/),
          'Rollback requires a bounded owner reason')
  end

  # Ancestry and owner approval are checked by the protected GitHub controller.
  # This function reconstructs bytes only; it never approves or merges a selection.
  def patch(root:, release:, source:, expected_current:, operation: 'forward', target: nil, reason: nil)
    source_sha(source)
    check(%w[forward rollback].include?(operation), 'Unsupported candidate selection operation')
    check(MoonshineReleases.snapshot_directories(root)[:stable], 'Candidate publication requires independent accepted snapshots')
    before = MoonshineCandidate.tree(root)
    MoonshineCask.generate(root: root, check: true)
    data = catalog(root)
    check(data['current'] == expected_current, 'Candidate selection changed; fresh validation required')
    if operation == 'rollback'
      reason!(reason)
      selected = recipe(root, identity(target))
      check(selected.release == MoonshineReleases.metadata(release), 'Rollback target RPM identity differs')
    else
      check(target.nil? && reason.nil?, 'Automatic candidate selection cannot supply rollback inputs')
      selected = build(root, release)
    end
    return {} if selected.identity == data['current']
    if operation == 'forward'
      check(data['history'].none? { |record| record['identity'] == selected.identity }, 'Superseded recipe requires owner-approved reselection')
      baseline = data['history'].find { |record| record['identity'] == data['current'] }&.fetch('release') || MoonshineReleases.current(root).release
      check((MoonshineReleases.version(selected.release['version']) <=> MoonshineReleases.version(baseline['version'])) >= 0,
            'Automatic candidate selection would move backwards')
      current_record = data['history'].find { |record| record['identity'] == data['current'] }
      check(!current_record || current_record['source_sha'] != source || current_record['release']['version'] != selected.release['version'],
            'Same-version candidate progress requires a new reviewed main source')
      data['history'] << {'identity' => selected.identity, 'release' => selected.release, 'source_sha' => source}
    end
    data['selections'] << {'from' => data['current'], 'to' => selected.identity, 'operation' => operation, 'reason' => reason}
    data['previous'], data['current'] = data['current'], selected.identity
    check(data['history'].length <= MAX_HISTORY && data['selections'].length <= MAX_HISTORY, 'Candidate history bound reached; owner review required')
    after = before.merge(payload(selected))
    kept = data.values_at('current', 'previous').compact
    after.keys.grep(%r{\Areleases/candidates/[0-9a-f]{64}/}).each do |name|
      after.delete(name) unless kept.include?(name.split('/')[2])
    end
    serialized = JSON.pretty_generate(data) + "\n"
    check(serialized.bytesize <= MAX_CATALOG, 'Candidate catalog exceeds bound')
    after['releases/candidates/catalog.json'] = serialized
    accepted = MoonshineReleases.recipes(root)
    tokens = ['moonshine', *accepted.map { |item| MoonshineReleases.exact_token(item) }, 'moonshine@untested']
    tokens.each do |token|
      item = token == 'moonshine@untested' ? selected : token == 'moonshine' ? accepted.first : accepted.find { |entry| token == MoonshineReleases.exact_token(entry) }
      after["Casks/#{token}.rb"] = MoonshineCask.render(recipe: item, token: token, tokens: tokens, root: root)
    end
    (before.keys | after.keys).sort.filter_map { |name| [name, after[name]] unless before[name] == after[name] }.to_h
  end
end

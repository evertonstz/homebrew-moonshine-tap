# Release inputs are trusted tap source. Never load helpers obtained from release assets or PR artifacts.
require 'json'
require 'digest'
require 'pathname'
require 'open3'
require 'rbconfig'
require 'fileutils'

module MoonshineReleases
  extend self
  class Failure < StandardError; end
  Recipe = Struct.new(:release, :source, :scripts, :template, :identity, :helper_path, :approvals, :delivery, keyword_init: true)
  MAX_SOURCE = 256 * 1024
  MAX_TEMPLATE = 1024 * 1024
  MAX_REFERENCE = 64 * 1024
  METADATA_KEYS = %w[filename sha256 version].freeze
  SNAPSHOT_FILES = %w[helper.rb postinstall.sh postremove.sh release.json].freeze
  COMPLETE_FILES = (SNAPSHOT_FILES + ['cask.rb']).sort.freeze
  TEMPLATE_MARKERS = {'__MOONSHINE_TOKEN__' => 2, '__MOONSHINE_VERSION__' => 1,
                      '__MOONSHINE_CONFLICTS__' => 1}.freeze
  DESCRIBE = <<~'RUBY'.freeze
    require 'json'
    data = {'release' => MoonshineHost::RELEASE}
    if MoonshineHost.const_defined?(:APPROVED_SCRIPTLETS)
      data['approvals'] = MoonshineHost::APPROVED_SCRIPTLETS
    else
      data['scripts'] = MoonshineHost::REVIEWED_SCRIPTS
    end
    puts JSON.generate(data)
  RUBY

  def check(condition, message)
    raise Failure, message unless condition
  end

  def version(value)
    check(value.is_a?(String) && value.match?(/\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/) && value.bytesize <= 32,
          'Release version must be a numeric MAJOR.MINOR.PATCH value')
    value.split('.').map(&:to_i)
  end

  def metadata(value)
    check(value.is_a?(Hash) && value.keys.sort == METADATA_KEYS, 'Unexpected release metadata fields')
    version(value['version'])
    check(value['sha256'].is_a?(String) && value['sha256'].match?(/\A[0-9a-f]{64}\z/), 'Invalid release SHA-256')
    check(value['filename'] == "moonshine-#{value['version']}-1.x86_64.rpm", 'Unsupported RPM filename or revision')
    METADATA_KEYS.to_h { |key| [key, value.fetch(key).dup.freeze] }.freeze
  end

  def read_file(path, limit)
    path = Pathname(path)
    check(path.file? && !path.symlink? && path.size <= limit, "Missing or unsafe release input: #{path}")
    text = path.read
    check(text.valid_encoding?, "Invalid release input encoding: #{path}")
    text
  end

  def load_recipe(helper, references)
    source = read_file(helper, MAX_SOURCE)
    output, error, status = Open3.capture3({'RUBYOPT' => nil, 'RUBYLIB' => nil, 'GITHUB_TOKEN' => nil, 'MOONSHINE_APP_TOKEN' => nil},
                                         RbConfig.ruby, '--disable=rubyopt', '-r', File.expand_path(helper), '-e', DESCRIBE)
    check(status.success? && output.bytesize <= MAX_SOURCE, "Cannot describe release helper: #{error.strip}")
    data = JSON.parse(output, max_nesting: 10)
    release = metadata(data.fetch('release'))
    if data.key?('approvals')
      approved = approvals(data['approvals'])
      if (Pathname(references)/'scriptlets.json').file?
        check(read_approvals(references) == approved, 'Approved scriptlet reference drift')
        return Recipe.new(release: release, source: source.freeze, approvals: approved,
                          helper_path: Pathname(helper).expand_path.freeze).freeze
      end
      scripts = %w[postinstall postremove].to_h { |name| [name, read_file(Pathname(references)/"#{name}.sh", MAX_REFERENCE).sub(/\n+\z/, '')] }
      check(scripts.all? { |name, body| Digest::SHA256.hexdigest(body) == approved[name]['sha256'] }, 'Approved scriptlet reference drift')
    else
      scripts = data.fetch('scripts')
    end
    check(scripts.is_a?(Hash) && scripts.keys.sort == %w[postinstall postremove], 'Unexpected reviewed scriptlet set')
    scripts.each do |name, body|
      check(body.is_a?(String) && body.bytesize <= MAX_REFERENCE, 'Invalid reviewed scriptlet body')
      reference = read_file(Pathname(references)/"#{name}.sh", MAX_REFERENCE).sub(/\n+\z/, '')
      check(reference == body, "Reviewed scriptlet reference drift: #{name}")
    end
    Recipe.new(release: release, source: source.freeze, scripts: scripts.freeze,
               helper_path: Pathname(helper).expand_path.freeze).freeze
  rescue JSON::ParserError, KeyError => e
    raise Failure, "Invalid release helper metadata: #{e.message}"
  end

  def snapshot_directories(root)
    parent = Pathname(root)/'releases'
    return {stable: nil, previous: nil} unless parent.exist? || parent.symlink?
    check(parent.directory? && !parent.symlink?, 'Unexpected release-snapshot directory')
    names = parent.children.map { |path| path.basename.to_s }.sort
    if names == ['previous']
      return {stable: nil, previous: parent/'previous'}
    end
    data = catalog_data(root)
    expected = ['catalog.json', 'stable', *('previous' if data['previous']), *('candidates' if (parent/'candidates').exist? || (parent/'candidates').symlink?)].sort
    check(names == expected, 'Unexpected release-snapshot directory')
    {stable: parent/'stable', previous: (parent/'previous' if data['previous'])}
  rescue JSON::ParserError => e
    raise Failure, "Invalid release catalog: #{e.message}"
  end

  def catalog_data(root)
    data = JSON.parse(read_file(Pathname(root)/'releases/catalog.json', 8192), max_nesting: 10,
                      allow_duplicate_key: false, create_additions: false)
    check(data.is_a?(Hash) && data['schema'].is_a?(Integer) && [1, 2].include?(data['schema']) &&
          data.keys.sort == (data['schema'] == 1 ? %w[previous schema stable] : %w[deliveries previous schema stable]) &&
          data['stable'] == 'stable' && [nil, 'previous'].include?(data['previous']), 'Unsupported release catalog schema')
    if data['schema'] == 2
      entries = data['deliveries']
      check(entries.is_a?(Hash) && entries.keys.sort == ['stable', *('previous' if data['previous'])].sort,
            'Unexpected accepted delivery slots')
      entries.each_value do |entry|
        check(entry.is_a?(Hash) && entry.keys.sort == %w[identity source_sha style] &&
              %w[legacy recipe].include?(entry['style']), 'Unexpected accepted delivery fields')
        MoonshineCandidates.identity(entry['identity'])
        entry['style'] == 'legacy' ? check(entry['source_sha'].nil?, 'Legacy delivery cannot invent provenance') :
          MoonshineCandidates.source_sha(entry['source_sha'])
      end
    end
    data
  rescue JSON::ParserError
    raise Failure, 'Invalid release catalog'
  end

  def accepted_delivery(root, recipe, slot)
    data = catalog_data(root)
    return recipe if data['schema'] == 1
    delivery = data['deliveries'].fetch(slot)
    check(delivery['identity'] == recipe.identity, 'Accepted delivery recipe identity differs')
    if delivery['style'] == 'recipe'
      record = MoonshineCandidates.catalog(root)['history'].find { |item| item['identity'] == recipe.identity }
      check(record && record['source_sha'] == delivery['source_sha'] && metadata(record['release']) == recipe.release,
            'Accepted delivery provenance differs from reviewed candidate history')
      url = "https://github.com/hgaiser/moonshine/releases/download/v#{recipe.release['version']}/#{recipe.release['filename']}"
      check(recipe.template.include?("  url \"#{url}\"\n"), 'Accepted delivery must pin its upstream URL independently')
    end
    Recipe.new(**recipe.to_h, delivery: delivery.transform_values { |value| value&.dup&.freeze }.freeze).freeze
  end

  def exact_token(recipe)
    suffix = recipe.delivery&.fetch('style') == 'recipe' ? "-#{recipe.identity}" : ''
    "moonshine@#{recipe.release['version']}#{suffix}"
  end

  def recipe_fields(release, source, scripts, template, approvals: nil)
    if approvals
      return {'schema' => 3, 'release' => metadata(release), 'helper_sha256' => Digest::SHA256.hexdigest(source),
              'template_sha256' => Digest::SHA256.hexdigest(template), 'approvals' => self.approvals(approvals)}
    end
    {'schema' => 2, 'release' => metadata(release),
     'helper_sha256' => Digest::SHA256.hexdigest(source),
     'template_sha256' => Digest::SHA256.hexdigest(template),
     'script_sha256' => scripts.sort.to_h.transform_values { |body| Digest::SHA256.hexdigest(body.sub(/\n+\z/, '')) }}
  end

  def recipe_digest(fields)
    Digest::SHA256.hexdigest(JSON.generate(fields.sort.to_h))
  end

  def source_release(source)
    literal_object(source, 'RELEASE').then { |value| metadata(value) }
  end

  def literal_object(source, name)
    declarations = source.scan(/^  #{Regexp.escape(name)} = (\{[^\n]+\})\.freeze$/).flatten
    check(declarations.length == 1, 'Cannot identify the single release metadata declaration')
    JSON.parse(declarations.first.gsub("'", '"').gsub(/\s*=>\s*/, ':'))
  rescue JSON::ParserError => e
    raise Failure, "Nonliteral release declaration: #{e.message}"
  end

  def validate_template(template, release, source)
    check(template.scan(/__MOONSHINE_[A-Z_]+__/).tally == TEMPLATE_MARKERS, 'Invalid frozen cask template markers')
    check(template.include?('cask "__MOONSHINE_TOKEN__" do') &&
          template.include?('  version "__MOONSHINE_VERSION__"') &&
          template.include?("  sha256 #{release['sha256'].inspect}"), 'Frozen cask template identity differs')
    url = "https://github.com/hgaiser/moonshine/releases/download/v#{release['version']}/#{release['filename']}"
    legacy_url = "https://github.com/hgaiser/moonshine/releases/download/v\#{version}/#{release['filename']}"
    check([url, legacy_url].any? { |value| template.include?("  url \"#{value}\"\n") },
          'Frozen cask template RPM URL differs')
    embedded = source.lines.map { |line| line.strip.empty? ? "\n" : '    ' + line }.join
    check(template.include?("  generated_script \"moonshine-host.rb\", content: <<~'MOONSHINE_RUBY'\n#{embedded}  MOONSHINE_RUBY\n"),
          'Frozen cask helper differs from snapshot')
    check(template.scan(/^  generated_script "moonshine-token-guard.rb", content: <<~'MOONSHINE_GUARD'$/).length == 1,
          'Frozen cask token guard is missing or ambiguous')
  end

  def load_snapshot(dir, label)
    check(dir.directory? && !dir.symlink?, "Unsafe #{label.downcase}-release snapshot directory")
    manifest = JSON.parse(read_file(dir/'release.json', 8192), max_nesting: 10)
    check(manifest.is_a?(Hash) && manifest['schema'].is_a?(Integer) && [1, 2, 3].include?(manifest['schema']),
          'Unsupported release snapshot schema')
    files = {1 => SNAPSHOT_FILES, 2 => COMPLETE_FILES, 3 => %w[cask.rb helper.rb release.json]}.fetch(manifest['schema'])
    check(dir.children.map { |path| path.basename.to_s }.sort == files,
          "Unexpected #{label.downcase}-release snapshot files")
    keys = {1 => %w[helper_sha256 release schema],
            2 => %w[helper_sha256 recipe_sha256 release schema script_sha256 template_sha256],
            3 => %w[approvals helper_sha256 recipe_sha256 release schema template_sha256]}.fetch(manifest['schema'])
    check(manifest.keys.sort == keys, 'Unsupported release snapshot fields')
    expected = metadata(manifest['release'])
    source = read_file(dir/'helper.rb', MAX_SOURCE)
    check(manifest['helper_sha256'] == Digest::SHA256.hexdigest(source), "#{label} helper snapshot digest differs")
    if manifest['schema'] == 1
      recipe = load_recipe(dir/'helper.rb', dir)
      check(expected == recipe.release, "#{label} helper and release identity differ")
      return recipe
    end
    check(source_release(source) == expected, "#{label} helper and release identity differ")
    if manifest['schema'] == 3
      approved = approvals(manifest['approvals'])
      check(approvals(literal_object(source, 'APPROVED_SCRIPTLETS')) == approved, 'Helper scriptlet approvals differ')
      scripts = nil
    else
      scripts = %w[postinstall postremove].to_h { |name| [name, read_file(dir/"#{name}.sh", MAX_REFERENCE).sub(/\n+\z/, '').freeze] }.freeze
    end
    template = read_file(dir/'cask.rb', MAX_TEMPLATE)
    fields = recipe_fields(expected, source, scripts, template, approvals: approved)
    check(manifest.reject { |key, _| key == 'recipe_sha256' } == fields, 'Frozen recipe input digests differ')
    identity = recipe_digest(fields)
    check(manifest['recipe_sha256'] == identity, 'Frozen recipe identity differs')
    validate_template(template, expected, source)
    Recipe.new(release: expected, source: source.freeze, scripts: scripts, template: template.freeze,
               identity: identity.freeze, helper_path: (dir/'helper.rb').expand_path.freeze, approvals: approved).freeze
  rescue JSON::ParserError => e
    raise Failure, "Invalid release snapshot: #{e.message}"
  end

  def approvals(value)
    check(value.is_a?(Hash) && value.keys.sort == %w[postinstall postremove], 'Unexpected approved scriptlet roles')
    value.sort.to_h.transform_values do |item|
      check(item.is_a?(Hash) && item.keys.sort == %w[interpreter sha256] && item['interpreter'] == ['/bin/sh'] &&
            item['sha256'].is_a?(String) && item['sha256'].match?(/\A[0-9a-f]{64}\z/), 'Invalid scriptlet approval or interpreter')
      {'interpreter' => ['/bin/sh'.freeze].freeze, 'sha256' => item['sha256'].dup.freeze}.freeze
    end.freeze
  end

  def read_approvals(dir)
    value = JSON.parse(read_file(Pathname(dir)/'scriptlets.json', 8192), max_nesting: 10)
    check(value.is_a?(Hash) && value.keys.sort == %w[schema scriptlets] && value['schema'].is_a?(Integer) && value['schema'] == 1,
          'Unsupported scriptlet review schema')
    approvals(value['scriptlets'])
  end

  # Text-only trusted-main inputs. Publication jobs do not execute candidate helpers.
  def development(root)
    root = Pathname(root)
    source = read_file(root/'lib/moonshine_host.rb', MAX_SOURCE)
    approved = read_approvals(root/'reference')
    check(approvals(literal_object(source, 'APPROVED_SCRIPTLETS')) == approved, 'Development scriptlet approvals differ')
    Recipe.new(release: source_release(source), source: source.freeze, approvals: approved,
               helper_path: (root/'lib/moonshine_host.rb').expand_path.freeze).freeze
  end

  def current(root)
    root = Pathname(root)
    dir = snapshot_directories(root)[:stable]
    dir ? accepted_delivery(root, load_snapshot(dir, 'Stable'), 'stable') : load_recipe(root/'lib/moonshine_host.rb', root/'reference')
  end

  def previous(root)
    dir = snapshot_directories(root)[:previous]
    if dir
      recipe = load_snapshot(dir, 'Previous')
      snapshot_directories(root)[:stable] ? accepted_delivery(root, recipe, 'previous') : recipe
    end
  end

  def recipes(root)
    latest = current(root)
    predecessor = previous(root)
    if predecessor
      order = version(predecessor.release['version']) <=> version(latest.release['version'])
      check(order == -1 || (order == 0 && latest.delivery&.fetch('style') == 'recipe' && predecessor.identity != latest.identity &&
                            exact_token(predecessor) != exact_token(latest)),
            'Previous release must precede the current release')
    end
    MoonshineCandidates.catalog(root)
    [latest, predecessor].compact
  end

  def tokens(root)
    ['moonshine', *recipes(root).map { |recipe| exact_token(recipe) }, *('moonshine@untested' if MoonshineCandidates.catalog(root)['current'])]
  end

  def save_previous(root, recipe)
    parent = Pathname(root)/'releases'
    check(!parent.symlink? && (!parent.exist? || parent.directory?), 'Unsafe release-snapshot parent')
    dir = parent/'previous'
    check(!dir.symlink? && (!dir.exist? || dir.directory?), 'Unsafe previous-release snapshot directory')
    if dir.exist?
      check(dir.children.all? { |path| path.file? && !path.symlink? && SNAPSHOT_FILES.include?(path.basename.to_s) },
            'Unexpected previous-release snapshot files')
    end
    dir.mkpath
    files = {'helper.rb' => recipe.source,
             'release.json' => JSON.pretty_generate('schema' => 1, 'release' => recipe.release,
                                                   'helper_sha256' => Digest::SHA256.hexdigest(recipe.source)) + "\n"}
    recipe.scripts.each { |name, body| files["#{name}.sh"] = body + "\n" }
    files.each { |name, text| (dir/name).write(text) }
  end

  # Call only in a disposable candidate tree after the RPM passes eligibility checks.
  def rotate(root, release)
    check(snapshot_directories(root)[:stable].nil?, 'Locked stable catalog requires explicit promotion')
    release = metadata(release)
    latest = current(root)
    check((version(release['version']) <=> version(latest.release['version'])) == 1, 'Candidate release must be newer')
    line = /^  RELEASE = [^\n]+\.freeze$/
    check(latest.source.scan(line).length == 1, 'Cannot identify the single release metadata declaration')
    source = latest.source.sub(line, "  RELEASE = #{release.inspect}.freeze")
    save_previous(root, latest)
    (Pathname(root)/'lib/moonshine_host.rb').write(source)
    current(root)
  end
end

require_relative 'candidate_catalog'

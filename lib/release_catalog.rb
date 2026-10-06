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
  Recipe = Struct.new(:release, :source, :scripts, keyword_init: true)
  MAX_SOURCE = 256 * 1024
  MAX_REFERENCE = 64 * 1024
  METADATA_KEYS = %w[filename sha256 version].freeze
  SNAPSHOT_FILES = %w[helper.rb postinstall.sh postremove.sh release.json].freeze
  DESCRIBE = <<~'RUBY'.freeze
    require 'json'
    puts JSON.generate('release' => MoonshineHost::RELEASE, 'scripts' => MoonshineHost::REVIEWED_SCRIPTS)
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
    scripts = data.fetch('scripts')
    check(scripts.is_a?(Hash) && scripts.keys.sort == %w[postinstall postremove], 'Unexpected reviewed scriptlet set')
    scripts.each do |name, body|
      check(body.is_a?(String) && body.bytesize <= MAX_REFERENCE, 'Invalid reviewed scriptlet body')
      reference = read_file(Pathname(references)/"#{name}.sh", MAX_REFERENCE).sub(/\n+\z/, '')
      check(reference == body, "Reviewed scriptlet reference drift: #{name}")
    end
    Recipe.new(release: release, source: source.freeze, scripts: scripts.freeze).freeze
  rescue JSON::ParserError, KeyError => e
    raise Failure, "Invalid release helper metadata: #{e.message}"
  end

  def current(root)
    root = Pathname(root)
    load_recipe(root/'lib/moonshine_host.rb', root/'reference')
  end

  def previous(root)
    parent = Pathname(root)/'releases'
    return unless parent.exist? || parent.symlink?
    check(parent.directory? && !parent.symlink? && parent.children.map { |path| path.basename.to_s } == ['previous'],
          'Unexpected release-snapshot directory')
    dir = parent/'previous'
    check(dir.directory? && !dir.symlink?, 'Unsafe previous-release snapshot directory')
    check(dir.children.map { |path| path.basename.to_s }.sort == SNAPSHOT_FILES, 'Unexpected previous-release snapshot files')
    manifest = JSON.parse(read_file(dir/'release.json', 8192), max_nesting: 10)
    check(manifest.keys.sort == %w[helper_sha256 release schema] && manifest['schema'] == 1, 'Unsupported release snapshot schema')
    expected = metadata(manifest['release'])
    source = read_file(dir/'helper.rb', MAX_SOURCE)
    check(manifest['helper_sha256'] == Digest::SHA256.hexdigest(source), 'Previous helper snapshot digest differs')
    recipe = load_recipe(dir/'helper.rb', dir)
    check(expected == recipe.release, 'Previous helper and release identity differ')
    recipe
  rescue JSON::ParserError => e
    raise Failure, "Invalid release snapshot: #{e.message}"
  end

  def recipes(root)
    latest = current(root)
    predecessor = previous(root)
    if predecessor
      check((version(predecessor.release['version']) <=> version(latest.release['version'])) == -1,
            'Previous release must precede the current release')
    end
    [latest, predecessor].compact
  end

  def tokens(root)
    ['moonshine', *recipes(root).map { |recipe| "moonshine@#{recipe.release['version']}" }]
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

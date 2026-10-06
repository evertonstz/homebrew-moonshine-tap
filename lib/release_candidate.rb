# Deterministic reconstruction uses trusted base inputs, never PR code or artifact helpers.
require_relative 'release_update'
require_relative '../tools/generate_cask'

module MoonshineCandidate
  extend self
  ROOT_ENTRIES = %w[.github .gitignore Casks LICENSE README.md lib reference releases tests tools].freeze
  MAX_FILE = 2 * 1024 * 1024

  def tree(root)
    root = Pathname(root)
    MoonshineUpdate.check(root.directory? && !root.symlink?, 'Unsafe tap root')
    names = root.children.map { |path| path.basename.to_s }
    MoonshineUpdate.check((names - ROOT_ENTRIES - ['.git']).empty?, 'Unexpected shipping-tree entry')
    result = {}
    root.find do |path|
      if path == root/'.git'
        Find.prune if path.directory?
        next
      end
      next if path == root
      MoonshineUpdate.check(!path.symlink?, 'Symlink in shipping tree')
      next if path.directory?
      MoonshineUpdate.check(path.file? && path.size <= MAX_FILE, 'Unsafe or oversized shipping input')
      result[path.relative_path_from(root).to_s] = path.binread
    end
    result.sort.to_h
  end

  # Construct candidate source as text. Execute only trusted base helpers in the write job.
  def patch(root, release)
    release = MoonshineReleases.metadata(release)
    before = tree(root)
    MoonshineCask.generate(root: root, check: true)
    current = MoonshineReleases.recipes(root).first
    MoonshineUpdate.check((MoonshineReleases.version(release['version']) <=> MoonshineReleases.version(current.release['version'])) == 1,
                          'Candidate release must be newer')
    declaration = /^  RELEASE = [^\n]+\.freeze$/
    MoonshineUpdate.check(current.source.scan(declaration).length == 1, 'Ambiguous release declaration')
    source = current.source.sub(declaration, "  RELEASE = #{release.inspect}.freeze")
    candidate = MoonshineReleases::Recipe.new(release: release, source: source, scripts: current.scripts)
    tokens = ['moonshine', "moonshine@#{release['version']}", "moonshine@#{current.release['version']}"]
    after = before.dup
    after['lib/moonshine_host.rb'] = source
    after['releases/previous/helper.rb'] = current.source
    after['releases/previous/release.json'] = JSON.pretty_generate('schema' => 1, 'release' => current.release,
                                                                 'helper_sha256' => Digest::SHA256.hexdigest(current.source)) + "\n"
    current.scripts.each { |name, body| after["releases/previous/#{name}.sh"] = body + "\n" }
    before.keys.grep(%r{\ACasks/moonshine.*\.rb\z}).each { |name| after.delete(name) }
    tokens.each do |token|
      recipe = token == tokens.last ? current : candidate
      after["Casks/#{token}.rb"] = MoonshineCask.render(recipe: recipe, token: token, tokens: tokens, root: root)
    end
    (before.keys | after.keys).sort.filter_map do |name|
      [name, after[name]] unless before[name] == after[name]
    end.to_h
  end

  def verify_patch(root, release, proposed)
    MoonshineUpdate.check(proposed.is_a?(Hash) && proposed == patch(root, release), 'Candidate differs from the exact permitted release patch')
    true
  end

  class Store
    def initialize(parent: nil)
      @parent = parent
    end

    def prepare(root, release)
      changes = MoonshineCandidate.patch(root, release)
      baseline = MoonshineCandidate.tree(root)
      directory = Dir.mktmpdir('moonshine-candidate-', @parent)
      begin
        target = Pathname(directory)
        baseline.each do |name, bytes|
          path = target/name
          path.dirname.mkpath
          path.binwrite(bytes)
        end
        changes.each do |name, bytes|
          path = target/name
          if bytes
            path.dirname.mkpath
            path.binwrite(bytes)
          else
            path.delete
          end
        end
        # Validate candidate trees only in jobs without write credentials.
        MoonshineCask.generate(root: target, check: true)
        actual = MoonshineCandidate.tree(target)
        difference = (baseline.keys | actual.keys).sort.filter_map do |name|
          [name, actual[name]] unless baseline[name] == actual[name]
        end.to_h
        MoonshineCandidate.verify_patch(root, release, difference)
        {'directory' => directory, 'paths' => changes.keys,
         'patch_sha256' => Digest::SHA256.hexdigest(JSON.generate(changes))}
      rescue StandardError
        FileUtils.remove_entry_secure(directory)
        raise
      end
    end
  end
end

#!/usr/bin/env ruby
# Freeze the currently offered recipes before changing development installation inputs.
require 'tempfile'
require_relative '../lib/release_candidate'

module MoonshineRecipeLock
  extend self

  def capture(recipe, text, token)
    template = text.sub("cask #{token.inspect} do", 'cask "__MOONSHINE_TOKEN__" do')
      .sub("  version #{recipe.release['version'].inspect}", '  version "__MOONSHINE_VERSION__"')
      .sub(/^  conflicts_with cask: \[[^\n]*\]$/, '  conflicts_with cask: [__MOONSHINE_CONFLICTS__]')
      .sub("\"evertonstz/moonshine-tap/#{token}\"", '"evertonstz/moonshine-tap/__MOONSHINE_TOKEN__"')
    MoonshineReleases.validate_template(template, recipe.release, recipe.source)
    fields = MoonshineReleases.recipe_fields(recipe.release, recipe.source, recipe.scripts, template)
    MoonshineReleases::Recipe.new(release: recipe.release, source: recipe.source, scripts: recipe.scripts,
                                  template: template.freeze, identity: MoonshineReleases.recipe_digest(fields).freeze).freeze
  end

  def files(slot, recipe)
    MoonshineReleases.check(%w[stable previous].include?(slot), 'Invalid accepted recipe slot')
    fields = MoonshineReleases.recipe_fields(recipe.release, recipe.source, recipe.scripts, recipe.template)
    MoonshineReleases.check(recipe.identity == MoonshineReleases.recipe_digest(fields), 'Frozen recipe identity differs')
    manifest = fields.merge('recipe_sha256' => recipe.identity)
    result = {"releases/#{slot}/helper.rb" => recipe.source,
              "releases/#{slot}/cask.rb" => recipe.template,
              "releases/#{slot}/release.json" => JSON.pretty_generate(manifest) + "\n"}
    recipe.scripts.each { |name, body| result["releases/#{slot}/#{name}.sh"] = body + "\n" }
    result
  end

  def patch(root:)
    before = MoonshineCandidate.tree(root)
    MoonshineCask.generate(root: root, check: true)
    MoonshineReleases.check(MoonshineReleases.snapshot_directories(root)[:stable].nil?, 'Accepted recipes are already locked')
    recipes = MoonshineReleases.recipes(root)
    outputs = MoonshineCask.outputs(root: root)
    proposed = {}
    recipes.each_with_index do |recipe, index|
      slot = index.zero? ? 'stable' : 'previous'
      token = index.zero? ? 'moonshine' : "moonshine@#{recipe.release['version']}"
      frozen = capture(recipe, outputs.fetch("Casks/#{token}.rb"), token)
      proposed.merge!(files(slot, frozen))
    end
    proposed['releases/catalog.json'] = JSON.pretty_generate('schema' => 1, 'stable' => 'stable',
                                                            'previous' => recipes.length == 2 ? 'previous' : nil) + "\n"
    Dir.mktmpdir('moonshine-recipe-lock-') do |directory|
      staged = Pathname(directory)
      before.merge(proposed).each do |name, bytes|
        path = staged/name
        path.dirname.mkpath
        path.binwrite(bytes)
      end
      MoonshineCask.generate(root: staged, check: true)
      MoonshineReleases.check(MoonshineCask.outputs(root: staged) == outputs, 'Freezing changed an offered cask')
    end
    MoonshineReleases.check(MoonshineCandidate.tree(root) == before, 'Recipe inputs changed during freezing')
    proposed.reject { |name, bytes| before[name] == bytes }.sort.to_h
  end

  def main(argv = ARGV)
    raise MoonshineReleases::Failure, 'Usage: ruby tools/lock_recipes.rb [--check]' unless argv.empty? || argv == ['--check']
    root = Pathname(__dir__).parent
    changes = patch(root: root)
    if argv.empty?
      changes.each do |name, bytes|
        path = root/name
        path.dirname.mkpath
        # Replace only owned source files; the private reconstruction has already checked every output.
        temporary = Tempfile.new('.moonshine-recipe-', path.dirname)
        begin
          temporary.binmode
          temporary.write(bytes)
          temporary.flush
          temporary.fsync
          temporary.close
          File.rename(temporary.path, path)
        ensure
          temporary.close!
        end
      end
    end
    puts JSON.pretty_generate('paths' => changes.keys, 'applied' => argv.empty?, 'host_installation' => false)
    0
  rescue StandardError => e
    warn "recipe lock failed: #{e.class}: #{e.message}"
    1
  end
end
exit MoonshineRecipeLock.main if $PROGRAM_NAME == __FILE__

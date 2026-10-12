require 'minitest/autorun'
require 'open3'
require_relative '../lib/release_candidate'

class UpdateCLITest < Minitest::Test
  def test_missing_exact_cask_reason_is_visible_when_workflow_redirects_stdout
    source = Pathname(__dir__).parent
    Dir.mktmpdir('moonshine-update-cli-') do |directory|
      root = Pathname(directory)
      MoonshineCandidate.tree(source).each do |name, bytes|
        path = root / name
        path.dirname.mkpath
        path.binwrite(bytes)
      end
      %w[init add commit].each do |operation|
        arguments = case operation
                    when 'init' then ['init', '-q', '-b', 'main']
                    when 'add' then ['add', '.']
                    else ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                          'commit', '-q', '-m', 'Pinned CLI fixture']
                    end
        _, error, status = Open3.capture3('git', *arguments, chdir: root.to_s)
        assert status.success?, error
      end
      (root / 'Casks/moonshine@0.16.1.rb').delete
      before = MoonshineCandidate.tree(root)
      extractor = ENV.fetch('MOONSHINE_TEST_BSDTAR', '/usr/bin/bsdtar')
      output, error, status = Open3.capture3(
        {'RUBYOPT' => nil, 'RUBYLIB' => nil, 'GITHUB_TOKEN' => nil, 'GH_TOKEN' => nil,
         'MOONSHINE_APP_TOKEN' => nil, 'MOONSHINE_PROTECTION_TOKEN' => nil},
        RbConfig.ruby, '--disable=rubyopt', (root / 'tools/update_release.rb').to_s,
        '--bsdtar', extractor, '--prepare', chdir: root.to_s
      )
      report = JSON.parse(output)
      assert_equal 1, status.exitstatus
      assert_equal 'review_required', report['status']
      assert_includes report.fetch('reason'), 'Release catalog validation failed:'
      assert_includes report.fetch('reason'), 'moonshine@0.16.1.rb'
      assert_equal before, MoonshineCandidate.tree(root), 'Refusal must not change remaining inputs'
      assert_equal "release review required: #{JSON.generate(report.fetch('reason'))}\n", error,
                   'The hosted workflow hides stdout; its refusal reason must remain visible on stderr'
    end
  end
end

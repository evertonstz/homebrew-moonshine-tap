require 'minitest/autorun'
require 'open3'
require_relative '../lib/release_candidate'

class GitHubCLITest < Minitest::Test
  def test_fresh_public_process_refuses_missing_protection_credential_before_network_or_mutation
    source = Pathname(__dir__).parent
    Dir.mktmpdir('moonshine-github-cli-') do |directory|
      root = Pathname(directory)
      MoonshineCandidate.tree(source).each do |name, bytes|
        path = root/name
        path.dirname.mkpath
        path.binwrite(bytes)
      end
      [['init', '-q', '-b', 'main'], ['add', '.'],
       ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '-q', '-m', 'Controller entrypoint fixture']].each do |arguments|
        _, error, status = Open3.capture3('git', *arguments, chdir: root.to_s)
        assert status.success?, error
      end
      before = MoonshineCandidate.tree(root)
      secret = 'BUILTIN_' + 'x' * 30
      env = {'RUBYOPT' => nil, 'RUBYLIB' => nil, 'GH_TOKEN' => nil,
        'MOONSHINE_APP_TOKEN' => nil, 'MOONSHINE_PROTECTION_TOKEN' => nil,
        'GITHUB_REPOSITORY' => 'evertonstz/homebrew-moonshine-tap',
        'GITHUB_REF' => 'refs/heads/main', 'GITHUB_EVENT_NAME' => 'workflow_dispatch',
        'MOONSHINE_RELEASE_UPDATES_ENABLED' => 'true', 'MOONSHINE_STABLE_PROMOTION_ENABLED' => 'false',
        'GITHUB_TOKEN' => secret}
      output, error, status = Open3.capture3(env, RbConfig.ruby, '--disable=rubyopt',
        (root/'tools/github_release.rb').to_s, 'publish', chdir: root.to_s)
      assert_equal 1, status.exitstatus
      assert_empty output
      assert_equal "Release controller failed; owner review required. No automatic retry or bypass.\n", error
      refute_includes error, secret
      assert_equal before, MoonshineCandidate.tree(root)
    end
  end
end

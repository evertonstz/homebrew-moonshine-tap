# Trusted-base GitHub controller. Never load a PR helper, cask, artifact or package.
require 'net/http'
require 'openssl'
require 'digest'
require_relative 'release_candidate'
require_relative 'ci_validation'

module MoonshineGitHub
  extend self
  REPOSITORY = 'evertonstz/homebrew-moonshine-tap'.freeze
  BRANCH = 'automation/moonshine-release'.freeze
  PREFIX = "Moonshine release update\n\n".freeze
  MAX_JSON = 2 * 1024 * 1024
  JOB_NAMES = ['Moonshine checks (ubuntu-24.04)', 'Moonshine checks (macos-15)', MoonshineCI::REQUIRED_CHECK].freeze
  Failure = Class.new(StandardError)

  def check(value, message)
    raise Failure, message unless value
  end

  def sha(value)
    check(value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/), 'Invalid Git object identity')
    value
  end

  def integer(value)
    check(value.is_a?(Integer) && value.positive? && value <= 0x7fff_ffff_ffff_ffff, 'Invalid GitHub numeric identity')
    value
  end

  def blob(bytes)
    Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes.b)
  end

  def manifest(base, release, asset)
    {'base_sha' => sha(base), 'release' => MoonshineReleases.metadata(release), 'asset_id' => integer(asset)}
  end

  def message(data)
    PREFIX + JSON.generate(data) + "\n"
  end

  def parse_message(text)
    check(text.is_a?(String) && text.bytesize <= 2048 && text.start_with?(PREFIX), 'Unrecognized release commit')
    value = JSON.parse(text.delete_prefix(PREFIX), max_nesting: 5)
    check(value.is_a?(Hash) && value.keys.sort == %w[asset_id base_sha release], 'Invalid release commit fields')
    result = manifest(value['base_sha'], value['release'], value['asset_id'])
    check(message(result) == text, 'Noncanonical release commit')
    result
  end

  # Use one HTTPS origin without redirects, response logging or token storage on disk.
  class API
    def initialize(token:, transport: nil)
      MoonshineGitHub.check(token.is_a?(String) && token.match?(/\A[A-Za-z0-9_.-]{20,512}\z/), 'Missing or malformed GitHub credential')
      @token = token
      @transport = transport || method(:send_request)
    end

    def inspect
      '#<MoonshineGitHub::API credential=redacted>'
    end

    def call(method, path, data = nil, missing: false)
      prefix = "/repos/#{REPOSITORY}"
      allowed = case method
      when 'GET' then path == '/installation/repositories?per_page=100' || path.start_with?(prefix + '/') || path == prefix
      when 'POST' then %w[/git/trees /git/commits /git/refs /pulls].include?(path.delete_prefix(prefix)) && path.start_with?(prefix + '/')
      when 'PUT' then path.match?(%r{\A#{Regexp.escape(prefix)}/pulls/[1-9][0-9]*/merge\z})
      else false
      end
      MoonshineGitHub.check(allowed && !path.match?(/[\s#\\]/) && !path.include?('..'), 'GitHub operation outside controller scope')
      if method == 'POST' && path.end_with?('/git/refs')
        MoonshineGitHub.check(data.is_a?(Hash) && data.keys.sort == %w[ref sha] && data['ref'] == "refs/heads/#{BRANCH}", 'Only the bot branch may be created')
        MoonshineGitHub.sha(data['sha'])
      end
      code, body = @transport.call(method, path, data, @token)
      return nil if missing && method == 'GET' && code == 404
      MoonshineGitHub.check(code.between?(200, 299), "GitHub request refused (HTTP #{code})")
      MoonshineGitHub.check(body.is_a?(String) && body.bytesize <= MAX_JSON, 'GitHub response exceeds limit')
      JSON.parse(body, max_nesting: 20)
    rescue JSON::ParserError
      raise Failure, 'Invalid GitHub JSON response'
    end

    def send_request(method, path, data, token)
      uri = URI('https://api.github.com' + path)
      request = {'GET' => Net::HTTP::Get, 'POST' => Net::HTTP::Post, 'PUT' => Net::HTTP::Put}.fetch(method).new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Accept'] = 'application/vnd.github+json'
      request['X-GitHub-Api-Version'] = '2022-11-28'
      request['User-Agent'] = 'moonshine-tap-release-controller'
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(data) if data
      http = Net::HTTP.new(uri.host, 443, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 20
      http.read_timeout = 30
      body = ''.b
      code = nil
      http.start do |connection|
        connection.request(request) do |response|
          code = response.code.to_i
          response.read_body do |part|
            MoonshineGitHub.check(body.bytesize + part.bytesize <= MAX_JSON, 'GitHub response exceeds limit')
            body << part
          end
        end
      end
      [code, body]
    rescue Failure
      raise
    rescue StandardError
      raise Failure, 'GitHub transport failed; accepted pins unchanged'
    end
  end

  class Controller
    def initialize(api:, root:, bot_slug:, bot_id:, check_app_id:)
      MoonshineGitHub.check(bot_slug.is_a?(String) && bot_slug.match?(/\A[a-z0-9][a-z0-9-]{0,62}\z/), 'Missing expected App slug')
      @api, @root = api, Pathname(root)
      @bot = "#{bot_slug}[bot]"
      @bot_id = MoonshineGitHub.integer(bot_id)
      @check_app_id = MoonshineGitHub.integer(check_app_id)
      @prefix = "/repos/#{REPOSITORY}"
    end

    def get(suffix, missing: false)
      @api.call('GET', @prefix + suffix, missing: missing)
    end

    def post(suffix, body)
      @api.call('POST', @prefix + suffix, body)
    end

    def bot?(user)
      user.is_a?(Hash) && user['type'] == 'Bot' && user['login'] == @bot && user['id'] == @bot_id
    end

    def scope!
      scope = @api.call('GET', '/installation/repositories?per_page=100')
      MoonshineGitHub.check(scope['total_count'] == 1 && scope['repositories'].is_a?(Array) &&
        scope['repositories'].map { |repo| repo['full_name'] } == [REPOSITORY], 'App credential must be scoped to this repository only')
      repo = get('')
      MoonshineGitHub.check(repo['full_name'] == REPOSITORY && repo['default_branch'] == 'main' &&
        repo['allow_squash_merge'] == true && repo['allow_auto_merge'] == true && repo['delete_branch_on_merge'] == true &&
        repo['archived'] == false && repo['disabled'] == false, 'Repository activation settings unavailable or insufficient')
    end

    def base!(base)
      MoonshineGitHub.check(get('/git/ref/heads/main').dig('object', 'sha') == MoonshineGitHub.sha(base), 'Default branch changed; fresh validation required')
    end

    def tree(commit)
      object = get("/git/commits/#{MoonshineGitHub.sha(commit)}")
      result = get("/git/trees/#{MoonshineGitHub.sha(object.dig('tree', 'sha'))}?recursive=1")
      MoonshineGitHub.check(result['truncated'] == false && result['tree'].is_a?(Array) && result['tree'].length <= 1000, 'Incomplete or oversized Git tree')
      files = {}
      directories = []
      result['tree'].each do |entry|
        name = entry['path']
        MoonshineGitHub.check(name.is_a?(String) && name.match?(%r{\A[A-Za-z0-9_.@/-]+\z}) &&
          name.split('/').none? { |part| part.empty? || %w[. .. .git].include?(part) }, 'Unsafe Git path')
        if entry['type'] == 'tree'
          MoonshineGitHub.check(entry['mode'] == '040000' && !directories.include?(name), 'Unsafe or duplicate Git directory')
          MoonshineGitHub.sha(entry['sha'])
          directories << name
          next
        end
        MoonshineGitHub.check(entry['type'] == 'blob' && %w[100644 100755].include?(entry['mode']) && !files.key?(name), 'Unexpected Git file type or duplicate')
        files[name] = {'sha' => MoonshineGitHub.sha(entry['sha']), 'mode' => entry['mode']}
      end
      ancestors = files.keys.flat_map do |path|
        parts = path.split('/')[0...-1]
        (1..parts.length).map { |length| parts.first(length).join('/') }
      end.uniq.sort
      MoonshineGitHub.check(directories.sort == ancestors, 'Unexpected empty or missing Git directory')
      [object, files]
    end

    def expected(data)
      base!(data.fetch('base_sha'))
      object, files = tree(data['base_sha'])
      local = MoonshineCandidate.tree(@root)
      MoonshineGitHub.check(files.keys.sort == local.keys.sort && local.all? { |path, bytes| files[path]['sha'] == MoonshineGitHub.blob(bytes) }, 'Checkout differs from trusted Git base')
      changes = MoonshineCandidate.patch(@root, data['release'])
      after = files.transform_values(&:dup)
      changes.each do |path, bytes|
        bytes ? after[path] = {'sha' => MoonshineGitHub.blob(bytes), 'mode' => files.dig(path, 'mode') || '100644'} : after.delete(path)
      end
      [object, changes, after]
    end

    def head!(head, data, expected_files)
      object, files = tree(head)
      MoonshineGitHub.check(object['parents'].is_a?(Array) && object['parents'].map { |parent| parent['sha'] } == [data['base_sha']] &&
        object['message'] == MoonshineGitHub.message(data) && files == expected_files, 'Unexpected bot branch commit or release patch')
      commit = get("/commits/#{MoonshineGitHub.sha(head)}")
      MoonshineGitHub.check(bot?(commit['author']) && bot?(commit['committer']), 'Release commit is not owned by the configured App bot')
    end

    def pull!(pr, base, head)
      MoonshineGitHub.check(pr.is_a?(Hash) && pr['state'] == 'open' && pr['draft'] == false && pr['merged'] == false &&
        bot?(pr['user']) && pr.dig('base', 'repo', 'full_name') == REPOSITORY && pr.dig('head', 'repo', 'full_name') == REPOSITORY &&
        pr.dig('base', 'ref') == 'main' && pr.dig('head', 'ref') == BRANCH && pr.dig('base', 'sha') == base &&
        pr.dig('head', 'sha') == head && pr['commits'] == 1, 'PR identity, head or current base differs')
      MoonshineGitHub.integer(pr['number'])
    end

    def protection!
      policy = get('/branches/main/protection')
      checks = policy['required_status_checks']
      reviews = policy['required_pull_request_reviews']
      expected = [{'context' => MoonshineCI::REQUIRED_CHECK, 'app_id' => @check_app_id}]
      MoonshineGitHub.check(checks.is_a?(Hash) && checks['strict'] == true && checks['checks'] == expected &&
        checks['contexts'] == [MoonshineCI::REQUIRED_CHECK] && policy.dig('enforce_admins', 'enabled') == true &&
        policy.dig('allow_force_pushes', 'enabled') == false && policy.dig('allow_deletions', 'enabled') == false &&
        reviews.is_a?(Hash), 'Unknown required checks or insufficient current-base PR protection')
      bypass = reviews['bypass_pull_request_allowances']
      MoonshineGitHub.check(bypass.is_a?(Hash) && bypass.keys.sort == %w[apps teams users] &&
        bypass.values.all? { |value| value == [] }, 'PR protection has bypass allowances')
    end

    def validation!(run, head, number)
      MoonshineGitHub.check(run.is_a?(Hash) && run['event'] == 'pull_request' && run['status'] == 'completed' &&
        run['conclusion'] == 'success' && run['path'] == '.github/workflows/ci.yml' && run['head_sha'] == head &&
        run['head_branch'] == BRANCH && run.dig('repository', 'full_name') == REPOSITORY &&
        run.dig('head_repository', 'full_name') == REPOSITORY, 'CI identity, conclusion or checked head differs')
      id = MoonshineGitHub.integer(run['id'])
      attempt = MoonshineGitHub.integer(run['run_attempt'])
      latest = get("/actions/workflows/ci.yml/runs?event=pull_request&head_sha=#{head}&per_page=100")
      MoonshineGitHub.check(latest['total_count'].is_a?(Integer) && latest['total_count'].between?(1, 99) &&
        latest['workflow_runs'].is_a?(Array) && latest['workflow_runs'].first&.values_at('id', 'run_attempt') == [id, attempt],
        'CI was superseded; fresh validation required')
      jobs = get("/actions/runs/#{id}/attempts/#{attempt}/jobs?per_page=100")
      list = jobs['jobs']
      MoonshineGitHub.check(jobs['total_count'] == JOB_NAMES.length && list.is_a?(Array) &&
        list.map { |job| job['name'] }.sort == JOB_NAMES.sort &&
        list.all? { |job| job['status'] == 'completed' && job['conclusion'] == 'success' }, 'Required CI jobs missing, skipped or unsuccessful')
      list.each do |job|
        names = job['name'] == MoonshineCI::REQUIRED_CHECK ? ['Require all prerequisite jobs to succeed'] :
          ['Check source and all generated casks', 'Load every offered token with Homebrew',
           'Inspect and extract every retained official RPM', 'Run all regressions with mandatory official RPM extraction']
        steps = job['steps']
        MoonshineGitHub.check(steps.is_a?(Array) && names.all? do |name|
          matches = steps.select { |step| step['name'] == name }
          matches.length == 1 && matches.first['status'] == 'completed' && matches.first['conclusion'] == 'success'
        end, 'Required CI steps missing, skipped or unsuccessful')
      end
      # Require CI association with this PR as well as its exact head.
      MoonshineGitHub.check(run['pull_requests'].is_a?(Array) && run['pull_requests'].map { |pr| pr['number'] } == [number], 'CI is not associated with the expected PR')
    end

    def merge(base:, run_id:)
      scope!
      protection!
      base!(base)
      run = get("/actions/runs/#{MoonshineGitHub.integer(run_id)}")
      head = MoonshineGitHub.sha(run['head_sha'])
      pulls = get("/pulls?state=open&head=evertonstz:#{BRANCH}&base=main&per_page=100")
      MoonshineGitHub.check(pulls.is_a?(Array) && pulls.length == 1, 'Expected exactly one open release PR')
      number = MoonshineGitHub.integer(pulls.first['number'])
      pr = get("/pulls/#{number}")
      pull!(pr, base, head)
      object = get("/git/commits/#{head}")
      data = MoonshineGitHub.parse_message(object['message'])
      MoonshineGitHub.check(data['base_sha'] == base, 'Candidate baseline changed; recompute release eligibility and retention')
      _, _, after = expected(data)
      head!(head, data, after)
      validation!(run, head, number)
      # Recheck mutable identities and protection immediately before the head-bound merge request.
      base!(base)
      fresh_head = MoonshineGitHub.sha(get("/git/ref/heads/#{BRANCH}").dig('object', 'sha'))
      MoonshineGitHub.check(fresh_head == head, 'PR head changed; fresh validation required')
      head!(fresh_head, data, after)
      pull!(get("/pulls/#{number}"), base, head)
      protection!
      result = @api.call('PUT', @prefix + "/pulls/#{number}/merge", {'sha' => head, 'merge_method' => 'squash'})
      MoonshineGitHub.check(result['merged'] == true, 'Protected merge was refused; accepted pins unchanged')
      {'status' => 'merged', 'number' => number, 'head_sha' => head, 'merge_sha' => MoonshineGitHub.sha(result['sha'])}
    end

    def publish(base:, release:, asset:)
      scope!
      data = MoonshineGitHub.manifest(base, release, asset)
      object, changes, after = expected(data)
      pulls = get("/pulls?state=all&head=evertonstz:#{BRANCH}&base=main&per_page=100")
      MoonshineGitHub.check(pulls.is_a?(Array) && pulls.length < 100, 'Incomplete PR history')
      open = pulls.select { |pr| pr['state'] == 'open' }
      MoonshineGitHub.check(open.length <= 1, 'Multiple open release PRs')
      ref = get("/git/ref/heads/#{BRANCH}", missing: true)
      if ref
        head = MoonshineGitHub.sha(ref.dig('object', 'sha'))
        head!(head, data, after)
        MoonshineGitHub.check(pulls.none? { |pr| pr.dig('head', 'sha') == head && pr['state'] != 'open' }, 'Release PR was closed; owner review required')
      else
        MoonshineGitHub.check(open.empty?, 'Open PR exists without the expected branch')
        entries = changes.map do |path, bytes|
          entry = {'path' => path, 'mode' => after.dig(path, 'mode') || '100644', 'type' => 'blob'}
          bytes ? entry.merge('content' => bytes) : entry.merge('sha' => nil)
        end
        new_tree = post('/git/trees', {'base_tree' => MoonshineGitHub.sha(object.dig('tree', 'sha')), 'tree' => entries})
        commit = post('/git/commits', {'message' => MoonshineGitHub.message(data), 'tree' => MoonshineGitHub.sha(new_tree['sha']), 'parents' => [base]})
        head = MoonshineGitHub.sha(commit['sha'])
        head!(head, data, after)
        base!(base)
        # Create the ref without replacement. Refuse if another writer creates it first.
        post('/git/refs', {'ref' => "refs/heads/#{BRANCH}", 'sha' => head})
      end
      if open.any?
        pr = get("/pulls/#{MoonshineGitHub.integer(open.first['number'])}")
        pull!(pr, base, head)
        return {'status' => 'reused', 'number' => pr['number'], 'head_sha' => head}
      end
      base!(base)
      old = MoonshineReleases.current(@root).release
      body = "Official Moonshine #{old['version']} to #{data['release']['version']}.\n\n" +
        "Asset #{asset}: #{MoonshineUpdate.download_url(data['release'])}\n" +
        "Old SHA-256: #{old['sha256']}\nNew SHA-256: #{data['release']['sha256']}\n\n" +
        'Package validation only. No new host installation, streaming, downgrade, data compatibility or OS-update acceptance. Older binaries may lack security fixes.'
      pr = post('/pulls', {'title' => "Moonshine #{data['release']['version']}", 'head' => BRANCH, 'base' => 'main', 'body' => body, 'maintainer_can_modify' => false})
      # The create response may not contain a computed commit count yet.
      pr = get("/pulls/#{MoonshineGitHub.integer(pr['number'])}")
      pull!(pr, base, head)
      {'status' => 'created', 'number' => pr['number'], 'head_sha' => head}
    end
  end
end

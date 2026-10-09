# Authenticate an explicit owner attestation, not the truth of its native observations.
require_relative 'native_evidence'
require_relative 'github_release'

module MoonshineNativeOrigin
  extend self
  PREFIX = "Moonshine native report v1\n\n".freeze

  def timestamp(value)
    MoonshineReleases.check(value.is_a?(String) && value.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/),
                            'Invalid authenticated report timestamp')
    parsed = Time.iso8601(value)
    MoonshineReleases.check(parsed.utc.iso8601 == value && parsed <= Time.now, 'Invalid authenticated report timestamp')
    parsed
  rescue ArgumentError
    raise MoonshineReleases::Failure, 'Invalid authenticated report timestamp'
  end

  def read(api:, origin:, owner:)
    MoonshineNativeEvidence.fields(origin, %w[comment_id body_sha256 updated_at], 'Unexpected native report origin fields')
    id = MoonshineGitHub.integer(origin['comment_id'])
    MoonshineNativeEvidence.digest(origin['body_sha256'], 'Invalid native report body digest')
    timestamp(origin['updated_at'])
    MoonshineReleases.check(api, 'Authenticated native report requires a GitHub reader')
    prefix = "/repos/#{MoonshineGitHub::REPOSITORY}"
    repo = api.call('GET', prefix)
    MoonshineReleases.check(repo.is_a?(Hash) && repo['full_name'] == MoonshineGitHub::REPOSITORY &&
      repo['default_branch'] == 'main' && repo.dig('owner', 'type') == 'User' && repo.dig('owner', 'login') == owner,
      'Native report repository owner differs')
    repository_id = MoonshineGitHub.integer(repo['id'])
    owner_id = MoonshineGitHub.integer(repo.dig('owner', 'id'))
    comment = api.call('GET', "#{prefix}/issues/comments/#{id}")
    MoonshineReleases.check(comment.is_a?(Hash) && comment['id'].is_a?(Integer) && comment['id'] == id &&
      comment['url'] == "https://api.github.com#{prefix}/issues/comments/#{id}" &&
      comment.dig('user', 'login') == owner && comment.dig('user', 'id').is_a?(Integer) &&
      comment.dig('user', 'id') == owner_id && comment.dig('user', 'type') == 'User',
      'Native report is not an authenticated owner comment')
    issue_url = comment['issue_url']
    match = issue_url.is_a?(String) && issue_url.match(%r{\Ahttps://api\.github\.com#{Regexp.escape(prefix)}/issues/([1-9][0-9]*)\z})
    MoonshineReleases.check(match, 'Native report comment belongs to another repository')
    number = MoonshineGitHub.integer(match[1].to_i)
    pull = api.call('GET', "#{prefix}/pulls/#{number}")
    MoonshineReleases.check(pull.is_a?(Hash) && pull['number'].is_a?(Integer) && pull['number'] == number &&
      pull.dig('base', 'repo', 'full_name') == MoonshineGitHub::REPOSITORY, 'Native report must belong to a tap pull request')
    body = comment['body']
    MoonshineReleases.check(body.is_a?(String) && body.valid_encoding? &&
      body.bytesize <= PREFIX.bytesize + MoonshineNativeEvidence::MAX_REPORT && body.start_with?(PREFIX),
      'Invalid or oversized native report comment')
    MoonshineReleases.check(Digest::SHA256.hexdigest(body) == origin['body_sha256'] &&
      comment['updated_at'] == origin['updated_at'], 'Native report comment changed; fresh validation required')
    created = timestamp(comment['created_at'])
    updated = timestamp(comment['updated_at'])
    MoonshineReleases.check(created <= updated, 'Invalid authenticated report timestamp')
    record = {'kind' => 'github-owner-pr-comment', 'repository' => MoonshineGitHub::REPOSITORY,
              'repository_id' => repository_id, 'owner_id' => owner_id, 'comment_id' => id, 'pr_number' => number,
              'body_sha256' => origin['body_sha256'], 'created_at' => comment['created_at'], 'updated_at' => comment['updated_at']}
    [body.delete_prefix(PREFIX), record]
  end

  def assess(root:, target:, expected_stable:, origin:, api:)
    selected, = MoonshineNativeEvidence.policy(root)
    MoonshineCandidates.identity(target)
    MoonshineCandidates.identity(expected_stable)
    MoonshineCask.generate(root: root, check: true)
    MoonshineReleases.check(MoonshineReleases.current(root).identity == expected_stable,
                            'Accepted recipe changed; fresh promotion review required')
    MoonshineReleases.check(MoonshineCandidates.recipe(root, target), 'Exact retained promotion target is missing')
    evidence, record = read(api: api, origin: origin, owner: selected['owner'])
    result = MoonshineNativeEvidence.assess(root: root, target: target, expected_stable: expected_stable, evidence: evidence)
    observed = MoonshineNativeEvidence.parse(evidence).fetch('observed_at')
    MoonshineReleases.check(Time.iso8601(observed) <= Time.iso8601(record['updated_at']), 'Native observations postdate the owner attestation')
    # Comments are mutable. Recheck origin after local validation and again before future writes/merge.
    fresh_evidence, fresh_record = read(api: api, origin: origin, owner: selected['owner'])
    MoonshineReleases.check(evidence == fresh_evidence && record == fresh_record, 'Native report origin changed; fresh validation required')
    result.merge('owner_report_authenticated' => true, 'origin' => record)
  end
end

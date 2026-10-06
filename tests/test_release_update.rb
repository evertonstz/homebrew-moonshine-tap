require 'minitest/autorun'
require 'stringio'
require_relative 'test_host'
require_relative '../lib/release_update'
require_relative '../lib/release_candidate'
require_relative '../tools/check_releases'

class UpdateFixture
  BASELINE = 'accepted package fixture'.freeze
  CANDIDATE = 'candidate binary fixture'.freeze
  attr_reader :root, :data, :bodies, :inspections, :store

  def initialize(root)
    @root = Pathname(root)
    original = Pathname(__dir__).parent
    %w[lib/moonshine_host.rb lib/moonshine_token_guard.rb reference/postinstall.sh reference/postremove.sh].each do |name|
      (@root/name).dirname.mkpath
      FileUtils.cp(original/name, @root/name)
    end
    current = release('0.16.1', BASELINE)
    helper = @root/'lib/moonshine_host.rb'
    helper.write(helper.read.sub(/^  RELEASE = [^\n]+\.freeze$/, "  RELEASE = #{current.inspect}.freeze"))
    MoonshineCask.generate(root: @root)
    future = release('0.16.2', CANDIDATE)
    @bodies = {MoonshineUpdate.download_url(current) => BASELINE, MoonshineUpdate.download_url(future) => CANDIDATE}
    @data = {'draft' => false, 'prerelease' => false, 'tag_name' => 'v0.16.2', 'body' => 'ignored release notes',
             'assets' => [{'id' => 123, 'name' => future['filename'], 'state' => 'uploaded', 'size' => CANDIDATE.bytesize,
                           'browser_download_url' => MoonshineUpdate.download_url(future), 'digest' => "sha256:#{future['sha256']}"}]}
    @inspections = []
    @store = MoonshineCandidate::Store.new
    @signature = {'tags' => {1000 => 'moonshine'}, 'inventory' => {'/usr/bin/moonshine' => 0100755},
                  'dependencies' => ['libc.so.6'], 'protected' => {'/usr/bin/start-moonshine.sh' => 'protected digest'}}
  end

  def release(version, bytes)
    {'version' => version, 'sha256' => Digest::SHA256.hexdigest(bytes), 'filename' => "moonshine-#{version}-1.x86_64.rpm"}
  end

  def json(url)
    raise 'Wrong release API' unless url == MoonshineUpdate::API
    Marshal.load(Marshal.dump(data))
  end

  def download(url, path)
    path.binwrite(bodies.fetch(url))
  end

  def inspect(path, release)
    inspections << [path.basename.to_s, release]
    signature = Marshal.load(Marshal.dump(@signature))
    signature['dependencies'] << 'new.so' if @change && path.basename.to_s == 'candidate.rpm'
    signature
  end

  def change_contract
    @change = true
  end

  def run(prepare: false, store: @store)
    MoonshineUpdate::Updater.new(root: root, client: self, inspector: self, store: store).run(prepare: prepare)
  end
end

class ReleaseUpdateTest < Minitest::Test
  def fixture
    Dir.mktmpdir do |directory|
      subject = UpdateFixture.new(directory)
      yield subject
    end
  end

  def test_stable_binary_update_and_missing_api_digest
    fixture do |subject|
      subject.data['assets'][0].delete('digest')
      result = subject.run
      assert_equal 'eligible', result['status']
      assert_equal Digest::SHA256.hexdigest(UpdateFixture::CANDIDATE), result['release']['sha256']
      assert_equal %w[baseline.rpm candidate.rpm], subject.inspections.map(&:first)
      assert_equal result, subject.run
      assert_equal '0.16.1', MoonshineReleases.current(subject.root).release['version']
    end
  end

  def test_numeric_order_and_older_release_do_not_downgrade
    fixture do |subject|
      subject.data['tag_name'] = 'v0.9.9'
      assert_equal 'unchanged', subject.run['status']
      assert_empty subject.inspections
      subject.data['tag_name'] = 'v0.100.0'
      subject.data['assets'] = []
      assert_equal 'awaiting_asset', subject.run['status']
    end
  end

  def test_invalid_tags_and_nonstable_data_require_review
    fixture do |subject|
      ['v01.16.2', 'v0.16.2-pre', "v0.16.2';system('false')", nil, 12].each do |tag|
        subject.data['tag_name'] = tag
        assert_equal 'review_required', subject.run['status']
      end
      subject.data['tag_name'] = 'v0.16.2'
      subject.data['prerelease'] = true
      assert_equal 'review_required', subject.run['status']
      subject.data['prerelease'] = false
      subject.data['draft'] = true
      assert_equal 'review_required', subject.run['status']
    end
  end

  def test_missing_and_unfinished_assets_remain_pending
    fixture do |subject|
      subject.data['assets'][0]['state'] = 'new'
      assert_equal 'awaiting_asset', subject.run['status']
      subject.data['assets'] = []
      assert_equal 'awaiting_asset', subject.run['status']
      assert_empty subject.inspections
    end
  end

  def test_ambiguous_assets_and_changed_revision_require_review
    fixture do |subject|
      subject.data['assets'] << subject.data['assets'][0].dup
      assert_equal 'review_required', subject.run['status']
      subject.data['assets'] = [subject.data['assets'][0]]
      subject.data['assets'][0]['name'] = 'moonshine-0.16.2-2.x86_64.rpm'
      assert_equal 'review_required', subject.run['status']
    end
  end

  def test_invalid_asset_fields_are_not_executable_inputs
    fixture do |subject|
      original = subject.data['assets'][0].dup
      {'id' => '123', 'size' => MoonshineHost::MAX_PACKAGE + 1, 'digest' => 'md5:abc',
       'browser_download_url' => 'https://evil.example/update.rpm', 'name' => '$(touch ignored).rpm'}.each do |key, value|
        subject.data['assets'][0] = original.merge(key => value)
        refute_equal 'eligible', subject.run['status']
      end
      subject.data['assets'][0] = original
      sentinel = subject.root/'release-note-executed'
      subject.data['body'] = "File.write(#{sentinel.to_s.inspect}, 'executed'); $(touch ignored)"
      assert_equal 'eligible', subject.run['status']
      refute sentinel.exist?
    end
  end

  def test_digest_and_size_mismatch_do_not_prepare_a_candidate
    fixture do |subject|
      before = MoonshineCandidate.tree(subject.root)
      subject.data['assets'][0]['digest'] = "sha256:#{'0' * 64}"
      assert_equal 'review_required', subject.run(prepare: true)['status']
      assert_equal before, MoonshineCandidate.tree(subject.root)
      subject.data['assets'][0].delete('digest')
      subject.data['assets'][0]['size'] += 1
      assert_equal 'review_required', subject.run['status']
    end
  end

  def test_current_pin_changed_bytes_require_review
    fixture do |subject|
      current = MoonshineReleases.current(subject.root).release
      subject.bodies[MoonshineUpdate.download_url(current)] = 'changed upstream bytes'
      result = subject.run(prepare: true)
      assert_equal 'review_required', result['status']
      assert_match(/Pinned official RPM changed/, result['reason'])
      assert_empty subject.inspections
    end
  end

  def test_current_release_is_checked_without_checksum_replacement
    fixture do |subject|
      current = MoonshineReleases.current(subject.root).release
      subject.data['tag_name'] = 'v0.16.1'
      subject.data['assets'][0].merge!('name' => current['filename'], 'size' => UpdateFixture::BASELINE.bytesize,
                                      'browser_download_url' => MoonshineUpdate.download_url(current),
                                      'digest' => "sha256:#{current['sha256']}")
      assert_equal 'unchanged', subject.run['status']
      subject.bodies[MoonshineUpdate.download_url(current)] = 'different current bytes'
      assert_equal 'review_required', subject.run['status']
    end
  end

  def test_packaging_change_and_store_failure_preserve_accepted_inputs
    fixture do |subject|
      before = MoonshineCandidate.tree(subject.root)
      subject.change_contract
      assert_equal 'review_required', subject.run(prepare: true)['status']
      assert_equal before, MoonshineCandidate.tree(subject.root)
    end
    fixture do |subject|
      before = MoonshineCandidate.tree(subject.root)
      store = Object.new
      store.define_singleton_method(:prepare) { |*| raise MoonshineUpdate::Failure, 'injected candidate failure' }
      assert_equal 'review_required', subject.run(prepare: true, store: store)['status']
      assert_equal before, MoonshineCandidate.tree(subject.root)
    end
  end

  def test_retained_package_checker_refuses_missing_artifacts_instead_of_skipping
    fixture do |subject|
      before = MoonshineCandidate.tree(subject.root)
      assert_raises(MoonshineUpdate::Failure) do
        MoonshineReleaseCheck.run(root: subject.root, bsdtar: '/missing/bsdtar', client: subject, packages: subject.root)
      end
      assert_equal before, MoonshineCandidate.tree(subject.root)
    end
  end

  def test_deterministic_candidate_and_exact_patch_refusal
    fixture do |subject|
      before = MoonshineCandidate.tree(subject.root)
      result = subject.run(prepare: true)
      assert_equal 'eligible', result['status']
      candidate = Pathname(result.fetch('candidate').fetch('directory'))
      begin
        assert_equal '0.16.2', MoonshineReleases.current(candidate).release['version']
        assert_equal '0.16.1', MoonshineReleases.previous(candidate).release['version']
        assert_equal before, MoonshineCandidate.tree(subject.root)
        first = MoonshineCandidate.patch(subject.root, result['release'])
        assert_equal first, MoonshineCandidate.patch(subject.root, result['release'])
        assert MoonshineCandidate.verify_patch(subject.root, result['release'], first)
        assert_raises(MoonshineUpdate::Failure) do
          MoonshineCandidate.verify_patch(subject.root, result['release'], first.merge('README.md' => 'unexpected edit'))
        end
        assert_raises(MoonshineUpdate::Failure) do
          MoonshineCandidate.verify_patch(subject.root, result['release'], first.merge('lib/moonshine_host.rb' => 'unexpected logic'))
        end
      ensure
        FileUtils.remove_entry_secure(candidate)
      end
    end
  end
end

class ReleaseNetworkTest < Minitest::Test
  def response(body, code: '200', location: nil, length: body.bytesize.to_s)
    klass = code == '200' ? Net::HTTPOK : Net::HTTPFound
    result = klass.new('1.1', code, 'fixture')
    result['location'] = location if location
    result['content-length'] = length if length
    result.define_singleton_method(:read_body) { |&consume| consume.call(body) }
    result
  end

  def test_headers_do_not_forward_api_auth_to_downloads
    calls = []
    transport = ->(uri, headers, &consume) do
      calls << [uri.host, headers.dup]
      consume.call(response('{}'))
    end
    http = MoonshineUpdate::HTTP.new(token: 'fixture-read-token', transport: transport)
    assert_equal({}, http.json(MoonshineUpdate::API))
    http.stream('https://github.com/hgaiser/moonshine/releases/download/v0.16.1/test.rpm', limit: 10) { |_| }
    assert_equal 'Bearer fixture-read-token', calls[0][1]['Authorization']
    refute calls[1][1].key?('Authorization')
  end

  def test_unsafe_urls_are_refused_before_transport
    calls = 0
    http = MoonshineUpdate::HTTP.new(transport: ->(*) { calls += 1 })
    %w[http://github.com/file https://evil.example/file https://github.com:444/file https://user:secret@github.com/file
       https://github.com/file#fragment].each do |url|
      assert_raises(MoonshineUpdate::Failure) { http.stream(url, limit: 10) { |_| } }
    end
    assert_equal 0, calls
  end

  def test_unsafe_redirects_api_redirects_and_redirect_loops
    ['http://github.com/file', 'https://evil.example/file'].each do |location|
      http = MoonshineUpdate::HTTP.new(transport: ->(_, _, &consume) { consume.call(response('', code: '302', location: location)) })
      assert_raises(MoonshineUpdate::Failure) { http.stream('https://github.com/file', limit: 10) { |_| } }
    end
    http = MoonshineUpdate::HTTP.new(transport: ->(_, _, &consume) { consume.call(response('', code: '302', location: '/file')) })
    assert_raises(MoonshineUpdate::Failure) { http.json(MoonshineUpdate::API) }
    assert_raises(MoonshineUpdate::Failure) { http.stream('https://github.com/file', limit: 10) { |_| } }
  end

  def test_stream_and_declared_limits_and_truncation
    [['too many bytes', nil], ['small', '99'], ['short', '7']].each do |body, length|
      http = MoonshineUpdate::HTTP.new(transport: ->(_, _, &consume) { consume.call(response(body, length: length)) })
      assert_raises(MoonshineUpdate::Failure) { http.stream('https://github.com/file', limit: 10) { |_| } }
    end
  end

  def test_failed_download_removes_only_its_created_file
    Dir.mktmpdir do |directory|
      path = Pathname(directory)/'package.rpm'
      http = MoonshineUpdate::HTTP.new(transport: ->(_, _, &consume) { consume.call(response('oversize', length: '999999999')) })
      assert_raises(MoonshineUpdate::Failure) { http.download('https://github.com/file', path) }
      refute path.exist?
      path.write('existing user file')
      assert_raises(Errno::EEXIST) { http.download('https://github.com/file', path) }
      assert_equal 'existing user file', path.read
    end
  end
end

class ReleaseContractTest < Minitest::Test
  include TestStubs
  def test_all_unsupported_executable_tag_forms_require_review
    MoonshineUpdate::UNSUPPORTED_EXECUTABLE_TAGS.each do |tag|
      assert_raises(MoonshineUpdate::Failure) { MoonshineUpdate::Contract.stable_tags({tag => 'unreviewed executable metadata'}) }
    end
    assert_equal({1024 => 'reviewed', 1086 => ['/bin/sh']}, MoonshineUpdate::Contract.stable_tags({1024 => 'reviewed', 1086 => ['/bin/sh']}))
  end

  def test_only_binary_content_and_bounded_build_metadata_can_differ
    baseline = {'tags' => MoonshineUpdate::Contract.stable_tags({1000 => 'moonshine', 1001 => '0.16.1', 1039 => ['root']}),
                'inventory' => {'/usr/bin/moonshine' => 0100755}, 'dependencies' => ['libc.so.6'], 'protected' => {'wrapper' => 'same'}}
    candidate = Marshal.load(Marshal.dump(baseline))
    candidate['tags'] = MoonshineUpdate::Contract.stable_tags({1000 => 'moonshine', 1001 => '0.16.2', 1039 => ['root']})
    assert MoonshineUpdate::Contract.compare(baseline, candidate)
    {'tags' => {1039 => ['other']}, 'inventory' => {'/usr/bin/moonshine' => 0100644},
     'dependencies' => ['other.so'], 'protected' => {'wrapper' => 'changed'}}.each do |field, value|
      assert_raises(MoonshineUpdate::Failure) { MoonshineUpdate::Contract.compare(baseline, candidate.merge(field => value)) }
    end
    assert_equal %w[/usr/bin/moonshine /usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so], MoonshineUpdate::BINARY_PATHS
  end

  def test_only_exact_release_identity_is_normalized_in_source_and_provides
    signatures = %w[0.16.0 0.16.1].map do |version|
      tags = {1044 => "moonshine-#{version}-1.src.rpm", 1047 => ['moonshine', 'other-library'],
              1112 => [8, 8], 1113 => ["#{version}-1", '2.0']}
      release = {'version' => version}
      normalized = MoonshineUpdate::Contract.stable_tags(tags, release: release)
      assert_equal ["#{version}-1", '2.0'], tags[1113]
      assert_raises(MoonshineUpdate::Failure) do
        MoonshineUpdate::Contract.stable_tags(tags.merge(1044 => 'unrelated-1.src.rpm'), release: release)
      end
      assert_raises(MoonshineUpdate::Failure) do
        MoonshineUpdate::Contract.stable_tags(tags.merge(1113 => ['wrong-version', '2.0']), release: release)
      end
      assert_raises(MoonshineUpdate::Failure) do
        MoonshineUpdate::Contract.stable_tags(tags.merge(1112 => [12, 8]), release: release)
      end
      normalized
    end
    assert_equal signatures[0], signatures[1]
    changed_other_provide = signatures[1].merge(1113 => ['RELEASE-1', '3.0'])
    refute_equal signatures[0], changed_other_provide
  end

  def test_extract_adapter_hashes_exactly_the_eight_protected_files
    inventory = (MoonshineHost::PAYLOAD.keys + MoonshineHost::HOST_FILES.keys).to_h { |name| [name, 0100644] }
    rpm = Object.new
    rpm.define_singleton_method(:validate) { |release: MoonshineHost::RELEASE| raise 'wrong expected release' unless release == MoonshineHost::RELEASE; inventory }
    rpm.define_singleton_method(:dependencies) { ['libc.so.6'] }
    rpm.define_singleton_method(:tags) { {1000 => 'moonshine'} }
    calls = []
    extract = ->(path, files, root, bsdtar:) do
      calls << [path, files, bsdtar]
      files.each_key do |name|
        target = root/name.delete_prefix('/')
        target.dirname.mkpath
        target.write(name)
      end
    end
    stubs(MoonshineHost::Rpm, new: rpm) do
      stubs(MoonshineHost, extract: extract) do
        result = MoonshineUpdate::Contract.new(bsdtar: RbConfig.ruby).inspect('fixture.rpm', MoonshineHost::RELEASE)
        assert_equal 8, result['protected'].length
        assert_equal inventory.keys.sort - MoonshineUpdate::BINARY_PATHS.sort, result['protected'].keys.sort
        assert_equal [['fixture.rpm', inventory, RbConfig.ruby]], calls
      end
    end
  end

  def test_char_tags_are_retained_and_unknown_types_cannot_disappear
    [1, 0, 10, 99].each do |kind|
      bytes = "\x8e\xad\xe8\x01".b + [0, 1, 1].pack('N3') + [7000, kind, 0, 1].pack('N4') + "\x01".b
      if kind == 1
        assert_equal({7000 => [1]}, MoonshineHost::Rpm.header(StringIO.new(bytes)))
      else
        assert_raises(MoonshineHost::Failure) { MoonshineHost::Rpm.header(StringIO.new(bytes)) }
      end
    end
  end
end

# Read-only official release detection. Never execute downloaded package content.
require 'net/http'
require 'uri'
require 'openssl'
require 'tmpdir'
require_relative 'release_catalog'
require_relative 'moonshine_host' unless defined?(MoonshineHost::RELEASE)

module MoonshineUpdate
  extend self
  class Failure < StandardError; end
  API = 'https://api.github.com/repos/hgaiser/moonshine/releases/latest'.freeze
  MAX_METADATA = 2 * 1024 * 1024
  DOWNLOAD_HOSTS = %w[github.com release-assets.githubusercontent.com objects.githubusercontent.com].freeze
  BINARY_PATHS = %w[/usr/bin/moonshine /usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so].freeze
  # Derived from RPM's public rpmtag.h. Every other tag is compared, including unknown tags.
  VOLATILE_TAGS = [63, 1001, 1006, 1007, 1009, 1028, 1034, 1035, 1046, 5008, 5009,
                   5092, 5097, 5112, 5113, 5118, 5121, 5122, 5123, 5124].freeze
  UNSUPPORTED_EXECUTABLE_TAGS = [1023, 1025, 1065, 1066, 1067, 1068, 1069, 1079, 1085, 1087,
                               1091, 1092, 1100, 1101, 1102, 1151, 1152, 1153, 1154, 1171,
                               5020, 5022, 5024, 5025, 5026, 5027,
                               *(5063..5082), 5084, 5085, 5086, 5087, 5088, 5089,
                               *(5103..5108), 5109].freeze

  def check(condition, message)
    raise Failure, message unless condition
  end

  def download_url(release)
    release = MoonshineReleases.metadata(release)
    "https://github.com/hgaiser/moonshine/releases/download/v#{release['version']}/#{release['filename']}"
  end

  class HTTP
    def initialize(token: nil, transport: nil)
      @token = token
      @transport = transport || method(:request)
    end

    def uri(value, api: false)
      parsed = URI.parse(value)
      hosts = api ? ['api.github.com'] : DOWNLOAD_HOSTS
      MoonshineUpdate.check(parsed.is_a?(URI::HTTPS) && parsed.port == 443 && hosts.include?(parsed.host) &&
                            !parsed.userinfo && !parsed.fragment, 'Unapproved HTTPS endpoint or redirect')
      parsed
    rescue URI::InvalidURIError
      raise Failure, 'Invalid HTTPS endpoint'
    end

    def request(endpoint, headers, &consume)
      http = Net::HTTP.new(endpoint.host, endpoint.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 10
      http.read_timeout = 30
      http.write_timeout = 30
      http.max_retries = 0
      http.start { |connection| connection.request(Net::HTTP::Get.new(endpoint.request_uri, headers), &consume) }
    end

    def stream(value, limit:, api: false, &consume)
      endpoint = uri(value, api: api)
      headers = {'User-Agent' => 'moonshine-tap-release-validator', 'Accept' => 'application/octet-stream'}
      if api
        headers['Accept'] = 'application/vnd.github+json'
        headers['X-GitHub-Api-Version'] = '2022-11-28'
        headers['Authorization'] = "Bearer #{@token}" if @token && !@token.empty?
      end
      redirects = 0
      loop do
        location = nil
        @transport.call(endpoint, headers) do |response|
          if response.is_a?(Net::HTTPRedirection)
            MoonshineUpdate.check(!api && redirects < 4, 'Metadata redirect or redirect limit exceeded')
            location = response['location']
            MoonshineUpdate.check(location.is_a?(String) && location.bytesize <= 8192, 'Invalid redirect location')
          else
            MoonshineUpdate.check(response.is_a?(Net::HTTPSuccess) && response.code == '200',
                                  "Official endpoint returned HTTP #{response.code}")
            length = response['content-length']
            MoonshineUpdate.check(!length || (length.match?(/\A\d+\z/) && length.to_i <= limit), 'Response exceeds byte limit')
            total = 0
            response.read_body do |chunk|
              total += chunk.bytesize
              MoonshineUpdate.check(total <= limit, 'Response exceeds byte limit')
              consume.call(chunk)
            end
            MoonshineUpdate.check(!length || total == length.to_i, 'Truncated response body')
            return total
          end
        end
        endpoint = uri(URI.join(endpoint.to_s, location).to_s, api: false)
        redirects += 1
      end
    end

    def json(value)
      body = +''
      stream(value, limit: MAX_METADATA, api: true) { |chunk| body << chunk }
      JSON.parse(body, max_nesting: 20)
    rescue JSON::ParserError
      raise Failure, 'Invalid official release JSON'
    end

    def download(value, path)
      created = false
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
        created = true
        stream(value, limit: MoonshineHost::MAX_PACKAGE) { |chunk| file.write(chunk) }
      end
      path
    rescue StandardError
      File.unlink(path) if created && File.file?(path) && !File.symlink?(path)
      raise
    end
  end

  class Contract
    def initialize(bsdtar:)
      @bsdtar = bsdtar
    end

    def self.stable_tags(tags, release: nil)
      forbidden = tags.keys & UNSUPPORTED_EXECUTABLE_TAGS
      MoonshineUpdate.check(forbidden.empty?, 'Unsupported RPM scriptlet or trigger metadata requires review')
      stable = tags.reject { |tag, _| VOLATILE_TAGS.include?(tag) }
      if tags.key?(1044)
        MoonshineUpdate.check(release && tags[1044] == "moonshine-#{release.fetch('version')}-1.src.rpm",
                              'Unexpected source-RPM identity requires review')
        stable[1044] = 'moonshine-RELEASE-1.src.rpm'
      end
      if tags.key?(1113)
        names, flags, versions = [1047, 1112, 1113].map { |tag| tags[tag] }
        MoonshineUpdate.check(release && [names, flags, versions].all? { |value| value.is_a?(Array) } &&
                              names.length == flags.length && flags.length == versions.length && names.count('moonshine') == 1,
                              'Malformed package provides require review')
        stable[1113] = versions.dup
        names.each_with_index do |name, index|
          next unless name == 'moonshine'
          MoonshineUpdate.check(flags[index] == 8 && versions[index] == "#{release.fetch('version')}-1",
                                'Unexpected package self-provide requires review')
          stable[1113][index] = 'RELEASE-1'
        end
      end
      stable
    end

    def inspect(path, release)
      release = MoonshineReleases.metadata(release)
      rpm = MoonshineHost::Rpm.new(path)
      inventory = release == MoonshineHost::RELEASE ? rpm.validate : rpm.validate(release: release)
      dependencies = rpm.dependencies
      tags = self.class.stable_tags(rpm.tags, release: release)
      MoonshineUpdate.check(@bsdtar.is_a?(String) && Pathname(@bsdtar).absolute? && File.file?(@bsdtar) &&
                            File.executable?(@bsdtar), 'Real RPM extraction requires an explicit executable bsdtar')
      protected = {}
      Dir.mktmpdir('moonshine-contract-') do |temporary|
        MoonshineHost.extract(path, inventory, Pathname(temporary), bsdtar: @bsdtar)
        inventory.each do |name, mode|
          next unless (mode & 0170000) == 0100000
          extracted = Pathname(temporary)/name.delete_prefix('/')
          protected[name] = Digest::SHA256.file(extracted).hexdigest unless BINARY_PATHS.include?(name)
        end
      end
      {'tags' => tags, 'inventory' => inventory, 'dependencies' => dependencies, 'protected' => protected}
    end

    def self.compare(baseline, candidate)
      %w[tags inventory dependencies protected].each do |field|
        MoonshineUpdate.check(baseline.fetch(field) == candidate.fetch(field), "RPM #{field} changed; review required")
      end
      true
    end
  end

  class Updater
    def initialize(root:, client:, inspector:, store: nil)
      @root, @client, @inspector, @store = root, client, inspector, store
    end

    def select(data, current)
      MoonshineUpdate.check(data.is_a?(Hash) && data['draft'] == false && data['prerelease'] == false,
                            'Only official non-draft stable releases are accepted')
      tag = data['tag_name']
      MoonshineUpdate.check(tag.is_a?(String) && tag.start_with?('v'), 'Unsupported official release tag')
      version = tag.delete_prefix('v')
      order = MoonshineReleases.version(version) <=> MoonshineReleases.version(current['version'])
      return ['unchanged', nil] if order == -1
      filename = "moonshine-#{version}-1.x86_64.rpm"
      assets = data['assets']
      MoonshineUpdate.check(assets.is_a?(Array) && assets.length <= 1000 && assets.all? { |item| item.is_a?(Hash) },
                            'Invalid official release asset list')
      related = assets.select { |item| item['name'].is_a?(String) && item['name'].start_with?("moonshine-#{version}-") &&
                                      item['name'].end_with?('.x86_64.rpm') }
      MoonshineUpdate.check(related.all? { |item| item['name'] == filename }, 'Changed RPM revision requires review')
      matches = related.select { |item| item['name'] == filename }
      MoonshineUpdate.check(matches.length <= 1, 'Ambiguous official RPM assets')
      return ['awaiting_asset', nil] if matches.empty? || matches.first['state'] != 'uploaded'
      asset = matches.first
      MoonshineUpdate.check(asset['id'].is_a?(Integer) && asset['id'] > 0 && asset['size'].is_a?(Integer) &&
                            asset['size'] > 0 && asset['size'] <= MoonshineHost::MAX_PACKAGE, 'Invalid official RPM asset identity or size')
      release = {'version' => version, 'filename' => filename, 'sha256' => current['sha256']}
      MoonshineUpdate.check(asset['browser_download_url'] == MoonshineUpdate.download_url(release), 'Unexpected official RPM URL')
      digest = asset['digest']
      MoonshineUpdate.check(digest.nil? || (digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)), 'Unsupported API asset digest')
      ['selected', asset.merge('version' => version)]
    end

    def run(prepare: false)
      current = MoonshineReleases.current(@root).release
      outcome, asset = select(@client.json(API), current)
      return {'status' => outcome, 'current' => current} unless asset
      Dir.mktmpdir('moonshine-update-') do |temporary|
        baseline_path = Pathname(temporary)/'baseline.rpm'
        @client.download(MoonshineUpdate.download_url(current), baseline_path)
        MoonshineUpdate.check(Digest::SHA256.file(baseline_path).hexdigest == current['sha256'],
                              'Pinned official RPM changed; review required')
        candidate_path = Pathname(temporary)/'candidate.rpm'
        draft = {'version' => asset.fetch('version'), 'filename' => asset.fetch('name'), 'sha256' => current['sha256']}
        @client.download(MoonshineUpdate.download_url(draft), candidate_path)
        MoonshineUpdate.check(candidate_path.size == asset['size'], 'Downloaded RPM size differs from asset metadata')
        digest = Digest::SHA256.file(candidate_path).hexdigest
        MoonshineUpdate.check(!asset['digest'] || asset['digest'] == "sha256:#{digest}", 'Official RPM API digest differs')
        release = MoonshineReleases.metadata(draft.merge('sha256' => digest))
        if release['version'] == current['version']
          MoonshineUpdate.check(release == current, 'Pinned official asset changed; review required')
          return {'status' => 'unchanged', 'current' => current}
        end
        baseline = @inspector.inspect(baseline_path, current)
        candidate = @inspector.inspect(candidate_path, release)
        Contract.compare(baseline, candidate)
        report = {'status' => 'eligible', 'current' => current, 'release' => release, 'asset_id' => asset['id'],
                  'limits' => 'Package comparison only; no host installation, downgrade or streaming acceptance.'}
        if prepare
          MoonshineUpdate.check(@store, 'Candidate preparation requires an explicit disposable-tree adapter')
          report['candidate'] = @store.prepare(@root, release)
        end
        report
      end
    rescue Failure, MoonshineReleases::Failure, MoonshineHost::Failure, KeyError, TypeError, ArgumentError => e
      {'status' => 'review_required', 'reason' => e.message}
    end
  end
end

require_relative 'test_host'

class ServiceCleanupTest < Minitest::Test
  include TestStubs
  H = MoonshineHost
  UNIT = 'moonshine@test.service'

  # Run the real lifecycle against simulated systemd and prepared image/RPM inputs.
  class Systemd
    attr_accessor :reset_error, :discard_on_reload, :start_error, :observation_error, :replacement, :stop_error, :observation_override
    attr_reader :enabled, :active, :calls
    def initialize(template, image, enabled:, running:)
      @template, @image = template, image
      @enabled, @active = enabled, running ? 'active' : 'inactive'
      @present = true
      @calls = []
    end
    def failed_units
      (@present && @active == 'failed' ? [UNIT] : []) + ['other.service']
    end
    def result(text = '', code = 0)
      H::Result.new(stdout: text, stderr: '', returncode: code)
    end
    def command(args, check: true, **_)
      @calls << args
      value = if args.first != 'systemctl'
        result
      else
        verb = args.fetch(1)
        case verb
        when 'list-units', 'list-unit-files'
          result(@present ? "#{UNIT} loaded #{@active}\n" : '')
        when 'is-enabled'
          result(@template.exist? ? @enabled : 'not-found', @template.exist? && @enabled == 'enabled' ? 0 : 4)
        when 'is-active'
          result(@present ? @active : 'inactive', @active == 'active' ? 0 : 3)
        when 'show'
          masked = %w[masked masked-runtime].include?(@enabled)
          load = @replacement ? 'loaded' : masked ? 'masked' : @template.exist? ? 'loaded' : 'not-found'
          fragment = @replacement || (masked ? '/dev/null' : @template.exist? ? @template.to_s : '')
          if args.include?('--property=LoadState,ActiveState,FragmentPath')
            observation_override || (observation_error ? result('', 1) : result("LoadState=#{load}\nActiveState=#{@present ? @active : 'inactive'}\nFragmentPath=#{fragment}\n"))
          elsif args.include?('--property=LoadState')
            result(load)
          elsif args.include?('--property=FragmentPath')
            result(fragment)
          else
            raise "Unexpected property query: #{args.inspect}"
          end
        when 'stop'
          if stop_error
            result('', 1)
          else
            @active = 'failed' if @active == 'active'
            result
          end
        when 'disable'
          @enabled = 'disabled'
          result
        when 'daemon-reload'
          @present = false if !@template.exist? && (discard_on_reload || @active == 'inactive')
          @present = true if @template.exist? || %w[masked masked-runtime].include?(@enabled)
          result
        when 'reset-failed'
          raise 'Unscoped failed-state reset' unless args == ['systemctl', 'reset-failed', UNIT]
          if reset_error
            result('', 1)
          else
            @active = 'inactive'
            @present = @template.exist?
            result
          end
        when 'enable'
          @enabled = 'enabled'
          result
        when 'start'
          if start_error && @image.read == 'new'
            @active = 'failed'
            result('', 1)
          else
            @active = 'active'
            result
          end
        else
          raise "Unexpected systemctl operation: #{args.inspect}"
        end
      end
      raise H::Failure, "Simulated command failed: #{args.join(' ')}" if check && value.returncode != 0
      value
    end
  end

  def scenario(enabled: 'enabled', running: true)
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      template, image = root/'moonshine@.service', root/'active.raw'
      template.write('old template'); image.write('old')
      subject = H::Host.new(root/'state'); subject.root.mkdir
      subject.save('schema'=>1, 'phase'=>'active', 'active'=>'bundle-old', 'recovery'=>nil, 'services'=>{})
      manifests = {}
      %w[old new].each do |version|
        path = subject.root/"bundle-#{version}"
        (path/'host').mkpath
        destination = path/'host'/template.to_s.delete_prefix('/')
        destination.dirname.mkpath; destination.write("#{version} template")
        (path/'image.raw').write(version)
        manifests["bundle-#{version}"] = [path, {'release'=>version == 'new' ? H::RELEASE : {'version'=>'0.0.0'},
          'host'=>{'id'=>'fixture'}, 'host_files'=>{template.to_s=>H.digest(destination)},
          'image_sha256'=>H.digest(path/'image.raw'), 'payload'=>{}}]
      end
      os = Systemd.new(template, image, enabled: enabled, running: running)
      with_constant(H, :IMAGE_PATH, image) do
        with_constant(H, :HOST_FILES, {'/usr/lib/systemd/system/moonshine@.service'=>template.to_s}) do
          with_constant(H, :PAYLOAD, {}) do
            stubs(subject, secure_path:nil, prerequisites:nil, fingerprint:{'id'=>'fixture'},
              bundle:->(name) { manifests.fetch(name) }, build:->(_) { 'bundle-new' },
              validate_cached_image:nil, verify_setup:nil, refresh:nil, scriptlet:nil,
              tool:->(name) { name }, command:os.method(:command)) do
              yield subject, os, image, template
            end
          end
        end
      end
    end
  end

  def test_upgrade_restores_all_independent_enabled_and_running_choices
    %w[enabled disabled].product([true, false]).each do |enabled, running|
      scenario(enabled: enabled, running: running) do |subject, os, image, _|
        subject.uninstall
        saved = subject.state['services']
        subject.install('candidate.rpm')
        assert_equal 'new', image.read
        assert_equal enabled, os.enabled
        assert_equal running ? 'active' : 'inactive', os.active
        assert_equal saved, subject.state['services']
        assert_equal 'bundle-old', subject.state['recovery']
        assert_equal ['other.service'], os.failed_units
      end
    end
  end

  def test_upgrade_from_cached_uninstaller_without_reset_preserves_service_choices
    %w[enabled disabled].product([true, false]).each do |enabled, running|
      scenario(enabled: enabled, running: running) do |subject, os, image, _|
        stubs(subject, reset_removed_services:nil) { subject.uninstall }
        saved = subject.state['services']
        subject.install('candidate.rpm')
        assert_equal 'new', image.read
        assert_equal enabled, os.enabled
        assert_equal running ? 'active' : 'inactive', os.active
        assert_equal saved, subject.state['services']
        assert_equal 'bundle-old', subject.state['recovery']
      end
    end
  end

  def test_conversion_failure_restores_predecessor_after_public_uninstall
    rollback_choices(:build, ->(_) { raise H::Failure, 'injected conversion failure' })
  end

  def test_setup_failure_restores_predecessor_after_public_uninstall
    rollback_choices(:verify_setup, ->(manifest) { raise H::Failure, 'injected setup failure' if manifest['release'] == H::RELEASE })
  end

  def rollback_choices(method, failure)
    %w[enabled disabled].product([true, false]).each do |enabled, running|
      scenario(enabled: enabled, running: running) do |subject, os, image, _|
        subject.uninstall
        saved = subject.state['services']
        stubs(subject, method=>failure) do
          error = assert_raises(H::Failure) { subject.install('candidate.rpm') }
          assert_includes error.message, 'Previous installation restored.'
        end
        assert_equal 'old', image.read
        assert_equal 'bundle-old', subject.state['active']
        assert_equal 'active', subject.state['phase']
        assert_equal saved, subject.state['services']
        assert_equal enabled, os.enabled
        assert_equal running ? 'active' : 'inactive', os.active
        assert_equal ['other.service'], os.failed_units
      end
    end
  end

  def test_start_failure_restores_predecessor_without_erasing_saved_running_choice
    %w[enabled disabled].each do |enabled|
      scenario(enabled: enabled) do |subject, os, image, _|
        subject.uninstall
        saved = subject.state['services']
        os.start_error = true
        error = assert_raises(H::Failure) { subject.install('candidate.rpm') }
        assert_includes error.message, 'Previous installation restored.'
        assert_equal 'old', image.read
        assert_equal saved, subject.state['services']
        assert_equal enabled, os.enabled
        assert_equal 'active', os.active
        assert_equal ['other.service'], os.failed_units
      end
    end
  end

  def test_already_discarded_unit_does_not_fail_upgrade
    scenario do |subject, os, image, _|
      os.discard_on_reload = true
      subject.uninstall
      refute os.calls.any? { |args| args.include?('reset-failed') }
      subject.install('candidate.rpm')
      assert_equal 'new', image.read
      assert_equal 'enabled', os.enabled
      assert_equal 'active', os.active
    end
  end

  def test_cached_recovery_retains_all_independent_service_choices
    %w[enabled disabled].product([true, false]).each do |enabled, running|
      scenario(enabled: enabled, running: running) do |subject, os, image, _|
        subject.uninstall
        saved = subject.state['services']
        subject.recover
        assert_equal 'old', image.read
        assert_equal saved, subject.state['services']
        assert_equal enabled, os.enabled
        assert_equal running ? 'active' : 'inactive', os.active
        assert_equal ['other.service'], os.failed_units
      end
    end
  end

  def test_incomplete_uninstall_keeps_failed_record_until_cleanup_succeeds
    scenario do |subject, os, _, _|
      stubs(subject, refresh: -> { raise H::Failure, 'injected refresh failure' }) do
        assert_raises(H::Failure) { subject.uninstall }
      end
      assert_includes os.failed_units, UNIT
      refute os.calls.any? { |args| args.include?('reset-failed') }
      saved = subject.state['services']
      assert_equal 'removing', subject.state['phase']
      subject.uninstall
      assert_equal ['other.service'], os.failed_units
      assert_equal saved, subject.state['services']
      assert_equal 'removed', subject.state['phase']
    end
  end

  def test_reset_failure_is_reported_and_retry_preserves_original_service_choices
    scenario do |subject, os, image, _|
      os.reset_error = true
      error = assert_raises(H::Failure) { subject.uninstall }
      assert_includes error.message, 'reset-failed'
      assert_equal 'removing', subject.state['phase']
      saved = subject.state['services']
      assert_equal({UNIT=>{'enabled'=>'enabled', 'running'=>true}}, saved)
      os.reset_error = false
      subject.recover
      assert_equal 'old', image.read
      assert_equal saved, subject.state['services']
      assert_equal 'active', os.active
      assert_equal ['other.service'], os.failed_units
    end
  end

  def test_uninspectable_status_is_not_treated_as_a_missing_unit
    scenario do |subject, os, _, _|
      os.observation_error = true
      error = assert_raises(H::Failure) { subject.uninstall }
      assert_includes error.message, 'Cannot inspect removed service'
      refute os.calls.any? { |args| args.include?('reset-failed') }
      assert_equal 'removing', subject.state['phase']
    end
  end

  def test_administrator_masks_survive_uninstall_and_reinstall
    %w[masked masked-runtime].each do |enabled|
      scenario(enabled: enabled, running: false) do |subject, os, image, _|
        subject.uninstall
        saved = subject.state['services']
        assert_equal({UNIT=>{'enabled'=>enabled, 'running'=>false}}, saved)
        refute os.calls.any? { |args| args.include?('reset-failed') }
        subject.install('candidate.rpm')
        assert_equal 'new', image.read
        assert_equal enabled, os.enabled
        assert_equal 'inactive', os.active
        assert_equal saved, subject.state['services']
      end
    end
  end

  def test_malformed_or_live_status_refuses_cleanup_without_clearing_records
    ["LoadState=not-found\nActiveState=failed\n", "LoadState=not-found\nActiveState=failed\nFragmentPath=\nActiveState=inactive\n",
     "LoadState=not-found\nActiveState=active\nFragmentPath=\n", "LoadState=not-found\nActiveState=deactivating\nFragmentPath=\n"].each do |properties|
      scenario do |subject, os, _, _|
        os.observation_override = os.result(properties)
        assert_raises(H::Failure) { subject.uninstall }
        refute os.calls.any? { |args| args.include?('reset-failed') }
        assert_equal 'removing', subject.state['phase']
      end
    end
  end

  def test_saved_glob_cannot_reset_other_instances
    %w[moonshine@*.service moonshine@?.service moonshine@[ab].service].each do |unit|
      scenario do |subject, os, _, _|
        value = subject.state
        value['phase'] = 'removing'
        value['services'] = {unit=>{'enabled'=>'disabled', 'running'=>false}}
        subject.save(value)
        assert_raises(H::Failure) { subject.uninstall }
        refute os.calls.any? { |args| args.include?('stop') || args.include?('reset-failed') }
      end
    end
  end

  def test_nonzero_show_result_is_not_accepted_even_with_missing_unit_properties
    scenario do |subject, os, _, _|
      os.observation_override = os.result("LoadState=not-found\nActiveState=inactive\nFragmentPath=\n", 4)
      assert_raises(H::Failure) { subject.uninstall }
      refute os.calls.any? { |args| args.include?('reset-failed') }
    end
  end

  def test_replacement_unit_is_not_reset
    scenario do |subject, os, _, _|
      reload = os.method(:command)
      runner = ->(args, **options) do
        os.replacement = '/etc/systemd/system/administrator.service' if args.include?('daemon-reload')
        reload.call(args, **options)
      end
      stubs(subject, command: runner) do
        error = assert_raises(H::Failure) { subject.uninstall }
        assert_includes error.message, 'ownership changed after removal'
      end
      refute os.calls.any? { |args| args.include?('reset-failed') }
    end
  end

  def test_failed_stop_does_not_remove_integration_or_clear_failed_records
    scenario do |subject, os, image, template|
      os.stop_error = true
      assert_raises(H::Failure) { subject.uninstall }
      assert image.file?
      assert template.file?
      refute os.calls.any? { |args| args.include?('reset-failed') }
      assert_equal 'removing', subject.state['phase']
    end
  end

  def test_uninstall_clears_only_removed_instances_and_preserves_recovery_choices
    scenario do |subject, os, image, template|
      subject.uninstall
      assert_equal ['other.service'], os.failed_units
      assert_equal({UNIT=>{'enabled'=>'enabled', 'running'=>true}}, subject.state['services'])
      assert_equal 'bundle-old', subject.state['recovery']
      assert_equal 'removed', subject.state['phase']
      refute image.exist?
      refute template.exist?
      assert (subject.root/'bundle-old/image.raw').file?
      subject.uninstall
      assert_equal ['other.service'], os.failed_units
    end
  end
end

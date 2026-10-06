require_relative 'test_host'
class EligibilityTest < Minitest::Test
  include TestStubs
  H=MoonshineHost
  def with_boot_marker
    Dir.mktmpdir do |dir|
      marker=Pathname(dir)/'ostree-booted';marker.write('')
      yield marker
    end
  end
  def validate(release,marker,platform:'x86_64-linux')
    H.validate_host(release,platform:platform,boot_marker:marker)
  end
  def test_fedora_atomic_variants_are_eligible
    with_boot_marker do |marker|
      %w[silverblue kinoite sericea onyx].each do |variant|
        release={'ID'=>'fedora','VARIANT_ID'=>variant,'VERSION_ID'=>'44'}
        assert_equal release,validate(release,marker)
      end
    end
  end
  def test_fedora_based_ublue_and_custom_images_are_eligible
    with_boot_marker do |marker|
      %w[bazzite bluefin aurora custom-image].each do |id|
        release={'ID'=>id,'ID_LIKE'=>'custom fedora','VERSION_ID'=>'44'}
        assert_equal release,validate(release,marker)
      end
    end
  end
  def test_ancestry_is_tokenized_not_substring_matched
    with_boot_marker do |marker|
      assert_equal 'bluefin',validate({'ID'=>'bluefin','ID_LIKE'=>"custom\tfedora  "},marker)['ID']
      ['notfedora','fedora-like','Fedora',''].each do |like|
        error=assert_raises(H::Failure) { validate({'ID'=>'custom','ID_LIKE'=>like},marker) }
        assert_includes error.message,'Fedora-based Atomic'
      end
    end
  end
  def test_image_names_do_not_override_non_fedora_ancestry
    with_boot_marker do |marker|
      %w[bazzite bluefin aurora].each do |id|
        assert_raises(H::Failure) { validate({'ID'=>id},marker) }
        assert_raises(H::Failure) { validate({'ID'=>id,'ID_LIKE'=>'centos rhel'},marker) }
      end
    end
  end
  def test_enterprise_ancestry_is_rejected_even_with_fedora_token
    with_boot_marker do |marker|
      %w[centos rhel rocky almalinux ol].each do |id|
        assert_raises(H::Failure) { validate({'ID'=>id,'ID_LIKE'=>'fedora'},marker) }
        assert_raises(H::Failure) { validate({'ID'=>'bluefin','ID_LIKE'=>"#{id} fedora"},marker) }
      end
    end
  end
  def test_unrelated_distributions_are_rejected
    with_boot_marker do |marker|
      %w[ubuntu debian arch steamos].each do |id|
        assert_raises(H::Failure) { validate({'ID'=>id,'ID_LIKE'=>'debian'},marker) }
      end
    end
  end
  def test_host_identity_must_be_present_safe_and_non_wildcard
    with_boot_marker do |marker|
      [nil,'','_any',"bluefin\nID=_any",'bluefin extra'].each do |id|
        assert_raises(H::Failure) { validate({'ID'=>id,'ID_LIKE'=>'fedora'},marker) }
      end
    end
  end
  def test_linux_x86_64_is_required
    with_boot_marker do |marker|
      %w[aarch64-linux arm64-linux x86_64-darwin25 arm64-darwin25 i686-linux].each do |platform|
        error=assert_raises(H::Failure) { validate({'ID'=>'fedora'},marker,platform:platform) }
        assert_includes error.message,'Linux x86_64'
      end
    end
  end
  def test_fedora_workstation_without_boot_marker_is_rejected
    with_boot_marker do |marker|
      marker.unlink
      error=assert_raises(H::Failure) { validate({'ID'=>'fedora','VARIANT_ID'=>'workstation'},marker) }
      assert_includes error.message,'OSTree-booted'
    end
  end
  def test_variant_label_is_not_proof_of_atomic_boot
    with_boot_marker do |marker|
      marker.unlink
      assert_raises(H::Failure) { validate({'ID'=>'fedora','VARIANT_ID'=>'silverblue'},marker) }
      assert_raises(H::Failure) { validate({'ID'=>'bluefin','ID_LIKE'=>'fedora'},marker) }
    end
  end
  def test_boot_marker_must_be_a_regular_file_not_a_symlink_or_directory
    with_boot_marker do |marker|
      link=marker.dirname/'alias';link.make_symlink(marker)
      assert_raises(H::Failure) { validate({'ID'=>'fedora'},link) }
      assert_raises(H::Failure) { validate({'ID'=>'fedora'},marker.dirname) }
    end
  end
  def test_prerequisites_call_eligibility_before_host_tools
    subject=H::Host.new;checked=false;calls=[]
    release={'ID'=>'bluefin','ID_LIKE'=>'fedora'}
    stubs(subject,os_release:release,validate_host:->(value) { checked=true;assert_equal release,value;raise H::Failure,'ineligible host' },
      tool:->(name) { calls<<name }) do
      assert_raises(H::Failure) { subject.prerequisites }
    end
    assert checked;assert_empty calls
  end
  def test_broader_eligibility_retains_selinux_and_systemd_gates
    Dir.mktmpdir do |dir|
      policy=Pathname(dir)/'file_contexts';policy.write('policy')
      subject=H::Host.new;release={'ID'=>'bluefin','ID_LIKE'=>'fedora'}
      [['Permissive','systemd 259','SELinux'],['Enforcing','systemd 256','systemd 257+']].each do |selinux,systemd,message|
        runner=->(args,**_) do
          text=args.first=='getenforce' ? selinux : args.first=='systemd-sysext' ? systemd : ''
          H::Result.new(stdout:text,stderr:'',returncode:args.first=='rpm' ? 1 : 0)
        end
        with_constant(H,:POLICY,policy) do
          stubs(subject,os_release:release,validate_host:release,tool:->(name) { name },command:runner) do
            error=assert_raises(H::Failure) { subject.prerequisites }
            assert_includes error.message,message
          end
        end
      end
    end
  end
  def test_extension_metadata_keeps_exact_derivative_id_not_ancestry_or_wildcard
    release={'ID'=>'bluefin','ID_LIKE'=>'fedora','VERSION_ID'=>'44'}
    assert_equal "ID=bluefin\nARCHITECTURE=x86-64\nSYSEXT_SCOPE=system\nVERSION_ID=44\n",H.extension_metadata(release)
  end
  def test_extension_metadata_rejects_wildcard_even_when_called_directly
    error=assert_raises(H::Failure) { H.extension_metadata({'ID'=>'_any','VERSION_ID'=>'44'}) }
    assert_includes error.message,'Wildcard'
  end
  def test_extension_level_takes_precedence_over_version
    release={'ID'=>'aurora','VERSION_ID'=>'44','SYSEXT_LEVEL'=>'44.1'}
    assert_equal "ID=aurora\nARCHITECTURE=x86-64\nSYSEXT_SCOPE=system\nSYSEXT_LEVEL=44.1\n",H.extension_metadata(release)
  end
  def test_extension_metadata_still_rejects_missing_or_unsafe_values
    [{'ID'=>'fedora'},{'ID'=>'bluefin','VERSION_ID'=>"44\nID=_any"},{'ID'=>'bluefin\nID=_any','VERSION_ID'=>'44'}].each do |release|
      assert_raises(H::Failure) { H.extension_metadata(release) }
    end
  end
  def test_cask_remains_linux_x86_64_and_discloses_untested_images
    source=MoonshineCask.render
    assert_includes source,'depends_on :linux'
    assert_includes source,'depends_on arch: :x86_64'
    assert_includes source,'Fedora Atomic x86_64'
    assert_includes source,'Only Bazzite has lifecycle acceptance; other eligible images are untested.'
  end
end

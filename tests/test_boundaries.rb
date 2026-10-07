require_relative 'test_host'
class BoundaryTest < Minitest::Test
  include TestStubs
  H=MoonshineHost
  def result(text='',code=0)
    H::Result.new(stdout:text,stderr:'',returncode:code)
  end
  def test_bad_conversion_tool_fails_before_bundle_creation
    Dir.mktmpdir do |dir|
      subject=H::Host.new(dir,build_tools:{'bsdtar'=>'/missing/bsdtar'})
      assert_raises(H::Failure) { subject.build('unused.rpm') }
      assert_empty Dir.children(dir)
    end
  end
  def test_cached_image_unmounts_and_cleans_view_after_symbol_failure
    Dir.mktmpdir do |dir|
      root=Pathname(dir);subject=H::Host.new(root);calls=[]
      rpm=Object.new;rpm.define_singleton_method(:dependencies) { [] }
      stubs(H::Rpm,new:rpm) do
        stubs(subject,tool:->(n) { n },command:->(args,**_) { calls<<args;result('system_u:object_r:root_t:s0') },
          context:'system_u:object_r:root_t:s0',mounted?:false,verify_elf:->(_) { raise H::Failure,'injected symbol mismatch' }) do
          assert_raises(H::Failure) { subject.validate_cached_image(root,{'payload'=>{}}) }
        end
      end
      assert calls.any? { |a| a.first=='umount' };assert_empty root.children
    end
  end
  def test_external_owned_file_edit_refuses_cleanup
    Dir.mktmpdir do |dir|
      file=Pathname(dir)/'owned.conf';file.write('administrator edit')
      subject=H::Host.new(dir)
      stubs(subject,secure_path:nil) do
        assert_raises(H::Failure) { subject.check_owned('host_files'=>{file.to_s=>'0'*64},'image_sha256'=>'0'*64) }
      end
      assert_equal 'administrator edit',file.read
    end
  end
  def test_cleanup_resumes_without_recapturing_stopped_service
    Dir.mktmpdir do |dir|
      root=Pathname(dir);image=root/'image.raw';file=root/'owned.conf'
      image.write('image');file.write('config');subject=H::Host.new(root/'state')
      subject.root.mkdir;subject.save('schema'=>1,'phase'=>'active','active'=>'bundle-old','recovery'=>nil,'services'=>{})
      snapshot={'moonshine@test.service'=>{'enabled'=>'enabled','running'=>true}}
      manifest={'host_files'=>{file.to_s=>H.digest(file)},'image_sha256'=>H.digest(image)}
      captures=0;refreshes=0;calls=[]
      cmd=->(args,**_) do
        calls << args
        if args.include?('--property=LoadState,ActiveState,FragmentPath')
          response = "LoadState=not-found\nActiveState=inactive\nFragmentPath=\n"
        elsif args.include?('--property=LoadState')
          response = file.exist? ? 'loaded' : 'not-found'
        elsif args.include?('--property=FragmentPath')
          response = H::HOST_FILES['/usr/lib/systemd/system/moonshine@.service']
        elsif args.include?('is-enabled')
          response = 'enabled'
        else
          response = ''
        end
        result(response)
      end
      with_constant(H,:IMAGE_PATH,image) do
        stubs(subject,secure_path:nil,bundle:[root,manifest],tool:->(n) { n },command:cmd,scriptlet:nil,
          capture_services:-> { captures+=1;snapshot },refresh:-> { refreshes+=1;raise H::Failure,'injected refresh failure' if refreshes==1 }) do
          assert_raises(H::Failure) { subject.uninstall }
          assert_equal 'removing',subject.state['phase']
          subject.uninstall
          assert_equal snapshot,subject.state['services'];assert_equal 'removed',subject.state['phase']
        end
      end
      assert_equal 1,captures;assert_equal 1,calls.count { |a| a.include?('stop') }
      refute image.exist?;refute file.exist?
    end
  end
  def test_recovery_refuses_host_fingerprint_change_even_when_already_active
    subject=H::Host.new;checked=false
    value={'phase'=>'active','active'=>'bundle-old','recovery'=>'bundle-old'}
    stubs(subject,state:value,bundle:[Pathname('/unused'),{'host'=>{'id'=>'bazzite','policy'=>'old'}}],fingerprint:{'id'=>'bazzite','policy'=>'changed'},verify_setup:->(_) { checked=true }) do
      assert_raises(H::Failure) { subject.recover }
    end
    refute checked
  end
  def test_cask_formula_wiring_and_system_only_host_path
    source=MoonshineCask.render
    assert_includes source,'depends_on formula: ["libarchive", "erofs-utils"]'
    %w[bsdtar mkfs.erofs fsck.erofs].each { |n| assert_includes source,'/bin/'+n }
    assert_equal '/usr/sbin:/usr/bin:/sbin:/bin',H::SAFE_PATH
  end
end

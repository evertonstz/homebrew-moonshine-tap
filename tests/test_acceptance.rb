require_relative 'test_host'
require_relative '../tools/acceptance'
class AcceptanceTest < Minitest::Test
  include TestStubs
  A=MoonshineAcceptance
  H=MoonshineHost
  def result(text='version')
    H::Result.new(stdout:text,stderr:'',returncode:0)
  end
  def invoke(action,*flags)
    calls=[];code=nil;record=nil
    Dir.mktmpdir do |dir|
      evidence=File.join(dir,'evidence.json');original=File.method(:read)
      runner=->(args,**_) do
        calls << args
        result(case args[0]
        when 'getenforce' then 'Enforcing'
        when 'systemd-sysext' then args.include?('status') ? '[]' : 'version'
        when 'systemctl' then args.include?('is-enabled') ? 'disabled' : 'inactive'
        else 'version'
        end)
      end
      stubs(A,operator_host?:true,run:runner) do
        stubs(Etc,getpwnam:Struct.new(:dir,:uid,:gid).new(dir,1000,1000)) do
          stubs(File,read:->(path,*args) { path=='/etc/os-release' ? "ID=bazzite\n" : original.call(path,*args) }) do
            capture_io { code=A.main([action,'--user','test','--evidence',evidence,*flags]) }
          end
        end
      end
      record=JSON.parse(File.read(evidence))
      assert_equal 0600,File.stat(evidence).mode & 0777
    end
    [code,calls,record]
  end
  def test_inventory_has_no_sudo_or_mutation
    code,calls,record=invoke('inventory')
    assert_equal 0,code
    refute calls.any? { |c| c[0]=='sudo' || c.include?('install') || c.include?('start') || c.include?('stop') }
    assert_includes record['result'],'inventory only'
  end
  def test_install_requires_approval_before_privileged_observation
    code,calls,record=invoke('install','--tap','test/moonshine')
    assert_equal 1,code;refute calls.any? { |c| c[0]=='sudo' }
    assert_includes record['error'],'approve-host-mutation'
  end
  def test_uninstall_requires_interruption_approval_before_sudo
    code,calls,record=invoke('uninstall','--approve-host-mutation')
    assert_equal 1,code;refute calls.any? { |c| c[0]=='sudo' }
    assert_includes record['error'],'approve-service-interruption'
  end
  def test_expected_failure_only_for_upgrade
    code,calls,record=invoke('install','--approve-host-mutation','--expect-failure')
    assert_equal 1,code;refute calls.any? { |c| c[0]=='sudo' }
    assert_includes record['error'],'only supported for upgrade'
  end
  def test_fresh_install_preserves_old_dangling_enablement
    links={'/etc/systemd/system/default.target.wants/moonshine@test.service'=>'/usr/lib/systemd/system/moonshine@.service'}
    before={'service'=>{'enabled'=>'not-found','active'=>'inactive'},'enablement_links'=>links}
    after={'service'=>{'enabled'=>'enabled','active'=>'inactive'},'enablement_links'=>links}
    A.verify_fresh_service(before,after)
    changed=Marshal.load(Marshal.dump(after));changed['enablement_links'].transform_values! { '/etc/systemd/system/moonshine@.service' }
    assert_raises(H::Failure) { A.verify_fresh_service(before,changed) }
  end
  def test_fresh_install_rejects_new_enablement_or_start
    before={'service'=>{'enabled'=>'not-found','active'=>'inactive'},'enablement_links'=>{}}
    after={'service'=>{'enabled'=>'enabled','active'=>'inactive'},'enablement_links'=>{}}
    assert_raises(H::Failure) { A.verify_fresh_service(before,after) }
    after['service']['enabled']='disabled';after['service']['active']='active'
    assert_raises(H::Failure) { A.verify_fresh_service(before,after) }
  end
  def test_healthcheck_uses_named_group_and_effective_gpu_selection
    calls=[]
    stubs(Etc,getpwnam:Struct.new(:uid,:gid).new(1000,1000),getgrnam:Struct.new(:gid).new(2000)) do
      stubs(A,run:->(args,**_) { calls<<args;result('VK_DRIVER_FILES=/admin/nvidia.json SECRET=do-not-forward') }) { A.healthcheck('test') }
    end
    args=calls.last
    assert_includes args,'--gid=2000'
    assert_includes args,'--property=SupplementaryGroups=moonshine'
    assert_includes args,'--setenv=XDG_RUNTIME_DIR=/run/user/1000'
    assert_includes args,'--setenv=VK_DRIVER_FILES=/admin/nvidia.json'
    refute args.any? { |v| v.include?('SECRET=') }
  end
  def test_live_healthcheck_rejected_before_port_probe
    observation={'service'=>{'active'=>'active'},'receipt'=>{'active'=>'bundle-current','services'=>{}}}
    stubs(A,observe:observation) do
      code,_,record=invoke('verify','--approve-host-mutation','--healthcheck')
      assert_equal 1,code;assert_includes record['error'],'binds server ports'
    end
  end
  def test_failed_healthcheck_returns_diagnostic_output
    failure=H::Result.new(stdout:'Port conflicts detected',stderr:'exit-code',returncode:1)
    stubs(Etc,getpwnam:Struct.new(:uid).new(1000),getgrnam:Struct.new(:gid).new(1000)) do
      stubs(A,run:->(args,**opts) { if args.first=='sudo';assert_equal false,opts[:check];failure;else;result('');end }) do
        value=A.healthcheck('test');assert_equal 1,value.returncode;assert_includes value.stdout,'Port conflicts'
      end
    end
  end
  def test_privileged_observation_uses_same_ruby_and_valid_source
    calls=[]
    stubs(Etc,getpwnam:Struct.new(:dir).new('/home/test')) do
      stubs(A,run:->(args,**_) { calls<<args;result(args[0]=='sudo' ? '{"receipt":{}}' : args[0]=='systemd-sysext' ? '[]' : 'inactive') }) do
        assert_equal({},A.observe('test')['receipt'])
      end
    end
    root=calls.find { |a| a[0]=='sudo' }
    assert_equal ['sudo',RbConfig.ruby,'--disable=rubyopt','-e'],root[0,4]
    RubyVM::InstructionSequence.compile(root.last)
    assert_includes root.last,'MoonshineHost.digest'
    refute_includes root.last,'hostname'
  end
  def test_data_and_unrelated_extensions_must_survive
    before={'sysext'=>[{'extensions'=>['other']}],'groups'=>{'input'=>{'gid'=>104}},'data'=>{'config'=>'hash'},'hierarchy_labels'=>{'/usr'=>'context'},'linger_enabled'=>true}
    after=Marshal.load(Marshal.dump(before));after['sysext'][0]['extensions']<<'moonshine-homebrew'
    A.compare(before,after)
    after['data']['config']='changed';assert_raises(H::Failure) { A.compare(before,after) }
    after=Marshal.load(Marshal.dump(before));after['sysext']=[];assert_raises(H::Failure) { A.compare(before,after) }
  end
end

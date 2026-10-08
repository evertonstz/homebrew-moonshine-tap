require 'minitest/autorun'
require 'stringio'
require_relative '../lib/moonshine_host'
require_relative '../tools/generate_cask'

module TestStubs
  def with_constant(target,name,value)
    original=target.const_get(name,false)
    target.send(:remove_const,name);target.const_set(name,value)
    yield
  ensure
    target.send(:remove_const,name);target.const_set(name,original)
  end
  def stubs(target, replacements)
    saved = replacements.to_h { |name,_| [name,[target.singleton_methods(false).include?(name),target.method(name)]] }
    replacements.each do |name,value|
      target.define_singleton_method(name) { |*args,**kwargs,&block| value.respond_to?(:call) ? value.call(*args,**kwargs,&block) : value }
    end
    yield
  ensure
    saved.each do |name,(own,original)|
      target.singleton_class.remove_method(name)
      target.define_singleton_method(name,original) if own
    end
  end
end
class HostTest < Minitest::Test
  include TestStubs
  H = MoonshineHost
  def header(entries)
    data, index = ''.b, ''.b
    entries.each do |tag,kind,value|
      body,count = case kind
      when 6 then [value.b+"\0",1]
      when 8 then [value.map { |x| x.b+"\0" }.join,value.length]
      else [value.pack('N*'),value.length]
      end
      index << [tag,kind,data.bytesize,count].pack('N4')
      data << body
    end
    "\x8e\xad\xe8\x01".b+"\0"*4+[entries.length,data.bytesize].pack('N2')+index+data
  end
  def reviewed
    rpm = H::Rpm.allocate
    names = H::PAYLOAD.keys+H::HOST_FILES.keys
    rpm.instance_variable_set(:@path,Pathname('unused.rpm'))
    rpm.instance_variable_set(:@tags,{1000=>'moonshine',1001=>'0.16.1',1002=>'1',1022=>'x86_64',1027=>names,
      1030=>[0100644]*names.length,1036=>['']*names.length,
      1024=>File.read(File.join(__dir__, 'fixtures/postinstall.sh')).sub(/\n+\z/, '')+"\n",1086=>'/bin/sh',1026=>File.read(File.join(__dir__, 'fixtures/postremove.sh')).sub(/\n+\z/, '')+"\n",1088=>'/bin/sh',
      1049=>['glibc','rpmlib(PayloadIsZstd)'],1048=>[12,0],1050=>['2.38','']})
    rpm
  end
  def temp
    Dir.mktmpdir { |p| yield Pathname(p) }
  end
  def result(text='',code=0)
    H::Result.new(stdout: text,stderr: '',returncode: code)
  end
  def test_decodes_scalar_array_and_integer_tags
    assert_equal({1=>'/bin/sh',2=>['/bin/sh'],3=>[7,8]},H::Rpm.header(StringIO.new(header([[1,6,'/bin/sh'],[2,8,['/bin/sh']],[3,4,[7,8]]]))))
  end
  def test_rejects_truncated_header
    assert_raises(H::Failure) { H::Rpm.header(StringIO.new(header([[1,6,'abc']])[0...-1])) }
  end
  def test_rejects_oversized_header
    assert_raises(H::Failure) { H::Rpm.header(StringIO.new("\x8e\xad\xe8\x01".b+"\0"*4+[10001,0].pack('N2'))) }
  end
  def test_rejects_duplicate_tags
    assert_raises(H::Failure) { H::Rpm.header(StringIO.new(header([[1,6,'a'],[1,6,'b']]))) }
  end
  def test_aggregate_value_limit
    assert_raises(H::Failure) { H::Rpm.header(StringIO.new(header([[1,4,[0]*60000],[2,4,[0]*60000]]))) }
  end
  def test_unterminated_string
    data = header([[1,6,'abc']]); data.setbyte(data.bytesize-1,42)
    assert_raises(H::Failure) { H::Rpm.header(StringIO.new(data)) }
  end
  def test_paths_reject_traversal
    %w[../etc/passwd usr/../../etc/passwd].each { |p| assert_raises(H::Failure) { H.canonical_member(p) } }
  end
  def test_paths_reject_ambiguous_members
    ["usr//bin/moonshine","usr/./bin/moonshine","bad\0path"].each { |p| assert_raises(H::Failure) { H.canonical_member(p) } }
    assert_equal '/usr/bin/moonshine',H.canonical_member('./usr/bin/moonshine')
  end
  def test_scalar_interpreter
    stubs(H,digest: H::RELEASE['sha256']) { assert_equal 10,reviewed.validate.length }
  end
  def test_array_interpreter
    rpm=reviewed;rpm.tags[1086]=['/bin/sh']
    stubs(H,digest: H::RELEASE['sha256']) { assert_equal 10,rpm.validate.length }
  end
  def test_bad_interpreters
    ['/bin/bash','/bin/sh -e',['/bin/sh','-e'],[]].each do |interpreter|
      rpm=reviewed;rpm.tags[1086]=interpreter
      stubs(H,digest: H::RELEASE['sha256']) { assert_raises(H::Failure) { rpm.validate } }
    end
  end
  def test_identity_changes
    [{1000=>'other'},{1022=>'aarch64'},{1001=>'wrong'}].each do |change|
      rpm=reviewed;rpm.tags.merge!(change)
      stubs(H,digest: H::RELEASE['sha256']) { assert_raises(H::Failure) { rpm.validate } }
    end
  end
  def test_scriptlet_changes
    [{1024=>'echo unknown'},{1023=>'echo preinstall'},{1025=>'echo preremove'}].each do |change|
      rpm=reviewed;rpm.tags.merge!(change)
      stubs(H,digest: H::RELEASE['sha256']) { assert_raises(H::Failure) { rpm.validate } }
    end
  end
  def test_inventory_changes
    rpm=reviewed;rpm.tags[1027][0]='/usr/bin/other'
    stubs(H,digest: H::RELEASE['sha256']) { assert_raises(H::Failure) { rpm.validate } }
  end
  def test_checksum_changes
    stubs(H,digest: '0'*64) { assert_raises(H::Failure) { reviewed.validate } }
  end
  def test_special_files_rejected
    [[0120777,'target'],[0010644,''],[0104755,'']].each do |mode,link|
      rpm=reviewed;rpm.tags[1030][0]=mode;rpm.tags[1036][0]=link
      assert_raises(H::Failure) { rpm.inventory }
    end
  end
  def test_requirement_versions
    assert_equal ['glibc >= 2.38'],reviewed.dependencies
  end
  def test_invalid_directory_index
    rpm=reviewed;rpm.tags.delete(1027);rpm.tags.merge!(1117=>['moonshine'],1118=>['/usr/bin/'],1116=>[4])
    assert_raises(H::Failure) { rpm.inventory }
  end
  def test_atomic_private_receipt
    temp do |root|
      path=root/'state.json';H.atomic_write(path,"{\"phase\":\"removed\"}\n")
      assert_equal({'phase'=>'removed'},JSON.parse(path.read));assert_equal 0600,path.stat.mode & 0777
      assert_equal [path],root.children
    end
  end
  def test_os_release_data_not_shell
    temp do |root|
      path=root/'os-release';path.write("ID=bazzite\nNAME=\"Bazzite Linux\"\nVERSION_ID=44\n")
      assert_equal 'Bazzite Linux',H.os_release(path)['NAME']
      path.write("ID=bazzite extra\n");assert_raises(H::Failure) { H.os_release(path) }
    end
  end
  def test_archive_mismatch_before_extraction
    temp do |root|
      stubs(H,tool: 'bsdtar',command: result("./etc/passwd\n")) do
        assert_raises(H::Failure) { H.extract('package.rpm',{'/usr/bin/moonshine'=>0100755},root) }
        assert_empty root.children
      end
    end
  end
  def test_bundle_identifiers
    ['../etc','/tmp/bundle','bundle-../../etc','',nil].each { |n| assert_raises(H::Failure) { H::Host.new.bundle(n) } }
  end
  def test_extension_empty_sentinel
    assert_equal Set['other'],H.extension_names([{'extensions'=>'none'},{'extensions'=>['other']}])
    assert_equal Set['none'],H.extension_names([{'extensions'=>nil},{'extensions'=>[]},{'extensions'=>['none']}])
  end
  def test_extension_bad_schemas
    [[{'extensions'=>'unknown'}],[{'extensions'=>[3]}],[nil],[{}],{}].each { |rows| assert_raises(H::Failure) { H.extension_names(rows) } }
  end
  def test_wrong_elf_architecture
    stubs(H,tool: 'readelf',command: result("Class: ELF64\nMachine: AArch64\n")) { assert_raises(H::Failure) { H.elf_requirements('candidate') } }
  end
  def test_full_staging_context
    temp do |tree|
      (tree/'usr').mkdir
      full=false
      cmd=lambda do |args,**_|
        if args.first=='setfiles'
          assert_equal tree,args.last;full=args.include?('-F');result
        else
          result('system_u:object_r:usr_t:s0')
        end
      end
      stubs(H,tool: ->(n) { n },command: cmd,context: ->(_) { (full ? 'system_u' : 'unconfined_u')+':object_r:usr_t:s0' }) { assert_equal 2,H.label_tree(tree).length }
    end
  end
  def test_staging_context_mismatch_still_fails
    temp do |tree|
      stubs(H,tool: ->(n) { n },command: result('system_u:object_r:root_t:s0'),context: 'unconfined_u:object_r:root_t:s0') { assert_raises(H::Failure) { H.label_tree(tree) } }
    end
  end
  def test_tool_symlinks_resolve
    temp do |root|
      paths={};(root/'cellar').mkdir
      %w[bsdtar mkfs.erofs fsck.erofs].each do |name|
        path=root/'cellar'/name;path.write('tool');path.chmod(0555);link=root/name;link.make_symlink(path)
        paths[name]=link.to_s
      end
      assert_equal paths.transform_values { |p| File.realpath(p) },H.resolve_build_tools(paths)
    end
  end
  def test_invalid_tool_basename
    assert_raises(H::Failure) { H.resolve_build_tools('bsdtar'=>'/tmp/not-bsdtar') }
  end
  def test_missing_explicit_tool_no_fallback
    assert_raises(H::Failure) { H.resolve_build_tools('bsdtar'=>'/no/such/path/bsdtar') }
  end
  def test_tool_permissions_rejected
    temp do |root|
      [0777,06755,0644].each do |mode|
        path=root/'bsdtar';path.write('tool');path.chmod(mode)
        assert_raises(H::Failure) { H.resolve_build_tools('bsdtar'=>path.to_s) }
      end
    end
  end
  def test_relative_tool_rejected
    assert_raises(H::Failure) { H.resolve_build_tools('bsdtar'=>'relative/bsdtar') }
  end
  def test_unknown_tool_override
    assert_raises(H::Failure) { H.resolve_build_tools('systemctl'=>'/usr/bin/systemctl') }
  end
  def test_delayed_tool_resolution
    H::Host.new(build_tools: {'bsdtar'=>'/does/not/exist/bsdtar'})
  end
  def test_conversion_flags_rejected_for_cached_actions
    %w[recover uninstall status purge-recovery].each do |action|
      capture_io { assert_equal 1,H.main([action,'--bsdtar','/missing/bsdtar']) }
    end
  end
  def test_checksum_checked_before_inspect_parser
    temp do |root|
      path=root/'wrong.rpm';path.write('not official')
      _,error=capture_io { assert_equal 1,H.main(['inspect','--rpm',path.to_s]) }
      assert_includes error,'SHA-256 mismatch'
    end
  end
  def test_generator_consistency_and_ruby_only
    assert_equal MoonshineCask.render,(MoonshineCask::ROOT/'Casks/moonshine.rb').read
    refute_includes MoonshineCask.render,'python'
    assert_includes MoonshineCask.render,'run RbConfig.ruby'
  end
  def test_uninstall_has_no_conversion_paths
    block=MoonshineCask.render.split('uninstall_preflight_steps').last.split('caveats').first
    refute_includes block,'--bsdtar';refute_includes block,'--mkfs-erofs'
  end
  def test_official_artifact_extraction
    skip 'Set MOONSHINE_TEST_RPM' unless ENV['MOONSHINE_TEST_RPM']
    rpm=H::Rpm.new(ENV['MOONSHINE_TEST_RPM']);files=rpm.validate
    temp do |root|
      H.extract(rpm.path,files,root,bsdtar: ENV['MOONSHINE_TEST_BSDTAR'])
      assert_equal (H::PAYLOAD.keys+H::HOST_FILES.keys).sort,H.nodes(root).select(&:file?).map { |p| '/'+p.relative_path_from(root).to_s }.sort
      assert_operator (root/'usr/bin/moonshine').size,:>,0
      assert_equal 0755,(root/'usr/bin/start-moonshine.sh').stat.mode & 0777
    end
  end
  def test_restore_enablement_independent_of_running
    %w[enabled disabled].product([true,false]).each do |enabled,running|
      calls=[];subject=H::Host.new
      stubs(subject,tool: ->(n) { n },command: ->(args,**_) { calls<<args;result('active') }) do
        subject.restore_services('moonshine@test.service'=>{'enabled'=>enabled,'running'=>running})
      end
      assert_equal enabled=='enabled',calls.any? { |a| a.include?('enable') }
      assert_equal running,calls.any? { |a| a.include?('start') }
    end
  end
  def test_stop_refuses_changed_fragment
    calls=[];subject=H::Host.new
    cmd=->(args,**_) do
      calls << args
      if args.include?('--property=LoadState')
        response = 'loaded'
      elsif args.include?('--property=FragmentPath')
        response = '/etc/systemd/system/foreign.service'
      else
        response = 'disabled'
      end
      result(response)
    end
    stubs(subject,tool: ->(n) { n },command: cmd) { assert_raises(H::Failure) { subject.stop_services('moonshine@test.service'=>{}) } }
    refute calls.any? { |a| a.include?('stop') }
  end
end
class TransactionHost < MoonshineHost::Host
  attr_accessor :failure,:manifests
  attr_reader :active_version,:running
  def initialize(root,active: true,failure: nil)
    super(root)
    @failure=failure;@active_version=active ? 'old' : nil;@running=active
    @manifests={'bundle-old'=>{'release'=>{'version'=>'older'},'host'=>{'id'=>'bazzite'}},'bundle-new'=>{'release'=>MoonshineHost::RELEASE,'host'=>{'id'=>'bazzite'}}}
    save('schema'=>1,'phase'=>active ? 'active' : 'empty','active'=>active ? 'bundle-old' : nil,'recovery'=>nil,'services'=>{})
  end
  def state; JSON.parse(receipt.read); end
  def prerequisites; end
  def fingerprint; {'id'=>'bazzite'}; end
  def bundle(name); [root/name,manifests.fetch(name)]; end
  def verify_setup(_); end
  def uninstall
    v=state
    if v['phase']=='active'
      v['services']={'moonshine@test.service'=>{'enabled'=>'enabled','running'=>running}}
      v['recovery']=v['active']
    end
    v.merge!('active'=>nil,'phase'=>'removed');save(v);@active_version=nil;@running=false
  end
  def build(_)
    raise MoonshineHost::Failure,'injected converter failure' if failure=='conversion'
    'bundle-new'
  end
  def activate(name)
    v=state;v.merge!('active'=>name,'phase'=>'installing');save(v);@active_version=name.delete_prefix('bundle-')
    raise MoonshineHost::Failure,'injected activation failure' if failure=='activation' && name=='bundle-new'
    raise MoonshineHost::Failure,'injected recovery failure' if failure=='recovery' && name=='bundle-old'
    @running=v['services'].values.any? { |s| s['running'] };v['phase']='active';save(v)
  end
end
class TransactionTest < Minitest::Test
  include TestStubs
  def scenario(**opts)
    Dir.mktmpdir { |root| yield TransactionHost.new(root,**opts) }
  end
  def test_successful_upgrade
    scenario { |s| s.install('candidate');assert_equal 'new',s.active_version;assert s.running;assert_equal 'bundle-old',s.state['recovery'] }
  end
  def test_conversion_failure_restores_previous
    scenario(failure:'conversion') { |s| assert_raises(MoonshineHost::Failure) { s.install('candidate') };assert_equal 'old',s.active_version;assert s.running }
  end
  def test_partial_activation_failure_restores_previous
    scenario(failure:'activation') { |s| assert_raises(MoonshineHost::Failure) { s.install('candidate') };assert_equal 'bundle-old',s.state['active'];assert s.running }
  end
  def test_fresh_install_does_not_start
    scenario(active:false) { |s| s.install('candidate');assert_equal 'new',s.active_version;refute s.running }
  end
  def test_fresh_failure_has_no_recovery_target
    scenario(active:false,failure:'activation') { |s| assert_raises(MoonshineHost::Failure) { s.install('candidate') };assert_nil s.active_version;assert_nil s.state['recovery'] }
  end
  def test_uninstall_retains_only_inactive_recovery
    scenario { |s| s.uninstall;v=s.state;s.uninstall;assert_equal v,s.state;assert_nil s.active_version;refute s.running }
  end
  def test_predecessor_replay_does_not_convert
    scenario { |s| s.uninstall;s.manifests['bundle-old']['release']=MoonshineHost::RELEASE;s.failure='conversion';s.install('old.rpm');assert_equal 'old',s.active_version;assert s.running }
  end
  def test_late_bookkeeping_rollback_uses_cached_old_release
    scenario do |s|
      s.install('candidate')
      s.failure='conversion'
      with_constant(MoonshineHost,:RELEASE,s.manifests['bundle-old']['release']) { s.install('old.rpm') }
      assert_equal 'old',s.active_version;assert s.running
      assert_equal 'bundle-new',s.state['recovery']
    end
  end
  def test_recovery_failure_reports_retained_state
    scenario(failure:'recovery') do |s|
      stubs(s,build: ->(_) { raise MoonshineHost::Failure,'converter failed' }) do
        error=assert_raises(MoonshineHost::Failure) { s.install('candidate') };assert_includes error.message,'Recovery also failed';assert_includes error.message,'state.json'
      end
    end
  end
end

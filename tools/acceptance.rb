#!/usr/bin/env ruby
require_relative '../lib/moonshine_host'
require 'time'
module MoonshineAcceptance
  extend self
  include MoonshineHost
  IMAGE = MoonshineHost::IMAGE_PATH
  STATE = (MoonshineHost::STATE_DIR/'state.json').to_s
  HELPER = (MoonshineHost::STATE_DIR/'helper.rb').to_s
  FILES = MoonshineHost::HOST_FILES.values+[MoonshineHost::DROPIN]
  def run(args,check: true,env: {})
    out,err,status=Open3.capture3(env,*args.map(&:to_s))
    ensure!(!check || status.success?, "#{args.first} exited #{status.exitstatus}: #{err.strip}")
    MoonshineHost::Result.new(stdout: out,stderr: err,returncode: status.exitstatus)
  end
  def operator_host?
    RUBY_PLATFORM.include?('linux') && Process.euid!=0
  end
  def service(user)
    unit="moonshine@#{user}.service"
    {'enabled'=>run(['systemctl','is-enabled',unit],check:false).stdout.strip,
     'active'=>run(['systemctl','is-active',unit],check:false).stdout.strip}
  end
  def observe(user)
    home=Etc.getpwnam(user).dir
    # Use the invoking Ruby interpreter explicitly instead of searching the sudo PATH.
    code=<<~RUBY
      require #{File.expand_path('../lib/moonshine_host.rb',__dir__).inspect}
      user=#{user.inspect}; home=#{home.inspect}; data={}
      [home+'/.config/moonshine',home+'/.local/share/moonshine'].each do |base|
        Dir.glob(base+'/**/*',File::FNM_DOTMATCH).sort.each { |p| data[p]=MoonshineHost.digest(p) if File.file?(p) && !File.symlink?(p) }
      end
      groups={}
      %w[moonshine input video render].each do |name|
        begin
          g=Etc.getgrnam(name);groups[name]={'gid'=>g.gid,'members'=>g.mem.sort}
        rescue ArgumentError
        end
      end
      puts JSON.generate('receipt'=>File.exist?(#{STATE.inspect}) ? JSON.parse(File.read(#{STATE.inspect})) : {},
        'image_exists'=>File.file?(#{IMAGE.to_s.inspect}),'host_files'=>#{FILES.inspect}.to_h { |p| [p,File.file?(p)] },
        'data'=>data,'groups'=>groups,'linger_enabled'=>File.exist?('/var/lib/systemd/linger/'+user),
        'enablement_links'=>Dir.glob('/etc/systemd/system/*.wants/moonshine@'+user+'.service').to_h { |p| [p,File.symlink?(p) ? File.readlink(p) : 'regular file'] },
        'hierarchy_labels'=>%w[/usr /opt].select { |p| File.exist?(p) }.to_h { |p| [p,MoonshineHost.context(p)] })
    RUBY
    result=JSON.parse(run(['sudo',RbConfig.ruby,'--disable=rubyopt','-e',code]).stdout)
    result.merge('service'=>service(user),'selinux'=>run(['getenforce']).stdout.strip,
      'sysext'=>JSON.parse(run(['systemd-sysext','status','--json=short']).stdout))
  end
  def names(observation)
    extension_names(observation.fetch('sysext'))
  end
  def verify_active(observation)
    ensure!(observation['receipt']['phase']=='active','Lifecycle journal is not active')
    ensure!(observation['image_exists'] && observation['host_files'].values.all?, 'Active installation files are missing')
    ensure!(names(observation).include?('moonshine-homebrew'), 'Moonshine is not merged')
    ensure!(observation['selinux']=='Enforcing', 'SELinux is not enforcing')
    (['/usr/bin/moonshine','/usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so']+FILES).each do |p|
      ensure!(run(['sudo','matchpathcon','-V',p],check:false).returncode==0,"Context mismatch: #{p}")
    end
  end
  def healthcheck(user)
    account=Etc.getpwnam(user);group=Etc.getgrnam(user)
    unit_env=run(['systemctl','show',"moonshine@#{user}.service",'--property=Environment','--value']).stdout
    # GPU selection must match the effective service, including administrator drop-ins.
    gpu=Shellwords.split(unit_env).select { |v| v.start_with?('VK_DRIVER_FILES=','VK_ICD_FILENAMES=') }.map { |v| '--setenv='+v }
    run(['sudo','systemd-run','--wait','--pipe','--collect','--unit=moonshine-homebrew-healthcheck','--uid='+user,'--gid='+group.gid.to_s,
      '--property=SupplementaryGroups=moonshine','--setenv=XDG_RUNTIME_DIR=/run/user/'+account.uid.to_s,
      '--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/'+account.uid.to_s+'/bus',*gpu,'/usr/bin/moonshine','healthcheck'],check:false)
  end
  def verify_fresh_service(before,after)
    ensure!(after['service']['active']!='active','First install started the service')
    links=before.fetch('enablement_links',{})
    ensure!(links==after.fetch('enablement_links',{}),'First install changed enablement links')
    ensure!(!%w[enabled enabled-runtime].include?(after['service']['enabled']) || %w[enabled enabled-runtime].include?(before['service']['enabled']) || !links.empty?,'First install enabled the service')
  end
  def compare(before,after)
    ensure!((names(before)-['moonshine-homebrew']).subset?(names(after)), 'An unrelated extension is no longer merged')
    %w[hierarchy_labels linger_enabled].each { |key| ensure!(before[key]==after[key],"Preserved state changed: #{key}") }
    ensure!(before['groups'].all? { |name,value| after['groups'][name]==value }, 'Existing host groups changed')
    ensure!(before['data'].all? { |path,value| after['data'][path]==value }, 'Existing configuration/pairing data changed')
  end
  def main(argv=ARGV)
    options={evidence:'artifacts/acceptance.json'}
    parser=OptionParser.new do |p|
      p.banner='Usage: acceptance.rb ACTION --user ACCOUNT [approval flags]'
      %w[tap user revision evidence].each { |name| p.on('--'+name+' VALUE') { |v| options[name.to_sym]=v } }
      %w[expect-failure healthcheck approve-host-mutation approve-service-interruption].each { |name| p.on('--'+name) { options[name.tr('-','_').to_sym]=true } }
    end
    parser.parse!(argv);action=argv.shift
    evidence={'action'=>action}
    begin
      ensure!(operator_host?,'Run as the normal Homebrew user on the eligible Fedora Atomic host, not root')
      user=options[:user]
      ensure!(user && user.match?(/\A[a-z_][a-z0-9_-]{0,31}\z/),'Provide an explicit valid streaming --user')
      Etc.getpwnam(user)
      ensure!(argv.empty? && %w[inventory install upgrade uninstall recover verify].include?(action),parser.to_s)
      evidence.merge!('os_release'=>File.read('/etc/os-release'),'kernel'=>run(['uname','-sr']).stdout.strip,
        'homebrew'=>run(['brew','--version']).stdout.strip,'systemd'=>run(['systemd-sysext','--version']).stdout.strip,'selinux'=>run(['getenforce']).stdout.strip)
      if action=='inventory'
        evidence.merge!('service'=>service(user),'sysext'=>JSON.parse(run(['systemd-sysext','status','--json=short']).stdout),'result'=>'inventory only; no sudo or host changes')
        return 0
      end
      ensure!(options[:approve_host_mutation],'This stage requires explicit --approve-host-mutation')
      ensure!(!options[:expect_failure] || action=='upgrade','--expect-failure is only supported for upgrade')
      ensure!(options[:approve_service_interruption],'This stage requires explicit --approve-service-interruption') if %w[upgrade uninstall recover].include?(action)
      before = observe(user)
      evidence['before'] = before
      if options[:healthcheck]
        resuming=%w[install recover].include?(action) && !before['receipt']['active'] && before['receipt'].fetch('services',{}).values.any? { |s| s['running'] }
        ensure!(before['service']['active']!='active' && !resuming,'Healthcheck binds server ports: stop Moonshine and run verify --healthcheck separately without resuming retained running instances')
      end
      if action=='install' && (before['receipt']['active'] || before['receipt'].fetch('services',{}).values.any? { |s| s['running'] })
        ensure!(options[:approve_service_interruption],'Install/reinstall can resume retained instances; approve service interruption')
      end
      if %w[install upgrade uninstall].include?(action)
        tap=options[:tap]
        ensure!(tap && tap.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/),'Provide the registered unofficial --tap')
        repo=run(['brew','--repo',tap]).stdout.strip
        if options[:revision]
          ensure!(action=='upgrade' && !options[:revision].start_with?('-'),'Invalid candidate revision or action')
          ensure!(run(['git','-C',repo,'status','--porcelain']).stdout.strip.empty?,'Tap checkout must be clean')
          run(['git','-C',repo,'checkout','--detach',options[:revision]])
        end
        # Inherit the terminal so Homebrew and sudo can receive operator input.
        # Explicit host approval permits bypassing only the Homebrew confirmation prompt.
        args=['brew',action]
        args << '--yes' unless action=='uninstall'
        args += ['--cask',tap+'/moonshine']
        ok=system({'HOMEBREW_NO_AUTO_UPDATE'=>'1','HOMEBREW_NO_INSTALL_CLEANUP'=>'1','SUDO_ASKPASS'=>nil,'SSH_ASKPASS'=>nil},*args)
        code=$?.exitstatus
        evidence['brew']={'returncode'=>code,'command'=>args,'output'=>'inherited terminal; retain console log with evidence'}
        ensure!((!ok)==!!options[:expect_failure],'Homebrew outcome differs from expected success/failure')
      elsif action=='recover'
        run(['sudo',HELPER,'recover'])
      end
      after = observe(user)
      evidence['after'] = after
      compare(before,after)
      if action=='uninstall'
        ensure!(!after['image_exists'] && !after['host_files'].values.any? && after['receipt']['active'].nil?,'Uninstall left owned active files/state')
        ensure!(after['service']['active']!='active' && !%w[enabled enabled-runtime].include?(after['service']['enabled']),'Uninstall left instance active/enabled')
        ensure!(!names(after).include?('moonshine-homebrew'),'Uninstall left Moonshine merged')
      else
        verify_active(after)
        if action=='install' && !before['receipt']['active'] && before['receipt'].fetch('services',{}).empty?
          verify_fresh_service(before,after)
        end
        if action=='upgrade'
          ensure!(before['service']==after['service'],'Upgrade changed selected service state')
          same=before['receipt']['active']==after['receipt']['active']
          ensure!(same==!!options[:expect_failure],'Upgrade/recovery bundle outcome differs from expectation')
        end
        if options[:healthcheck]
          result = healthcheck(user)
          evidence['healthcheck'] = {'returncode'=>result.returncode,'stdout'=>result.stdout,'stderr'=>result.stderr}
          ensure!(result.returncode==0,'Moonshine healthcheck failed; full diagnostic output is retained in private evidence')
        end
      end
      evidence['result']='stage checks passed; streaming/input and reboot require separate observations'
      0
    rescue StandardError => e
      evidence['result'] = 'failed'
      evidence['error'] = e.message
      warn e.message
      1
    ensure
      evidence['recorded_at']=Time.now.utc.iso8601
      path = Pathname(options[:evidence])
      path.dirname.mkpath
      File.open(path,File::WRONLY|File::CREAT|File::TRUNC,0600) do |f|
        f.chmod(0600)
        f.write(JSON.pretty_generate(evidence)+"\n")
      end
      puts 'Private acceptance evidence: '+path.to_s
    end
  end
end
exit MoonshineAcceptance.main if $PROGRAM_NAME == __FILE__

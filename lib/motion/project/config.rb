require 'motion/plist'

module Motion; module Project
  class Config
    VARS = []

    def self.variable(*syms)
      syms.each do |sym|
        attr_accessor sym
        VARS << sym.to_s
      end
    end

    class Deps < Hash
      def []=(key, val)
        key = relpath(key)
        val = [val] unless val.is_a?(Array)
        val = val.map { |x| relpath(x) }
        super
      end

      def relpath(path)
        /^\./.match(path) ? path : File.join('.', path)
      end
    end

    variable :files, :platforms_dir, :sdk_version, :deployment_target,
      :frameworks, :libs, :delegate_class, :name, :build_dir, :resources_dir,
      :specs_dir, :identifier, :codesign_certificate, :provisioning_profile,
      :device_family, :interface_orientations, :version, :icons,
      :prerendered_icon, :seed_id, :entitlements

    def initialize(project_dir)
      @project_dir = project_dir
      @files = Dir.glob(File.join(project_dir, 'app/**/*.rb'))
      @dependencies = {}
      @platforms_dir = File.join(`/usr/bin/xcode-select -print-path`.strip, 'Platforms')
      @frameworks = ['UIKit', 'Foundation', 'CoreGraphics']
      @libs = []
      @delegate_class = 'AppDelegate'
      @name = 'Untitled'
      @resources_dir = File.join(project_dir, 'resources')
      @build_dir = File.join(project_dir, 'build')
      @specs_dir = File.join(project_dir, 'spec')
      @device_family = :iphone
      @bundle_signature = '????'
      @interface_orientations = [:portrait, :landscape_left, :landscape_right]
      @version = '1.0'
      @icons = []
      @prerendered_icon = false
      @vendor_projects = []
      @entitlements = {}
    end

    def variables
      map = {}
      VARS.each do |sym|
        map[sym] =
          begin
            send(sym)
          rescue Exception
            'Error'
          end
      end
      map
    end

    def validate
      # sdk_version
      ['iPhoneSimulator', 'iPhoneOS'].each do |platform|
        sdk_path = File.join(platforms_dir, platform + '.platform',
            "Developer/SDKs/#{platform}#{sdk_version}.sdk")
        unless File.exist?(sdk_path)
          App.fail "Can't locate #{platform} SDK #{sdk_version} at `#{sdk_path}'" 
        end
      end

      # deployment_target
      if deployment_target > sdk_version
        App.fail "Deployment target `#{deployment_target}' must be equal or lesser than SDK version `#{sdk_version}'"
      end
      unless File.exist?(datadir)
        App.fail "iOS deployment target #{deployment_target} is not supported by this version of RubyMotion"
      end
    end

    def build_dir
      unless File.directory?(@build_dir)
        tried = false
        begin
          FileUtils.mkdir_p(@build_dir)
        rescue Errno::EACCES
          raise if tried
          require 'digest/sha1'
          hash = Digest::SHA1.hexdigest(File.expand_path(project_dir))
          tmp = File.join(ENV['TMPDIR'], hash)
          App.warn "Cannot create build_dir `#{@build_dir}'. Check the permissions. Using a temporary build directory instead: `#{tmp}'"
          @build_dir = tmp
          tried = true
          retry
        end
      end
      @build_dir
    end

    def versionized_build_dir
      File.join(build_dir, deployment_target)
    end

    attr_reader :project_dir

    def project_file
      File.join(@project_dir, 'Rakefile')
    end

    def files_dependencies(deps_hash)
      res_path = lambda do |x|
        path = /^\./.match(x) ? x : File.join('.', x)
        unless @files.include?(path)
          App.fail "Can't resolve dependency `#{x}'"
        end
        path
      end
      deps_hash.each do |path, deps|
        deps = [deps] unless deps.is_a?(Array)
        @dependencies[res_path.call(path)] = deps.map(&res_path)
      end
    end

    attr_reader :vendor_projects

    def vendor_project(path, type, opts={})
      @vendor_projects << Motion::Project::Vendor.new(path, type, self, opts)
    end

    def unvendor_project(path)
      @vendor_projects.delete_if { |x| x.path == path }
    end

    def file_dependencies(file)
      deps = @dependencies[file]
      if deps
        deps = deps.map { |x| file_dependencies(x) }
      else
        deps = [] 
      end
      deps << file
      deps 
    end

    def ordered_build_files
      @ordered_build_files ||= begin
        flat_deps = @files.map { |file| file_dependencies(file) }.flatten
        paths = flat_deps.dup
        flat_deps.each do |path|
          n = paths.count(path)
          if n > 1
            (n - 1).times { paths.delete_at(paths.rindex(path)) }
          end
        end
        paths
      end
    end

    def bridgesupport_files
      @bridgesupport_files ||= begin
        # Compute the list of frameworks, including dependencies, that the project uses.
        deps = ['RubyMotion']
        slf = File.join(sdk('iPhoneSimulator'), 'System', 'Library', 'Frameworks')
        frameworks.each do |framework|
          framework_path = File.join(slf, framework + '.framework', framework)
          if File.exist?(framework_path)
            `/usr/bin/otool -L \"#{framework_path}\"`.scan(/\t([^\s]+)\s\(/).each do |dep|
              # Only care about public, non-umbrella frameworks (for now).
              if md = dep[0].match(/^\/System\/Library\/Frameworks\/(.+)\.framework\/(.+)$/) and md[1] == md[2]
                deps << md[1]
              end
            end
          end
          deps << framework
        end

        bs_files = []
        deps.uniq.each do |framework|
          bs_path = File.join(datadir, 'BridgeSupport', framework + '.bridgesupport')
          if File.exist?(bs_path)
            bs_files << bs_path
          end
        end
        bs_files
      end
    end

    attr_accessor :spec_mode

    def spec_files
      Dir.glob(File.join(specs_dir, '**', '*.rb'))
    end

    def motiondir
      File.expand_path(File.join(File.dirname(__FILE__), '../../..'))
    end

    def bindir
      File.join(motiondir, 'bin')
    end

    def datadir(target=deployment_target)
      File.join(motiondir, 'data', target)
    end

    def platform_dir(platform)
      File.join(@platforms_dir, platform + '.platform')
    end

    def sdk_version
      @sdk_version ||= begin
        versions = Dir.glob(File.join(platforms_dir, 'iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk')).map do |path|
          File.basename(path).scan(/iPhoneOS(.*)\.sdk/)[0][0]
        end
        if versions.size == 0
          App.fail "Can't find an iOS SDK in `#{platforms_dir}'"
        end
        supported_vers = versions.reverse.find { |vers| File.exist?(datadir(vers)) }
        unless supported_vers
          App.fail "RubyMotion doesn't support any of these SDK versions: #{versions.join(', ')}"
        end
        supported_vers
      end
    end

    def deployment_target
      @deployment_target ||= sdk_version
    end

    def sdk(platform)
      File.join(platform_dir(platform), 'Developer/SDKs',
        platform + sdk_version + '.sdk')
    end

    def bundle_name
      @name + (spec_mode ? '_spec' : '')
    end

    def app_bundle(platform)
      File.join(versionized_build_dir, platform, bundle_name + '.app')
    end

    def app_bundle_dsym(platform)
      File.join(versionized_build_dir, platform, bundle_name + '.dSYM')
    end

    def archive
      File.join(versionized_build_dir, bundle_name + '.ipa')
    end

    def identifier
      @identifier ||= "com.yourcompany.#{@name.gsub(/\s/, '')}"
    end

    def device_family_int(family)
      case family
        when :iphone then 1
        when :ipad then 2
        else
          App.fail "Unknown device_family value: `#{family}'"
      end
    end

    def device_family_ints
      ary = @device_family.is_a?(Array) ? @device_family : [@device_family]
      ary.map { |family| device_family_int(family) }
    end

    def interface_orientations_consts
      @interface_orientations.map do |ori|
        case ori
          when :portrait then 'UIInterfaceOrientationPortrait'
          when :landscape_left then 'UIInterfaceOrientationLandscapeLeft'
          when :landscape_right then 'UIInterfaceOrientationLandscapeRight'
          when :portrait_upside_down then 'UIInterfaceOrientationPortraitUpsideDown'
          else
            App.fail "Unknown interface_orientation value: `#{ori}'"
        end
      end
    end

    def info_plist
      @info_plist ||= {
        'BuildMachineOSBuild' => `sw_vers -buildVersion`.strip,
        'MinimumOSVersion' => deployment_target,
        'CFBundleDevelopmentRegion' => 'en',
        'CFBundleName' => @name,
        'CFBundleDisplayName' => @name,
        'CFBundleExecutable' => @name, 
        'CFBundleIdentifier' => identifier,
        'CFBundleInfoDictionaryVersion' => '6.0',
        'CFBundlePackageType' => 'APPL',
        'CFBundleResourceSpecification' => 'ResourceRules.plist',
        'CFBundleShortVersionString' => @version,
        'CFBundleSignature' => @bundle_signature,
        'CFBundleSupportedPlatforms' => ['iPhoneOS'],
        'CFBundleVersion' => @version,
        'CFBundleIconFiles' => icons,
        'CFBundleIcons' => {
          'CFBundlePrimaryIcon' => {
            'CFBundleIconFiles' => icons,
            'UIPrerenderedIcon' => prerendered_icon,
          }
        },
        'UIDeviceFamily' => device_family_ints.map { |x| x.to_s },
        'UISupportedInterfaceOrientations' => interface_orientations_consts
      }
    end

    def info_plist_data
      Motion::PropertyList.to_s(info_plist)
    end

    def pkginfo_data
      "AAPL#{@bundle_signature}"
    end

    def codesign_certificate
      @codesign_certificate ||= begin
        certs = `/usr/bin/security -q find-certificate -a`.scan(/"iPhone Developer: [^"]+"/).uniq
        if certs.size == 0
          App.fail "Can't find an iPhone Developer certificate in the keychain"
        elsif certs.size > 1
          App.warn "Found #{certs.size} iPhone Developer certificates in the keychain. Set the `codesign_certificate' project setting. Will use the first certificate: `#{certs[0]}'"
        end
        certs[0][1..-2] # trim trailing `"` characters
      end 
    end

    def device_id
      @device_id ||= begin
        deploy = File.join(App.config.bindir, 'deploy')
        device_id = `#{deploy} -D`.strip
        if device_id.empty?
          App.fail "Can't find an iOS device connected on USB"
        end
        device_id
      end
    end

    def provisioning_profile(name = /iOS Team Provisioning Profile/)
      @provisioning_profile ||= begin
        paths = Dir.glob(File.expand_path("~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision")).select do |path|
          text = File.read(path)
          text.force_encoding('binary') if RUBY_VERSION >= '1.9.0'
          text.scan(/<key>\s*Name\s*<\/key>\s*<string>\s*([^<]+)\s*<\/string>/)[0][0].match(name)
        end
        if paths.size == 0
          App.fail "Can't find a provisioning profile named `#{name}'"
        elsif paths.size > 1
          App.warn "Found #{paths.size} provisioning profiles named `#{name}'. Set the `provisioning_profile' project setting. Will use the first one: `#{paths[0]}'"
        end
        paths[0]
      end
    end

    def read_provisioned_profile_array(key)
      text = File.read(provisioning_profile)
      text.force_encoding('binary') if RUBY_VERSION >= '1.9.0'
      text.scan(/<key>\s*#{key}\s*<\/key>\s*<array>(.*?)\s*<\/array>/m)[0][0].scan(/<string>(.*?)<\/string>/).map { |str| str[0].strip }
    end
    private :read_provisioned_profile_array

    def provisioned_devices
      @provisioned_devices ||= read_provisioned_profile_array('ProvisionedDevices')
    end

    def seed_id
      @seed_id ||= begin
        seed_ids = read_provisioned_profile_array('ApplicationIdentifierPrefix')
        if seed_ids.size == 0
          App.fail "Can't find an application seed ID in the provisioning profile `#{provisioning_profile}'"
        elsif seed_ids.size > 1
          App.warn "Found #{seed_ids.size} seed IDs in the provisioning profile. Set the `seed_id' project setting. Will use the last one: `#{seed_ids.last}'"
        end
        seed_ids.last
      end
    end

    def entitlements_data
      Motion::PropertyList.to_s(entitlements)
    end
  end
end; end

require 'xcodeproj'

module JournalRelease
  def self.prepared_inputs!(prepared)
    external!(prepared)
    inputs=JSON.parse(File.read(File.join(prepared,'release-inputs.json')))
    raise Failure, 'Prepared receipt changed; prepare a new project' unless Digest::SHA256.file(inputs.fetch('manifest_path')).hexdigest==inputs.fetch('manifest_sha256')
    manifest=verify_inputs!(**inputs.slice('root','manifest_path','lui','experimental').transform_keys(&:to_sym))
    inputs['source_sha']=manifest.fetch('source_sha')
    expected_flags=['$(inherited)',manifest.fetch('native_object').fetch('path'),manifest.fetch('production_link').fetch('target_c').fetch('path'),'-lsqlite3']
    project=Xcodeproj::Project.open(File.join(prepared,'Journal.xcodeproj'))
    target=project.targets.find { |t| t.name=='Journal' }
    valid=target && target.build_configurations.all? do |config|
      settings=config.build_settings
      settings['TARGETED_DEVICE_FAMILY']=='1' && settings['PRODUCT_BUNDLE_IDENTIFIER']==BUNDLE && settings['OTHER_LDFLAGS']==expected_flags
    end
    raise Failure, 'Prepared project target or native link inputs changed' unless valid
    info=Plist.parse_xml(File.read(File.join(prepared,'Info.plist')),marshal: false)
    validate_info!(info.merge('CFBundleIdentifier'=>BUNDLE,'DTPlatformName'=>'iphoneos'),version: inputs.fetch('version'),build: inputs.fetch('build'),source_sha: inputs.fetch('source_sha'),experimental: inputs.fetch('experimental'))
    [prepared,inputs]
  end

  def self.verify_inputs!(root:, manifest_path:, lui:, experimental: false)
    manifest=JSON.parse(File.read(manifest_path))
    raise Failure, 'Only explicitly experimental device receipts are supported' unless experimental && manifest.values_at('status','mode','cross_abi_validated','sdk_name','architecture')==['built','experimental-host-restamp',false,'iphoneos','arm64']
    raise Failure, 'Source revision differs from receipt' unless run!('git','-C',root,'rev-parse','HEAD').strip==manifest.fetch('source_sha')
    [root,lui].each { |p| raise Failure, 'Source/LUI checkout must be clean' unless run!('git','-C',p,'status','--porcelain','--untracked-files=all').empty? }
    inputs=manifest.fetch('inputs')
    raise Failure, 'LUI revision differs from receipt' unless run!('git','-C',lui,'rev-parse','HEAD').strip==inputs.fetch('lui_sha')
    {'source'=>root,'lui'=>lui}.each do |kind,base|
      inputs.fetch(kind).each do |relative,hash|
        path=File.expand_path(relative,base)
        raise Failure, 'Unsafe source receipt path' unless path.start_with?(File.expand_path(base)+'/')
        raise Failure, "#{kind} input hash changed: #{relative}" unless Digest::SHA256.file(path).hexdigest==hash
      end
    end
    [manifest.fetch('native_object'),manifest.fetch('production_link').fetch('target_c')].each do |object|
      raise Failure, 'Native input hash changed' unless Digest::SHA256.file(object.fetch('path')).hexdigest==object.fetch('sha256')
    end
    manifest
  end

  def self.prepare!(root:, manifest_path:, lui:, output:, version:, build:, experimental: false)
    root,lui,output=[root,lui,output].map { |p| File.expand_path(p) }
    external!(output,root: root)
    raise Failure, 'Prepared output already exists; preserve it' if File.exist?(output)
    raise Failure, 'Invalid version/build' unless [version,build].all? { |s| s.to_s.match?(/\A\d+(?:\.\d+){0,2}\z/) }
    manifest=verify_inputs!(root: root,manifest_path: manifest_path,lui: lui,experimental: experimental)
    info=Plist.parse_xml(File.read(File.join(root,'apple/Info.plist')),marshal: false)
    raise Failure, 'Source encryption declaration missing or changed' unless info['ITSAppUsesNonExemptEncryption']==false
    info.merge!('CFBundleExecutable'=>'$(EXECUTABLE_NAME)','CFBundleIdentifier'=>'$(PRODUCT_BUNDLE_IDENTIFIER)',
      'CFBundleShortVersionString'=>version,'CFBundleVersion'=>build,'UIDeviceFamily'=>[1],
      'CFBundleURLTypes'=>[{'CFBundleURLName'=>'com.logseq.journal.auth','CFBundleURLSchemes'=>['logseqjournal']}],
      'JournalSourceRevision'=>manifest.fetch('source_sha'),'JournalBuildMode'=>'experimental-host-restamp',
      'JournalCrossABIValidated'=>false,'JournalOCamlRuntimeOrigin'=>'host-arm64-restamp',
      'JournalNativeConfiguration'=>manifest.fetch('inputs').fetch('flags').fetch('configuration'),'JournalArchiveConfiguration'=>'Release')
    info.delete('LSMinimumSystemVersion')
    FileUtils.mkdir_p(output)
    File.write(File.join(output,'Info.plist'),Plist::Emit.dump(info))
    project=Xcodeproj::Project.new(File.join(output,'Journal.xcodeproj'))
    target=project.new_target(:application,'Journal',:ios,'26.0')
    group=project.main_group.new_group('Journal Sources')
    Dir[File.join(root,'swift','*.swift')].sort.reject { |p| File.basename(p)=='Package.swift' }.each do |path|
      target.source_build_phase.add_file_reference(group.new_file(path))
    end
    target.resources_build_phase.add_file_reference(group.new_file(File.join(root,'assets/apple/Assets.xcassets')))
    package=project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    package.relative_path=lui; project.root_object.package_references << package
    product=project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product.package=package; product.product_name='LUIAppleBackendStatic'
    target.package_product_dependencies << product
    file=project.new(Xcodeproj::Project::Object::PBXBuildFile); file.product_ref=product
    target.frameworks_build_phase.files << file
    target.build_configurations.each do |config|
      config.build_settings.merge!('PRODUCT_NAME'=>'JournalApp','PRODUCT_BUNDLE_IDENTIFIER'=>BUNDLE,
        'SDKROOT'=>'iphoneos','SUPPORTED_PLATFORMS'=>'iphoneos','ARCHS'=>'arm64',
        'IPHONEOS_DEPLOYMENT_TARGET'=>'26.0','TARGETED_DEVICE_FAMILY'=>'1','SWIFT_VERSION'=>'6.0',
        'INFOPLIST_FILE'=>File.join(output,'Info.plist'),'GENERATE_INFOPLIST_FILE'=>'NO',
        'MARKETING_VERSION'=>version,'CURRENT_PROJECT_VERSION'=>build,'CODE_SIGNING_ALLOWED'=>'NO',
        'CODE_SIGN_STYLE'=>'Manual','SKIP_INSTALL'=>'NO','DEBUG_INFORMATION_FORMAT'=>'dwarf-with-dsym',
        'SWIFT_OPTIMIZATION_LEVEL'=>(config.name=='Release' ? '-O' : '-Onone'),
        'ASSETCATALOG_COMPILER_APPICON_NAME'=>'AppIcon','SUPPORTS_MACCATALYST'=>'NO',
        'LD_GENERATE_MAP_FILE'=>'YES','COPY_PHASE_STRIP'=>'NO','STRIP_INSTALLED_PRODUCT'=>'NO',
        'OTHER_LDFLAGS'=>['$(inherited)',manifest.fetch('native_object').fetch('path'),manifest.fetch('production_link').fetch('target_c').fetch('path'),'-lsqlite3'])
    end
    project.save
    scheme=Xcodeproj::XCScheme.new; scheme.add_build_target(target); scheme.set_launch_target(target)
    scheme.archive_action.build_configuration='Release'; scheme.save_as(project.path,'Journal',true)
    File.write(File.join(output,'release-inputs.json'),JSON.pretty_generate({root: root,manifest_path: File.expand_path(manifest_path),manifest_sha256: Digest::SHA256.file(manifest_path).hexdigest,lui: lui,experimental: true,version: version,build: build})+"\n")
    project.path.to_s
  end
end

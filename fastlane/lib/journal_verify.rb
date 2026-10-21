require 'zip'

module JournalRelease
  def self.read_plist(path)
    Plist.parse_xml(run!('/usr/bin/plutil','-convert','xml1','-o','-',path))
  end

  def self.verify_ipa!(ipa:, version:, build:, sha256:, source_sha:, experimental: false)
    raise Failure, 'IPA SHA256 mismatch' unless sha256.to_s.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(ipa).hexdigest==sha256
    Dir.mktmpdir('journal-ipa-') do |directory|
      Zip::File.open(ipa) do |zip|
        zip.each do |entry|
          destination=File.expand_path(entry.name,directory)
          raise Failure, 'Unsafe IPA entry' unless destination.start_with?(directory+'/') && !entry.symlink?
          FileUtils.mkdir_p(File.dirname(destination))
          entry.extract(destination)
        end
      end
      apps=Dir[File.join(directory,'Payload','*.app')]
      raise Failure, 'IPA must contain exactly one Journal app' unless apps.length==1
      app=apps.first; info=read_plist(File.join(app,'Info.plist'))
      validate_info!(info,version: version,build: build,source_sha: source_sha,experimental: experimental)
      run!('/usr/bin/codesign','--verify','--deep','--strict',app)
      ent_xml=run!('/usr/bin/codesign','-d','--entitlements',':-',app)
      ent=Plist.parse_xml(ent_xml)
      profile=Plist.parse_xml(run!('/usr/bin/openssl','smime','-inform','der','-verify','-noverify','-in',File.join(app,'embedded.mobileprovision')))
      prefix=File.join(directory,'certificate')
      run!('/usr/bin/codesign','-d','--extract-certificates',prefix,app)
      cert_sha=Digest::SHA1.file(prefix+'0').hexdigest
      validate_profile!(profile,ent,cert_sha)
      executable=File.join(app,info.fetch('CFBundleExecutable'))
      raise Failure, 'IPA must contain arm64 only' unless run!('/usr/bin/lipo','-archs',executable).strip=='arm64'
      load_commands=run!('/usr/bin/otool','-l',executable)
      raise Failure, 'Executable is not an iPhoneOS image' unless load_commands.match?(/cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (?:2|IOS)\b/)
      {'app_id'=>APP_ID,'bundle_id'=>BUNDLE,'team_id'=>TEAM,'version'=>version,'build'=>build,
       'ipa_sha256'=>sha256,'source_sha'=>info.fetch('JournalSourceRevision'),
       'profile_uuid'=>profile.fetch('UUID'),'cross_abi_validated'=>false,
       'build_mode'=>info.fetch('JournalBuildMode')}
    end
  end
end

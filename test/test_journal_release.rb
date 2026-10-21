require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'
require 'open3'
require 'plist'
require 'xcodeproj'
require 'stringio'

ROOT = File.expand_path('..', __dir__)
RELEASE = File.join(ROOT, 'fastlane/lib/journal_release.rb')
require RELEASE if File.file?(RELEASE)

# Packaging and transport are owned by release tooling, not the graph reducer.
# Fixtures exercise that boundary without any Apple login, keychain or upload.
class JournalReleaseTest < Minitest::Test
  def setup
    assert File.file?(RELEASE), 'Journal release tooling must exist'
  end

  def info
    {'CFBundleIdentifier'=>'com.logseq.journal', 'CFBundleExecutable'=>'JournalApp',
     'CFBundleShortVersionString'=>'1.0', 'CFBundleVersion'=>'42', 'UIDeviceFamily'=>[1],
     'ITSAppUsesNonExemptEncryption'=>false, 'DTPlatformName'=>'iphoneos',
     'JournalBuildMode'=>'experimental-host-restamp', 'JournalCrossABIValidated'=>false,
     'JournalSourceRevision'=>'a'*40}
  end

  def test_source_and_final_package_contract
    source = Plist.parse_xml(File.read(File.join(ROOT, 'apple/Info.plist')))
    assert_equal false, source['ITSAppUsesNonExemptEncryption']
    assert_equal [1], source['UIDeviceFamily']
    assert JournalRelease.validate_info!(info, version: '1.0', build: '42', experimental: true)
    [['UIDeviceFamily',[1,2]], ['ITSAppUsesNonExemptEncryption',nil],
     ['CFBundleIdentifier','com.logseq.logseq'], ['DTPlatformName','iphonesimulator'],
     ['JournalCrossABIValidated',true], ['CFBundleVersion','43']].each do |key,value|
      assert_raises(JournalRelease::Failure, key) do
        JournalRelease.validate_info!(info.merge(key=>value), version: '1.0', build: '42', experimental: true)
      end
    end
    assert_raises(JournalRelease::Failure) { JournalRelease.validate_info!(info, version: '1.0', build: '42') }
  end

  def test_structured_credentials_do_not_erase_neighboring_error_details
    raw = '{"token":["synthetic-nested-token"],"errors":[{"detail":"Keep complete failure"}]}'
    clean=JournalRelease.redact(raw)
    refute_includes clean,'synthetic-nested-token'
    assert_includes clean,'Keep complete failure'
  end

  def test_ipa_preflight_rejects_wrong_hash_and_unsafe_zip_before_signing
    Dir.mktmpdir do |directory|
      ipa=File.join(directory,'synthetic.ipa')
      Zip::File.open(ipa,create: true) { |zip| zip.get_output_stream('../escape') { |out| out.write('synthetic') } }
      assert_raises(JournalRelease::Failure) { JournalRelease.verify_ipa!(ipa: ipa,version:'1.0',build:'42',sha256:'0'*64,experimental:true) }
      error=assert_raises(JournalRelease::Failure) { JournalRelease.verify_ipa!(ipa:ipa,version:'1.0',build:'42',sha256:Digest::SHA256.file(ipa).hexdigest,experimental:true) }
      assert_match(/Unsafe IPA entry/,error.message)
    end
  end

  def test_profile_identity_and_entitlement_boundary
    cert = 'synthetic public certificate'
    ent = {'application-identifier'=>'K378MFWK59.com.logseq.journal',
           'com.apple.developer.team-identifier'=>'K378MFWK59',
           'get-task-allow'=>false, 'beta-reports-active'=>true}
    profile = {'TeamIdentifier'=>['K378MFWK59'], 'Entitlements'=>ent,
               'ExpirationDate'=>Time.now+3600, 'DeveloperCertificates'=>[StringIO.new(cert)]}
    assert JournalRelease.validate_profile!(profile, ent, Digest::SHA1.hexdigest(cert))
    [{'ProvisionedDevices'=>['synthetic']}, {'ExpirationDate'=>Time.now-1},
     {'TeamIdentifier'=>['OTHER']}, {'ProvisionsAllDevices'=>true}].each do |change|
      assert_raises(JournalRelease::Failure) { JournalRelease.validate_profile!(profile.merge(change), ent, Digest::SHA1.hexdigest(cert)) }
    end
    assert_raises(JournalRelease::Failure) { JournalRelease.validate_profile!(profile, ent.merge('get-task-allow'=>true), Digest::SHA1.hexdigest(cert)) }
    assert_raises(JournalRelease::Failure) { JournalRelease.validate_profile!(profile, ent.merge('unauthorized-capability'=>true), Digest::SHA1.hexdigest(cert)) }
    assert_raises(JournalRelease::Failure) { JournalRelease.validate_profile!(profile, ent, '0'*40) }
  end

  def test_diagnostics_preserve_multiline_errors_and_redact_all_secret_forms
    password = 'abcd-efgh-ijkl-mnop'
    raw = <<~TEXT
      ERROR: Validation failed (409)
      Invalid bundle. Include iPad orientations. (-19241)
      STATE_ERROR.VALIDATION_ERROR
      {"errors":[{"code":"409","detail":"Complete multi-line reason"}],"token":"synthetic-token"}
      <key>password</key><string>synthetic-pass</string>
      Authorization: Bearer synthetic-auth
      --password '#{password}'
      -----BEGIN PRIVATE KEY-----
      synthetic-material
      -----END PRIVATE KEY-----
    TEXT
    clean = JournalRelease.redact(raw, secrets: [password])
    %w[synthetic-token synthetic-pass synthetic-auth synthetic-material].each { |v| refute_includes clean, v }
    refute_includes clean, password
    %w[409 -19241 STATE_ERROR.VALIDATION_ERROR].each { |v| assert_includes clean, v }
    assert_includes clean, 'Complete multi-line reason'
    assert_includes clean, 'Include iPad orientations'
    refute JournalRelease.transport_success?(0, raw)
    refute JournalRelease.transport_success?(1, 'UPLOAD SUCCEEDED with no errors')
    refute JournalRelease.transport_success?(0, '')
    assert JournalRelease.transport_success?(0, 'UPLOAD SUCCEEDED with no errors')
  end

  def test_attempt_ledger_never_silently_retries_or_confuses_changed_packages
    Dir.mktmpdir do |directory|
      package = {'app_id'=>'6824952205', 'bundle_id'=>'com.logseq.journal',
                 'version'=>'1.0', 'build'=>'42', 'ipa_sha256'=>'a'*64}
      proof = package.merge('checked_utc'=>Time.now.utc.iso8601,
                            'accepted_build_visible'=>false, 'active_upload'=>false,
                            'non_target_automatic_distribution'=>false)
      ledger = JournalRelease::Ledger.new(directory, package)
      ledger.attempt!(proof) { {'status'=>'failed_or_uncertain'} }
      assert_raises(JournalRelease::Failure) { ledger.attempt!(proof) { flunk 'blind retry' } }
      stale = proof.merge('checked_utc'=>(Time.now-901).utc.iso8601)
      assert_raises(JournalRelease::Failure) { ledger.attempt!(stale, retry_upload: true) { flunk 'stale retry' } }
      assert_raises(JournalRelease::Failure) { ledger.attempt!(proof.merge('accepted_build_visible'=>true), retry_upload: true) { flunk 'duplicate' } }
      assert_raises(JournalRelease::Failure) { ledger.attempt!(proof.merge('non_target_automatic_distribution'=>true), retry_upload: true) { flunk 'unintended audience' } }
      changed = JournalRelease::Ledger.new(directory, package.merge('ipa_sha256'=>'b'*64))
      assert_raises(JournalRelease::Failure) { changed.attempt!(proof, retry_upload: true) { flunk 'wrong proof' } }
      ledger.attempt!(proof, retry_upload: true) { {'status'=>'tool_reported_success'} }
      assert_raises(JournalRelease::Failure) { ledger.attempt!(proof, retry_upload: true) { flunk 'success retried' } }
      assert_equal 2, Dir[File.join(directory, '*.json')].length
    end
  end

  def test_concurrent_and_interrupted_attempts_are_recorded
    Dir.mktmpdir do |directory|
      package = {'app_id'=>'6824952205','version'=>'1.0','build'=>'42','ipa_sha256'=>'a'*64}
      proof = package.merge('checked_utc'=>Time.now.utc.iso8601,'accepted_build_visible'=>false,'active_upload'=>false,'non_target_automatic_distribution'=>false)
      ledger = JournalRelease::Ledger.new(directory, package)
      assert_raises(Interrupt) do
        ledger.attempt!(proof) do
          assert_raises(JournalRelease::Failure) { ledger.attempt!(proof) {} }
          raise Interrupt
        end
      end
      result = JSON.parse(File.read(Dir[File.join(directory, '*.json')].fetch(0)))
      assert_equal 'failed_or_uncertain', result['status']
    end
  end

  def test_upload_snapshot_is_hash_bound_and_does_not_change_original
    Dir.mktmpdir do |directory|
      original=File.join(directory,'original.ipa'); File.write(original,'synthetic package')
      hash=Digest::SHA256.file(original).hexdigest
      assert JournalRelease.respond_to?(:with_snapshot), 'Upload must use a hash-bound private copy'
      JournalRelease.with_snapshot(original,hash) do |snapshot|
        refute_equal original,snapshot
        assert_equal hash,Digest::SHA256.file(snapshot).hexdigest
        File.write(original,'changed after snapshot')
        assert_equal hash,Digest::SHA256.file(snapshot).hexdigest
      end
      assert_equal 'changed after snapshot',File.read(original)
      assert_raises(JournalRelease::Failure) { JournalRelease.with_snapshot(original,hash) { flunk 'changed package uploaded' } }
    end
  end

  def test_real_pilot_contract_without_apple_or_credential_store
    require 'pilot'
    JournalRelease.install_transport_hooks!
    Pilot::BuildManager.class_eval do
      def login; raise 'unexpected Apple login'; end
      def distribute(*); raise 'unexpected distribution'; end
      def wait_for_build_processing_to_be_complete(*); raise 'unexpected processing API'; end
    end
    CredentialsManager::AccountManager.define_singleton_method(:new) { |*| raise 'unexpected credential store' }
    ENV['JOURNAL_UPLOAD_PASSWORD'] = 'abcd-efgh-ijkl-mnop'
    ENV['FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD'] = '@env:JOURNAL_UPLOAD_PASSWORD'
    fixture = Tempfile.new(['journal-contract-', '.ipa'])
    fixture.write('synthetic package; command execution is replaced at the PTY boundary')
    fixture.flush
    [[0,"UPLOAD SUCCEEDED with no errors\n",true],
     [0,"ERROR: Validation failed (409)\nInvalid bundle\nSTATE_ERROR.VALIDATION_ERROR\n",false],
     [1,"ERROR: Authentication failed (-20101)\n",false],
     [1,"{\"errors\":[{\"code\":\"409\",\"detail\":\"Invalid package\"}]}\n",false]].each do |exit_code,output,success|
      commands = []
      FastlaneCore::FastlanePty.define_singleton_method(:spawn) do |command,&block|
        commands << command
        block.call(StringIO.new(output), StringIO.new, 123)
        exit_code
      end
      JournalRelease.transport = {}
      options = JournalRelease.upload_options(fixture.path, version: '1.0', build: '42')
      result = begin
        Pilot::BuildManager.new.upload(FastlaneCore::Configuration.create(Pilot::Options.available_options, options))
        true
      rescue StandardError
        false
      end
      assert_equal success, result
      assert_equal 1, commands.length
      assert_includes commands.first, 'xcrun altool --upload-app'
      assert_includes commands.first, '@env:JOURNAL_UPLOAD_PASSWORD'
      refute_includes commands.first, ENV['JOURNAL_UPLOAD_PASSWORD']
      assert_equal exit_code, JournalRelease.transport.fetch(:exit_code)
      assert_includes JournalRelease.transport.fetch(:output), output.lines.first.strip
      assert_equal false, options[:distribute_external]
      assert_equal true, options[:skip_submission]
      refute options.key?(:groups)
    end
  ensure
    fixture&.close!
    ENV.delete('JOURNAL_UPLOAD_PASSWORD')
    ENV.delete('FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD')
  end

  def test_generated_project_preserves_iphone_and_compliance_and_provenance
    Dir.mktmpdir do |directory|
      root = File.join(directory,'source'); lui = File.join(directory,'lui')
      [root,lui].each do |path|
        FileUtils.mkdir_p(path)
        system('git','init','-q',path, exception: true)
      end
      FileUtils.mkdir_p(File.join(root,'apple')); FileUtils.mkdir_p(File.join(root,'swift'))
      File.write(File.join(root,'swift/App.swift'),'// synthetic fixture')
      source_info = info.reject { |k,_| k.start_with?('Journal') || k=='DTPlatformName' }
      source_info['UISupportedInterfaceOrientations'] = %w[UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight]
      File.write(File.join(root,'apple/Info.plist'),Plist::Emit.dump(source_info))
      File.write(File.join(lui,'Package.swift'),'// synthetic fixture')
      [root,lui].each do |path|
        system('git','-C',path,'add','.', exception: true)
        system('git','-C',path,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-qm','fixture', exception: true)
      end
      sha = ->(p) { Digest::SHA256.file(p).hexdigest }
      native=File.join(directory,'native.o'); target=File.join(directory,'target.o')
      File.write(native,'synthetic native'); File.write(target,'synthetic target')
      manifest={'status'=>'built','mode'=>'experimental-host-restamp','cross_abi_validated'=>false,
        'source_sha'=>`git -C #{root} rev-parse HEAD`.strip,'sdk_name'=>'iphoneos','architecture'=>'arm64',
        'native_object'=>{'path'=>native,'sha256'=>sha.call(native)},
        'production_link'=>{'target_c'=>{'path'=>target,'sha256'=>sha.call(target)}},
        'inputs'=>{'flags'=>{'configuration'=>'debug'},'source'=>{'swift/App.swift'=>sha.call(File.join(root,'swift/App.swift'))},
          'lui'=>{'Package.swift'=>sha.call(File.join(lui,'Package.swift'))},
          'lui_sha'=>`git -C #{lui} rev-parse HEAD`.strip}}
      manifest_path=File.join(directory,'manifest.json'); File.write(manifest_path,JSON.generate(manifest))
      output=File.join(directory,'prepared')
      JournalRelease.prepare!(root: root, manifest_path: manifest_path, lui: lui, output: output, version: '1.0', build: '42', experimental: true)
      project=Xcodeproj::Project.open(File.join(output,'Journal.xcodeproj'))
      project.targets.first.build_configurations.each { |c| assert_equal '1', c.build_settings['TARGETED_DEVICE_FAMILY'] }
      prepared=Plist.parse_xml(File.read(File.join(output,'Info.plist')))
      assert_equal false, prepared['ITSAppUsesNonExemptEncryption']
      assert_equal false, prepared['JournalCrossABIValidated']
      assert_equal ['logseqjournal'],prepared.fetch('CFBundleURLTypes',[]).flat_map { |entry| entry.fetch('CFBundleURLSchemes',[]) }
      assert_equal source_info['UISupportedInterfaceOrientations'],prepared['UISupportedInterfaceOrientations']
      assert_raises(JournalRelease::Failure) { JournalRelease.prepare!(root: root, manifest_path: manifest_path,lui: lui,output: output,version: '1.0',build: '42',experimental: true) }
      File.write(native,'tampered')
      assert_raises(JournalRelease::Failure) { JournalRelease.prepare!(root: root,manifest_path: manifest_path,lui: lui,output: output+'other',version: '1.0',build: '42',experimental: true) }
    end
  end
end

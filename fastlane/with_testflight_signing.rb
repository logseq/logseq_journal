#!/usr/bin/env ruby
# Scope the existing Journal signing identity and profile to one command.
require 'base64'
require 'securerandom'
require 'shellwords'
require_relative 'lib/journal_release'

module JournalTestFlightSigning
  WWDR_G3 = 'https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer'.freeze
  SECURITY = '/usr/bin/security'.freeze
  LOGIN_KEYCHAIN = File.expand_path('~/Library/Keychains/login.keychain-db')
  XCODE_PROFILES = File.expand_path('~/Library/Developer/Xcode/UserData/Provisioning Profiles')

  def self.security!(*args)
    JournalRelease.run!(SECURITY, *args)
  end

  def self.private_security!(stage, *args)
    # security's interactive mode reads arguments from stdin, keeping passwords
    # out of process arguments. Its output can contain input, so never print it.
    raise JournalRelease::Failure, "Invalid input for #{stage}" if args.any? { |arg| arg.match?(/[\r\n\0]/) }
    _, _, status = Open3.capture3(SECURITY, '-i', stdin_data: Shellwords.join(args) + "\n")
    raise JournalRelease::Failure, "#{stage} failed (security #{status.exitstatus})" unless status.success?
  end

  def self.signing_secret!(name)
    value = ENV.delete(name)
    raise JournalRelease::Failure, "#{name} is required in the process environment" if value.nil? || value.empty?
    value.dup
  end

  def self.install_profile!(source, destination)
    FileUtils.mkdir_p(XCODE_PROFILES)
    Tempfile.create('.journal-testflight-', XCODE_PROFILES, binmode: true) do |file|
      IO.copy_stream(source, file)
      file.flush
      File.link(file.path, destination)
    end
  end

  def self.run(command)
    umask_before = File.umask(0o077)
    lock_path = File.expand_path('~/Library/Caches/com.logseq.journal/testflight-signing.lock')
    FileUtils.mkdir_p(File.dirname(lock_path))
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      raise JournalRelease::Failure, 'Another Journal signing command is running for this user' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      Dir.mktmpdir('journal-testflight-signing-') { |dir| with_signing(dir, command) }
    end
  ensure
    File.umask(umask_before)
  end

  def self.with_signing(dir, command)
    keychain = File.join(dir, 'release.keychain-db')
    profile_path = File.join(dir, 'Journal.mobileprovision')
    p12_path = File.join(dir, 'distribution.p12')
    keychain_password = SecureRandom.hex(32)
    installed_profile = nil
    installed_login_intermediate = false
    keychain_created = false

    profile_b64 = signing_secret!('JOURNAL_IOS_APPSTORE_PROFILE_BASE64')
    p12_b64 = signing_secret!('JOURNAL_IOS_DISTRIBUTION_P12_BASE64')
    p12_password = signing_secret!('JOURNAL_IOS_DISTRIBUTION_P12_PASSWORD')
    File.binwrite(profile_path, Base64.strict_decode64(profile_b64.gsub(/\s+/, '')))
    profile = Plist.parse_xml(JournalRelease.run!('/usr/bin/openssl', 'smime', '-inform', 'der', '-verify', '-noverify', '-in', profile_path), marshal: false)
    uuid = profile.fetch('UUID')
    raise JournalRelease::Failure, 'Expected an iOS App Store provisioning profile' unless JournalRelease.apple_uuid?(uuid) && Array(profile['Platform']).include?('iOS')
    entitlements = {
      'application-identifier' => "#{JournalRelease::TEAM}.#{JournalRelease::BUNDLE}",
      'com.apple.developer.team-identifier' => JournalRelease::TEAM,
      'get-task-allow' => false,
      'beta-reports-active' => true,
      'keychain-access-groups' => ["#{JournalRelease::TEAM}.#{JournalRelease::BUNDLE}"],
    }
    certs = profile.fetch('DeveloperCertificates').map { |cert| Digest::SHA1.hexdigest(cert.string).upcase }
    JournalRelease.validate_profile!(profile, entitlements, certs.fetch(0))
    entitlements_path = File.join(dir, 'Journal.entitlements')
    File.write(entitlements_path, Plist::Emit.dump(entitlements))
    intermediate = File.join(dir, 'AppleWWDRCAG3.cer')
    JournalRelease.run!('/usr/bin/curl', '--fail', '--silent', '--show-error', '--proto', '=https',
                        '--output', intermediate, WWDR_G3)

    prior = keychains
    private_security!('Create temporary keychain', 'create-keychain', '-p', keychain_password, keychain)
    keychain_created = true
    private_security!('Unlock temporary keychain', 'unlock-keychain', '-p', keychain_password, keychain)
    security!('set-keychain-settings', keychain)
    begin
      File.binwrite(p12_path, Base64.strict_decode64(p12_b64.gsub(/\s+/, '')))
      private_security!('Import Apple Distribution identity', 'import', p12_path, '-f', 'pkcs12',
                        '-k', keychain, '-P', p12_password, '-T', '/usr/bin/codesign')
    ensure
      FileUtils.rm_f(p12_path)
    end
    private_security!('Authorize Apple signing tools in the temporary keychain', 'set-key-partition-list',
                      '-S', 'apple-tool:,apple:', '-s', '-k', keychain_password, keychain)
    intermediate_sha1 = Digest::SHA1.file(intermediate).hexdigest.upcase
    unless security!('find-certificate', '-a', '-Z', keychain).include?(intermediate_sha1)
      security!('import', intermediate, '-k', keychain)
    end
    security!('list-keychains', '-d', 'user', '-s', keychain, *prior)

    matching = security!('find-identity', '-v', '-p', 'codesigning', keychain)
                 .scan(/([0-9A-F]{40}) "Apple Distribution:/).flatten & certs
    raise JournalRelease::Failure, 'Expected one valid Apple Distribution identity matching the Journal profile' unless matching.one?
    fingerprint = matching.first
    probe = File.join(dir, 'signing-probe')
    FileUtils.cp('/usr/bin/true', probe)
    sign_probe = ['/usr/bin/codesign', '--force', '--sign', fingerprint, probe]
    begin
      JournalRelease.run!(*sign_probe)
    rescue JournalRelease::Failure => error
      raise unless error.message.downcase.include?('unable to build chain') && File.file?(LOGIN_KEYCHAIN)
      unless security!('find-certificate', '-a', '-Z', LOGIN_KEYCHAIN).include?(intermediate_sha1)
        # Xcode's trust lookup can require the public intermediate in login.
        security!('import', intermediate, '-k', LOGIN_KEYCHAIN)
        installed_login_intermediate = true
      end
      JournalRelease.run!(*sign_probe)
    end
    JournalRelease.run!('/usr/bin/codesign', '--verify', '--strict', probe)

    destination = File.join(XCODE_PROFILES, "#{uuid}.mobileprovision")
    begin
      install_profile!(profile_path, destination)
      installed_profile = destination
    rescue Errno::EEXIST
      raise JournalRelease::Failure, 'Xcode already has a different profile with the same UUID' unless FileUtils.compare_file(profile_path, destination)
    end

    puts 'Journal TestFlight profile and Apple Distribution identity verified.'
    $stdout.flush
    run_command({
      'EXISTING_APPSTORE_PROFILE' => profile_path,
      'EXISTING_CERTIFICATE_SHA1' => fingerprint,
      'JOURNAL_IOS_SIGN_ENTITLEMENTS' => entitlements_path,
    }, command)
  ensure
    begin
      [profile_b64, p12_b64, p12_password, keychain_password].each { |value| JournalRelease.wipe(value) if value }
      if installed_profile && File.file?(installed_profile) && FileUtils.compare_file(profile_path, installed_profile)
        File.unlink(installed_profile)
      end
    ensure
      begin
        security!('delete-certificate', '-Z', intermediate_sha1, LOGIN_KEYCHAIN) if installed_login_intermediate
      ensure
        if keychain_created
          # Deleting this keychain also removes its entry from the search list.
          security!('delete-keychain', keychain)
        end
      end
    end
  end

  def self.keychains
    Shellwords.split(security!('list-keychains', '-d', 'user'))
  end

  def self.run_command(environment, command)
    pid = Process.spawn(environment, *command, pgroup: true)
    handlers = %w[INT TERM].to_h do |signal|
      [signal, Signal.trap(signal) { Process.kill(signal, -pid) rescue nil }]
    end
    _, status = Process.wait2(pid)
    status.exitstatus || 128 + status.termsig
  ensure
    handlers&.each { |signal, handler| Signal.trap(signal, handler) }
  end
end

if ARGV.empty? || %w[-h --help].include?(ARGV.first)
  puts 'Usage: bundle exec ruby fastlane/with_testflight_signing.rb -- COMMAND [ARG ...]'
  exit(ARGV.empty? ? 1 : 0)
end
unless ARGV.shift == '--' && !ARGV.empty?
  abort 'Pass a command after --. Use --help for usage.'
end

Signal.trap('TERM') { raise Interrupt }
begin
  exit JournalTestFlightSigning.run(ARGV)
rescue Interrupt
  exit 130
rescue JournalRelease::Failure, ArgumentError, KeyError, SystemCallError => error
  abort "TestFlight signing preparation: #{error.message}"
end

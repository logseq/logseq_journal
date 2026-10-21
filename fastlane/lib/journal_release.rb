require 'json'
require 'digest'
require 'time'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'plist'

module JournalRelease
  class Failure < StandardError; end
  BUNDLE = 'com.logseq.journal'.freeze
  TEAM = 'K378MFWK59'.freeze
  APP_ID = '6824952205'.freeze
  ACCOUNT = 'dev@logseq.com'.freeze
  INTERNAL_GROUP = 'Logseq Team'.freeze
  INTERNAL_GROUP_ID = '3fcd1cd3-cafa-44e4-987d-47a752174c32'.freeze
  ROOT = File.expand_path('../..', __dir__)

  def self.run!(*argv)
    out, err, status = Open3.capture3(*argv.map(&:to_s))
    raise Failure, "#{File.basename(argv.first.to_s)} exited #{status.exitstatus}: #{redact(out + err)}" unless status.success?
    out
  end

  def self.external!(path, root: ROOT)
    expanded = File.expand_path(path)
    # Resolve existing ancestors too, so a symlink cannot put artifacts in Git.
    ancestor = expanded
    ancestor = File.dirname(ancestor) until File.exist?(ancestor)
    resolved = File.realpath(ancestor) + expanded.delete_prefix(ancestor)
    repository = File.realpath(root)
    raise Failure, 'Keep generated hosts, signing material and reports outside the repository' if resolved == repository || resolved.start_with?(repository + '/')
    expanded
  end

  def self.validate_info!(info, version:, build:, source_sha:, experimental: false)
    expected = {'CFBundleIdentifier'=>BUNDLE, 'CFBundleShortVersionString'=>version,
      'CFBundleVersion'=>build, 'UIDeviceFamily'=>[1], 'ITSAppUsesNonExemptEncryption'=>false,
      'DTPlatformName'=>'iphoneos'}
    expected.each { |key,value| raise Failure, "Unexpected #{key}" unless info[key] == value }
    raise Failure, 'Source revision differs from the expected release' unless source_sha.to_s.match?(/\A[0-9a-f]{40}\z/) && info['JournalSourceRevision']==source_sha
    raise Failure, 'Experimental host-restamp requires explicit opt-in; no verified cross-release route exists here' unless experimental && info['JournalBuildMode']=='experimental-host-restamp' && info['JournalCrossABIValidated']==false
    true
  end

  def self.validate_profile!(profile, entitlements, certificate_sha1)
    grants = profile.fetch('Entitlements')
    identity = {'application-identifier'=>"#{TEAM}.#{BUNDLE}",
      'com.apple.developer.team-identifier'=>TEAM, 'get-task-allow'=>false, 'beta-reports-active'=>true}
    valid = profile['TeamIdentifier']==[TEAM] && profile['ExpirationDate'].to_time > Time.now &&
      !profile.key?('ProvisionedDevices') && !profile['ProvisionsAllDevices'] &&
      identity.all? { |key,value| grants[key]==value && entitlements[key]==value }
    certs = profile.fetch('DeveloperCertificates').map { |cert| Digest::SHA1.hexdigest(cert.respond_to?(:string) ? cert.string : cert).upcase }
    valid &&= certs.include?(certificate_sha1.upcase)
    allowed = lambda do |request,grant|
      case request
      when Array then grant.is_a?(Array) && request.all? { |v| grant.any? { |g| allowed.call(v,g) } }
      when Hash then grant.is_a?(Hash) && request.all? { |k,v| allowed.call(v,grant[k]) }
      when String then grant.is_a?(String) && File.fnmatch?(grant,request)
      else request == grant
      end
    end
    valid &&= entitlements.all? { |key,value| grants.key?(key) && allowed.call(value,grants[key]) }
    raise Failure, 'Journal App Store profile, identity or signed entitlements do not match' unless valid
    true
  end

  def self.redact(value, secrets: [])
    text = value.to_s.encode('UTF-8',invalid: :replace,undef: :replace)
    secrets.compact.reject(&:empty?).sort_by { |s| -s.length }.each { |s| text=text.gsub(s,'[REDACTED]') }
    sensitive = '(?:password|passwd|pwd|secret|token|authorization|cookie|session|api[_-]?key|credential|jwt|bearer|private[_-]?key)'
    text.gsub!(/-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----/m,'[REDACTED PRIVATE KEY]')
    text.gsub!(/\b[a-z]{4}(?:-[a-z]{4}){3}\b/i,'[REDACTED APP PASSWORD]')
    text.gsub!(/\beyJ[\w-]+\.[\w-]+\.[\w-]+\b/,'[REDACTED JWT]')
    text.gsub!(%r{(https?://)[^/\s:@]+:[^/\s@]+@},'\\1[REDACTED]@')
    scrub = lambda do |node|
      case node
      when Hash then node.to_h { |k,v| [k,k.match?(/#{sensitive}/i) ? '[REDACTED]' : scrub.call(v)] }
      when Array then node.map { |v| scrub.call(v) }
      else node
      end
    end
    offset=0
    while (first=text.index(/[\[{]/,offset))
      depth=0; quoted=false; escaped=false; last=nil
      (first...text.length).each do |index|
        char=text[index]
        if quoted
          if escaped then escaped=false
          elsif char=='\\' then escaped=true
          elsif char=='"' then quoted=false
          end
        elsif char=='"' then quoted=true
        elsif '[{'.include?(char) then depth+=1
        elsif ']}'.include?(char)
          depth-=1
          if depth.zero? then last=index; break; end
        end
      end
      break unless last
      begin
        replacement=JSON.generate(scrub.call(JSON.parse(text[first..last])))
        text[first..last]=replacement; offset=first+replacement.length
      rescue JSON::ParserError
        offset=first+1
      end
    end
    text.gsub!(/(<key>\s*[^<]*#{sensitive}[^<]*<\/key>\s*<(?:string|data)>).*?(<\/(?:string|data)>)/im,'\\1[REDACTED]\\2')
    text.gsub!(/(<([\w:-]*#{sensitive}[\w:-]*)\b[^>]*>).*?(<\/\2>)/im,'\\1[REDACTED]\\3')
    text.gsub!(/("[^"\n]*#{sensitive}[^"\n]*"\s*:\s*)"(?:\\.|[^"\\])*"/i,'\\1"[REDACTED]"')
    text.gsub!(/(^[^\n]*\b(?:#{sensitive})[\w-]*\s*[:=]\s*)[^\n]*/i,'\\1[REDACTED]')
    text.gsub!(/((?:--password|-p)\s+)(?:'[^']*'|"[^"]*"|\S+)/i,'\\1[REDACTED]')
    text
  end

  def self.transport_success?(exit_code, output)
    exit_code==0 && output.include?('UPLOAD SUCCEEDED with no errors') && !output.match?(/ERROR:|"errors"\s*:\s*\[\s*\{|STATE_ERROR\./)
  end

  def self.upload_options(ipa, version:, build:)
    {username: ACCOUNT, apple_id: APP_ID, app_identifier: BUNDLE, app_platform: 'ios',
     ipa: ipa, app_version: version, build_number: build,
     skip_waiting_for_build_processing: true, skip_submission: true, distribute_external: false}
  end

  def self.with_snapshot(ipa,sha256)
    Dir.mktmpdir('journal-upload-') do |directory|
      snapshot=File.join(directory,'Journal.ipa')
      FileUtils.copy_file(ipa,snapshot)
      raise Failure, 'IPA changed after verification' unless Digest::SHA256.file(snapshot).hexdigest==sha256
      yield snapshot
    end
  end

  # Local attempt evidence is separate from Apple receipt/processing. A crash
  # leaves a pending record that requires an explicit fresh ASC check and retry.
  class Ledger
    def initialize(directory, package)
      @directory, @package = directory, package
      FileUtils.mkdir_p(directory,mode: 0o700)
    end

    def attempt!(proof, retry_upload: false)
      File.open(File.join(@directory,'upload.lock'),File::RDWR|File::CREAT,0o600) do |lock|
        raise Failure, 'Another upload holds the lock' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
        key = Digest::SHA256.hexdigest(@package.values_at('app_id','version','build').join('/'))
        prior = Dir[File.join(@directory,"#{key}-*.json")].sort.map { |p| JSON.parse(File.read(p)) }
        raise Failure, 'Existing attempt requires a fresh ASC check and explicit retry_upload:true' if !prior.empty? && !retry_upload
        raise Failure, 'Apple receipt must be resolved; successful upload cannot be retried' if prior.any? { |r| r['status']=='tool_reported_success' }
        age = Time.now.utc-Time.iso8601(proof.fetch('checked_utc'))
        valid = @package.all? { |k,v| proof[k]==v } && age.between?(0,900) && proof['accepted_build_visible']==false && proof['active_upload']==false && proof['non_target_automatic_distribution']==false
        raise Failure, 'Fresh exact-package ASC receipt check required (within 15 minutes)' unless valid
        path=File.join(@directory,"#{key}-#{format('%04d',prior.length+1)}.json")
        record=@package.merge('started_utc'=>Time.now.utc.iso8601,'status'=>'failed_or_uncertain',
          'processing_state'=>'not_checked','distribution_changed'=>false)
        File.write(path,JSON.pretty_generate(record)+"\n",mode:'wx',perm:0o600)
        begin
          record.merge!(yield)
        ensure
          record['finished_utc']=Time.now.utc.iso8601
          File.write(path,JSON.pretty_generate(record)+"\n",perm:0o600)
        end
        record
      end
    end
  end
end
require_relative 'journal_project'
require_relative 'journal_verify'
require_relative 'journal_upload'

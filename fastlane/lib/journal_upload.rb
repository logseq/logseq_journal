require 'date'

module JournalRelease
  class << self
    attr_accessor :transport
  end

  def self.install_transport_hooks!
    return if @hooks_installed
    require 'pilot'
    FastlaneCore::FastlanePty.singleton_class.prepend(Module.new do
      def spawn(command,&block)
        evidence=JournalRelease.transport ||= {}
        evidence[:started_utc]=Time.now.utc.iso8601
        result=super(command,&block)
        evidence[:exit_code]=result
        result
      ensure
        evidence[:finished_utc]=Time.now.utc.iso8601
      end
    end)
    FastlaneCore::AltoolTransporterExecutor.prepend(Module.new do
      def execute(*args,&block)
        super
      ensure
        text=(defined?(@all_lines) && @all_lines ? @all_lines.join : '')
        errors=(defined?(@errors) && @errors ? @errors.join("\n") : '')
        JournalRelease.transport ||= {}
        secrets=[ENV['JOURNAL_UPLOAD_PASSWORD'],ENV['JOURNAL_ASC_APPLE_ID_PASSWORD'],ENV['FASTLANE_PASSWORD']]
        JournalRelease.transport[:output]=JournalRelease.redact(text,secrets: secrets)
        JournalRelease.transport[:errors]=JournalRelease.redact(errors,secrets: secrets)
      end
    end)
    FastlaneCore::ItunesTransporter.prepend(Module.new do
      def handle_two_step_failure(*)
        raise JournalRelease::Failure, 'Apple upload authentication failed; no credential-store fallback or automatic retry'
      end
    end)
    @hooks_installed=true
  end

  def self.release_secret!(name)
    value=ENV[name].to_s
    raise Failure, "#{name} is required; provide it through the process environment only" if value.empty?
    value
  end

  def self.wipe(value)
    value.replace("\0"*value.bytesize) unless value.to_s.empty?
  end

  def self.normalize_private_key_pem(key)
    header='-----BEGIN PRIVATE KEY-----'; footer='-----END PRIVATE KEY-----'
    compact=key.strip
    return key if compact.include?("\n") || !compact.start_with?(header) || !compact.end_with?(footer)
    body=compact[header.length...-footer.length].to_s.gsub(/\s+/,'')
    "#{header}\n#{body.scan(/.{1,64}/).join("\n")}\n#{footer}\n"
  end

  def self.asc_api_key!
    require 'base64'
    key_id=release_secret!('JOURNAL_ASC_KEY_ID')
    issuer_id=release_secret!('JOURNAL_ASC_ISSUER_ID')
    key=ENV['JOURNAL_ASC_PRIVATE_KEY'].to_s.dup
    if key.empty? && !ENV['JOURNAL_ASC_PRIVATE_KEY_BASE64'].to_s.empty?
      begin
        key=Base64.strict_decode64(ENV['JOURNAL_ASC_PRIVATE_KEY_BASE64'])
      rescue ArgumentError
        raise Failure, 'JOURNAL_ASC_PRIVATE_KEY_BASE64 is not valid base64'
      end
    end
    raise Failure, 'JOURNAL_ASC_PRIVATE_KEY or JOURNAL_ASC_PRIVATE_KEY_BASE64 is required' if key.empty?
    key=normalize_private_key_pem(key)
    raise Failure, 'ASC private key must be PEM content, not a path or lane argument' unless key.include?('-----BEGIN PRIVATE KEY-----')
    {'key_id'=>key_id,'issuer_id'=>issuer_id,'key'=>key,'duration'=>1140,'in_house'=>false}
  end

  def self.wipe_api_key(api_key)
    wipe(api_key['key']) if api_key['key'].is_a?(String)
  end

  def self.with_release_environment(api_key)
    saved=ENV.to_h
    begin
      ENV.keys.each { |key| ENV.delete(key) unless %w[PATH HOME TMPDIR LANG LC_ALL TERM USER LOGNAME BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG].include?(key) }
      ENV['FASTLANE_OPT_OUT_USAGE']='1'; ENV['FASTLANE_SKIP_UPDATE_CHECK']='1'
      ENV['FASTLANE_DONT_STORE_PASSWORD']='1'; ENV['FASTLANE_USER']=ACCOUNT
      yield
    ensure
      ENV.replace(saved)
      wipe_api_key(api_key)
    end
  end

  def self.connect_api_login!(api_key)
    require 'spaceship'
    return unless Spaceship::ConnectAPI.client.nil?
    token=Spaceship::ConnectAPI::Token.from(hash: api_key.transform_keys(&:to_sym))
    raise Failure, 'ASC API key could not initialize a token' unless token
    Spaceship::ConnectAPI.token=token
  end

  def self.asc_app!(api_key)
    connect_api_login!(api_key)
    app=Spaceship::ConnectAPI::App.get(app_id: APP_ID)
    raise Failure, 'ASC app is unavailable or bundle ID differs' unless app && app.bundle_id==BUNDLE
    app
  end

  def self.logseq_team_group!(groups)
    group=groups.find { |candidate| candidate.id==INTERNAL_GROUP_ID }
    valid=group && group.name==INTERNAL_GROUP && group.is_internal_group
    raise Failure, 'Logseq Team internal tester group is unavailable on the Journal app' unless valid
    group
  end

  def self.apple_version_value(value)
    parts=value.to_s.split('.')
    return value.to_s unless parts.all? { |part| part.match?(/\A\d+\z/) }
    parts.map { |part| part.to_i.to_s }.join('.')
  end

  def self.build_number_sequence(value)
    text=value.to_s
    return text.split('.').last.to_i if text.match?(/\A\d+(?:\.\d+)+\z/)
    match=text.match(/\A(\d{4})(\d{2})(\d{2})(\d{4})\z/)
    return unless match && Date.valid_date?(match[1].to_i,match[2].to_i,match[3].to_i)
    match[4].to_i
  end

  def self.next_testflight_build_number!(api_key=asc_api_key!,now: Time.now.utc)
    app=asc_app!(api_key)
    builds=Spaceship::ConnectAPI::Build.all(app_id: app.id,platform: Spaceship::ConnectAPI::Platform::IOS,limit: 200)
    upload_pages=Spaceship::ConnectAPI.get_build_uploads(app_id: app.id,filter: {platform: 'IOS'},limit: 200).all_pages
    upload_builds=upload_pages.flat_map(&:to_models).map(&:cf_build_version)
    sequences=(builds.map(&:version)+upload_builds).map { |build| build_number_sequence(build) }.compact
    latest=sequences.max
    raise Failure, 'No previous TestFlight build sequence is visible in App Store Connect' unless latest
    sequence=latest+1
    raise Failure, 'TestFlight build sequence exceeds the four-digit yyyymmddXXXX suffix' if sequence>9999
    "#{now.utc.strftime('%Y%m%d')}#{format('%04d',sequence)}"
  end

  def self.release_version_queries(version)
    canonical=apple_version_value(version)
    segments=canonical.split('.')
    alternate=if segments.length==3 && segments[2]=='0'
      segments[0..1].join('.')
    elsif segments.length==2
      "#{canonical}.0"
    end
    [canonical,alternate].compact.uniq
  end

  def self.release_build_uploads(app_id:,version:,build:)
    build_number=apple_version_value(build)
    release_version_queries(version).flat_map do |query|
      Spaceship::ConnectAPI::BuildUpload.all(app_id: app_id,version: query,build_number: build_number)
    end.uniq(&:id)
  end

  def self.release_builds(app_id:,version:,build:,limit: 10)
    build_number=apple_version_value(build)
    release_version_queries(version).flat_map do |query|
      Spaceship::ConnectAPI::Build.all(app_id: app_id,version: query,build_number: build_number,
        platform: Spaceship::ConnectAPI::Platform::IOS,limit: limit)
    end.uniq(&:id)
  end

  def self.build_upload_state(upload)
    detail=upload.state
    detail=detail['state'] || detail[:state] if detail.is_a?(Hash)
    detail.to_s
  end

  def self.automatic_receipt_check!(package,api_key)
    app=asc_app!(api_key)
    version=package.fetch('version'); build=package.fetch('build')
    uploads=release_build_uploads(app_id: app.id,version: version,build: build)
    active=uploads.any? { |upload| build_upload_state(upload)!='FAILED' }
    accepted=!release_builds(app_id: app.id,version: version,build: build).empty?
    groups=app.get_beta_groups
    target=logseq_team_group!(groups)
    automatic=groups.any? do |group|
      next false if group.id==target.id
      group.has_access_to_all_builds==true || (group.is_internal_group==true && group.has_access_to_all_builds.nil?)
    end
    package.merge('checked_utc'=>Time.now.utc.iso8601,'accepted_build_visible'=>accepted,
      'active_upload'=>active,'non_target_automatic_distribution'=>automatic,
      'target_group_id'=>target.id,'target_group_name'=>target.name)
  end

  def self.testflight_package(version, build)
    unless [version, build].all? { |value| value.to_s.match?(/\A\d+(?:\.\d+){0,2}\z/) }
      raise Failure, 'Expected the exact numeric Journal version and build number'
    end
    {'app_id'=>APP_ID, 'version'=>version, 'build'=>build}
  end

  def self.testflight_observation(app, package, apple_id)
    scope = {app_id: app.id, version: package.fetch('version'), build: package.fetch('build')}
    uploads = release_build_uploads(**scope).select { |upload| upload.platform == 'IOS' }
    builds = release_builds(**scope)
    ids = (builds.map(&:id) + uploads.reject { |upload| build_upload_state(upload) == 'FAILED' }.map(&:id)).uniq
    if apple_id
      raise Failure, 'App Store Connect shows a different active build for this version/build' if (ids - [apple_id]).any?
    elsif ids.length > 1
      raise Failure, 'Multiple Apple IDs match this version/build; inspect Build Uploads before proceeding'
    end
    apple_id ||= ids.first
    upload = uploads.find { |candidate| candidate.id == apple_id }
    build = builds.find { |candidate| candidate.id == apple_id }
    internal = build&.build_beta_detail&.internal_build_state
    ready = build&.processing_state == 'VALID' && build.expired == false &&
            %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].include?(internal)
    target = logseq_team_group!(app.get_beta_groups) if ready
    assigned = target && target.fetch_builds.any? { |candidate| candidate.id == apple_id }
    report = {
      'apple_build_id'=>apple_id,
      'upload_state'=>upload && build_upload_state(upload),
      'processing_state'=>build&.processing_state,
      'internal_build_state'=>internal,
      'uses_non_exempt_encryption'=>build&.uses_non_exempt_encryption,
      'target_group_id'=>INTERNAL_GROUP_ID,
      'target_group_name'=>INTERNAL_GROUP,
      'target_group_assigned'=>assigned,
      'ready_for_internal_testing'=>ready,
    }
    report['status'] = testflight_status(report, expired: build&.expired)
    [report, build, target]
  end

  def self.testflight_status(report, expired: false)
    return 'published_to_logseq_team' if report['ready_for_internal_testing'] && report['target_group_assigned']
    return 'ready_to_assign' if report['ready_for_internal_testing']
    return 'upload_failed' if report['upload_state'] == 'FAILED'
    if expired || %w[FAILED INVALID].include?(report['processing_state']) ||
       %w[PROCESSING_EXCEPTION EXPIRED].include?(report['internal_build_state'])
      return 'processing_failed'
    end
    if %w[MISSING_EXPORT_COMPLIANCE IN_EXPORT_COMPLIANCE_REVIEW].include?(report['internal_build_state'])
      return 'compliance_pending'
    end
    return 'awaiting_upload' if report['upload_state'] == 'AWAITING_UPLOAD'
    return 'processing' if report['upload_state'] || report['processing_state']
    'awaiting_apple_receipt'
  end

  def self.wait_for_testflight!(app, package, apple_id, wait_timeout:, persist:, require_visible: false)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_timeout
    previous = nil
    assignment_requested = false
    loop do
      report, build, target = testflight_observation(app, package, apple_id)
      state = report.fetch('status')
      if require_visible && state == 'awaiting_apple_receipt'
        raise Failure, 'App Store Connect has not verified this receipt for the exact Journal version/build'
      end
      require_visible = false
      apple_id = report.fetch('apple_build_id')
      if report != previous
        persist.call(report.merge('stage'=>'testflight_distribution'))
        puts "TestFlight #{apple_id || '(receipt pending)'}: #{state}"
        $stdout.flush
        previous = report
      end
      return report if %w[published_to_logseq_team compliance_pending upload_failed processing_failed].include?(state)
      if state == 'ready_to_assign' && !assignment_requested
        build.add_beta_groups(beta_groups: [target])
        assignment_requested = true
        persist.call('distribution_changed'=>true)
        next
      end
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if remaining <= 0
        puts 'Apple wait timed out. Use testflight_status or resume_testflight with the same receipt.'
        return report
      end
      sleep [30, remaining].min
    end
  end

  def self.publish_options(ipa,version:,build:,api_key:)
    options=upload_options(ipa,version: version,build: build)
    options.delete(:username)
    options.merge(api_key: api_key.transform_keys(&:to_sym))
  end

  def self.transport_publish!(snapshot, package, api_key)
    out,err=STDOUT.dup,STDERR.dup
    result={'status'=>'failed_or_uncertain','stage'=>'pilot_upload'}
    begin
      install_transport_hooks!; self.transport={}
      config=FastlaneCore::Configuration.create(Pilot::Options.available_options,
        publish_options(snapshot,version: package.fetch('version'),build: package.fetch('build'),api_key: api_key))
      STDOUT.reopen(File::NULL,'w'); STDERR.reopen(File::NULL,'w')
      Pilot::BuildManager.new.upload(config)
      observed=transport || {}
      raise Failure, 'Transporter did not report a successful upload' unless transport_success?(observed[:exit_code],observed[:output].to_s) && observed[:errors].to_s.empty?
      result['status']='tool_reported_success'
      result['upload_accepted']=true
      receipt = observed[:output][/\b(?:RequestUUID|Delivery UUID)\s*[:=]\s*([0-9a-f-]{36})\b/i, 1]
      result['apple_build_id'] = receipt.downcase if apple_uuid?(receipt)
    rescue StandardError => error
      result['error_class']=error.class.name
      result['error']=redact(error.message,secrets: api_key.values.map(&:to_s))
    ensure
      result['transport']=transport || {}
      result['apple_error_codes']=JSON.generate(result).scan(/ITMS-\d+|(?:STATE|ENTITY)_ERROR\.[A-Z_.]+|\(-?\d{1,6}\)/).uniq
      STDOUT.reopen(out); STDERR.reopen(err); out.close; err.close
    end
    result
  end

  def self.publish!(package:, ipa:, state_dir:, retry_upload: false, wait_timeout: 3600)
    require 'pilot'
    api_key=asc_api_key!
    external!(state_dir)
    with_snapshot(ipa,package.fetch('ipa_sha256')) do |snapshot|
      with_release_environment(api_key) do
        proof=automatic_receipt_check!(package,api_key)
        Ledger.new(state_dir,package).attempt!(proof,retry_upload: retry_upload,mode: 'publish') do |persist|
          puts "Uploading #{BUNDLE} #{package.fetch('version')} (#{package.fetch('build')}) for #{INTERNAL_GROUP}."
          result = transport_publish!(snapshot, package, api_key)
          persist.call(result)
          next result unless result['status'] == 'tool_reported_success'
          puts "Apple accepted the upload#{result['apple_build_id'] ? " (#{result['apple_build_id']})" : ''}."
          $stdout.flush
          app = asc_app!(api_key)
          wait_for_testflight!(app, package, result['apple_build_id'], wait_timeout: wait_timeout, persist: persist)
        end
      rescue StandardError => error
        raise Failure, redact(error.message,secrets: api_key.values.map(&:to_s)), cause: nil
      end
    end
  end

  def self.inspect_testflight!(version:, build:, apple_id:, state_dir: nil, wait_timeout: 3600)
    raise Failure, 'Expected an Apple delivery/build UUID' unless apple_uuid?(apple_id)
    apple_id = apple_id.downcase
    package = testflight_package(version, build)
    api_key = asc_api_key!
    with_release_environment(api_key) do
      app = asc_app!(api_key)
      next testflight_observation(app, package, apple_id).first unless state_dir
      Ledger.new(external!(state_dir),package).resume_publish!(apple_id) do |record, persist|
        wait_for_testflight!(app, package, apple_id, wait_timeout: wait_timeout, persist: persist,
                            require_visible: record['apple_build_id'].nil?)
      end
    rescue StandardError => error
      raise Failure, redact(error.message,secrets: api_key.values.map(&:to_s)), cause: nil
    end
  end

  def self.upload!(package:, ipa:, state_dir:, proof:, retry_upload: false)
    require 'io/console'
    raise Failure, 'Run upload locally with a hidden terminal prompt' unless $stdin.tty? && $stdout.tty? && IO.console
    external!(state_dir)
    with_snapshot(ipa,package.fetch('ipa_sha256')) do |snapshot|
    Ledger.new(state_dir,package).attempt!(proof,retry_upload: retry_upload) do
      puts "Upload #{BUNDLE} #{package.fetch('version')} (#{package.fetch('build')}) to Apple app #{APP_ID}; no group changes."
      secret=IO.console.getpass("#{ACCOUNT} existing App-specific password (hidden): ")
      raise Failure, 'App-specific password format is invalid; no upload started' unless secret.match?(/\A[a-z]{4}(?:-[a-z]{4}){3}\z/)
      saved=ENV.to_h
      out,err=STDOUT.dup,STDERR.dup
      result={'status'=>'failed_or_uncertain','stage'=>'pilot_configuration'}
      begin
        raise Failure, 'ASC check expired while awaiting local input; check Apple again' unless (Time.now.utc-Time.iso8601(proof.fetch('checked_utc'))).between?(0,900)
        # Only standard runtime paths survive. Credentials are process-local;
        # the command references the environment variable, never its value.
        ENV.keys.each { |key| ENV.delete(key) unless %w[PATH HOME TMPDIR LANG LC_ALL TERM USER LOGNAME BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG].include?(key) }
        ENV['FASTLANE_OPT_OUT_USAGE']='1'; ENV['FASTLANE_SKIP_UPDATE_CHECK']='1'
        ENV['FASTLANE_DONT_STORE_PASSWORD']='1'; ENV['JOURNAL_UPLOAD_PASSWORD']=secret
        ENV['FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD']='@env:JOURNAL_UPLOAD_PASSWORD'
        STDOUT.reopen(File::NULL,'w'); STDERR.reopen(File::NULL,'w')
        install_transport_hooks!; self.transport={}
        config=FastlaneCore::Configuration.create(Pilot::Options.available_options,upload_options(snapshot,version: package.fetch('version'),build: package.fetch('build')))
        result['stage']='pilot_upload'
        Pilot::BuildManager.new.upload(config)
        observed=transport || {}
        result['status']='tool_reported_success' if transport_success?(observed[:exit_code],observed[:output].to_s) && observed[:errors].to_s.empty?
      rescue StandardError => error
        result['error_class']=error.class.name
        result['error']=redact(error.message,secrets: [secret])
      ensure
        result['transport']=transport || {}
        result['apple_error_codes']=JSON.generate(result).scan(/ITMS-\d+|(?:STATE|ENTITY)_ERROR\.[A-Z_.]+|\(-?\d{1,6}\)/).uniq
        ENV.replace(saved)
        secret.replace("\0"*secret.bytesize)
        STDOUT.reopen(out); STDERR.reopen(err); out.close; err.close
      end
      puts JSON.pretty_generate(result)
      result
    end
    end
  end
end

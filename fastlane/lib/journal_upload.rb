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

  def self.asc_api_key!
    require 'base64'
    key_id=release_secret!('JOURNAL_ASC_KEY_ID')
    issuer_id=release_secret!('JOURNAL_ASC_ISSUER_ID')
    key=ENV['JOURNAL_ASC_PRIVATE_KEY'].to_s
    if key.empty? && !ENV['JOURNAL_ASC_PRIVATE_KEY_BASE64'].to_s.empty?
      begin
        key=Base64.strict_decode64(ENV['JOURNAL_ASC_PRIVATE_KEY_BASE64'])
      rescue ArgumentError
        raise Failure, 'JOURNAL_ASC_PRIVATE_KEY_BASE64 is not valid base64'
      end
    end
    raise Failure, 'JOURNAL_ASC_PRIVATE_KEY or JOURNAL_ASC_PRIVATE_KEY_BASE64 is required' if key.empty?
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

  def self.automatic_receipt_check!(package,api_key)
    app=asc_app!(api_key)
    version=package.fetch('version'); build=package.fetch('build')
    uploads=release_build_uploads(app_id: app.id,version: version,build: build)
    active=uploads.any? { |upload| upload.state!='FAILED' }
    accepted=!release_builds(app_id: app.id,version: version,build: build).empty?
    groups=app.get_beta_groups
    target=logseq_team_group!(groups)
    automatic=groups.any? { |group| group.id!=target.id && group.has_access_to_all_builds!=false }
    package.merge('checked_utc'=>Time.now.utc.iso8601,'accepted_build_visible'=>accepted,
      'active_upload'=>active,'non_target_automatic_distribution'=>automatic,
      'target_group_id'=>target.id,'target_group_name'=>target.name)
  end

  def self.verify_logseq_team_assignment!(package,api_key)
    app=asc_app!(api_key)
    target=logseq_team_group!(app.get_beta_groups)
    build=release_builds(app_id: app.id,version: package.fetch('version'),build: package.fetch('build')).first
    raise Failure, 'Uploaded build is not visible after processing' unless build
    assigned=target.fetch_builds.any? { |candidate| candidate.id==build.id }
    raise Failure, 'Logseq Team group is not assigned to the processed build' unless assigned
    internal_state=build.build_beta_detail&.internal_build_state
    internal_states=Spaceship::ConnectAPI::BuildBetaDetail::InternalState
    {'build_id'=>build.id,'processing_state'=>build.processing_state,
     'internal_build_state'=>internal_state,
     'ready_for_internal_testing'=>[internal_states::READY_FOR_BETA_TESTING,internal_states::IN_BETA_TESTING].include?(internal_state),
     'target_group_id'=>target.id,'target_group_name'=>target.name,'target_group_assigned'=>true}
  end

  def self.publish_options(ipa,version:,build:,wait_timeout:,api_key:)
    options=upload_options(ipa,version: version,build: build)
    options.delete(:username)
    options.merge(
      api_key: api_key.transform_keys(&:to_sym),
      skip_waiting_for_build_processing: false,skip_submission: false,
      distribute_external: false,groups: [INTERNAL_GROUP_ID],notify_external_testers: false,
      uses_non_exempt_encryption: false,expire_previous_builds: false,
      reject_build_waiting_for_review: false,submit_beta_review: false,
      wait_processing_interval: 30,wait_processing_timeout_duration: wait_timeout)
  end

  def self.publish!(package:, ipa:, state_dir:, retry_upload: false, wait_timeout: 3600)
    require 'pilot'
    api_key=asc_api_key!
    external!(state_dir)
    with_snapshot(ipa,package.fetch('ipa_sha256')) do |snapshot|
      with_release_environment(api_key) do
        proof=automatic_receipt_check!(package,api_key)
        Ledger.new(state_dir,package).attempt!(proof,retry_upload: retry_upload) do
          puts "Publish #{BUNDLE} #{package.fetch('version')} (#{package.fetch('build')}) to Apple app #{APP_ID}, then assign only #{INTERNAL_GROUP}."
          out,err=STDOUT.dup,STDERR.dup
          result={'status'=>'failed_or_uncertain','stage'=>'pilot_configuration'}
          begin
            install_transport_hooks!; self.transport={}
            config=FastlaneCore::Configuration.create(Pilot::Options.available_options,
              publish_options(snapshot,version: package.fetch('version'),build: package.fetch('build'),wait_timeout: wait_timeout,api_key: api_key))
            STDOUT.reopen(File::NULL,'w'); STDERR.reopen(File::NULL,'w')
            err.puts('Uploading and waiting for Apple processing; group assignment will be verified after distribution.')
            result['stage']='pilot_upload_process_distribute'
            Pilot::BuildManager.new.upload(config)
            observed=transport || {}
            raise Failure, 'Transporter did not report a successful upload' unless transport_success?(observed[:exit_code],observed[:output].to_s) && observed[:errors].to_s.empty?
            result['status']='tool_reported_success'
            result['stage']='verify_logseq_team_assignment'
            result['distribution']=verify_logseq_team_assignment!(package,api_key)
            result['distribution_changed']=true
            result['status']='published_to_logseq_team'
          rescue StandardError => error
            result['error_class']=error.class.name
            result['error']=redact(error.message,secrets: api_key.values.map(&:to_s))
          ensure
            result['transport']=transport || {}
            result['apple_error_codes']=JSON.generate(result).scan(/ITMS-\d+|(?:STATE|ENTITY)_ERROR\.[A-Z_.]+|\(-?\d{1,6}\)/).uniq
            STDOUT.reopen(out); STDERR.reopen(err); out.close; err.close
          end
          puts JSON.pretty_generate(result)
          result
        end
      end
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

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
        JournalRelease.transport[:output]=JournalRelease.redact(text,secrets: [ENV['JOURNAL_UPLOAD_PASSWORD']])
        JournalRelease.transport[:errors]=JournalRelease.redact(errors,secrets: [ENV['JOURNAL_UPLOAD_PASSWORD']])
      end
    end)
    FastlaneCore::ItunesTransporter.prepend(Module.new do
      def handle_two_step_failure(*)
        raise JournalRelease::Failure, 'Apple upload authentication failed; no credential-store fallback or automatic retry'
      end
    end)
    @hooks_installed=true
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

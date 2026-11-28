require_relative '../fastlane/lib/journal_release'

def expect_release_failure(message)
  yield
  raise "Expected #{message}"
rescue JournalRelease::Failure => error
  raise unless error.message.include?(message)
end

def receipt_proof(package)
  package.merge(
    'checked_utc'=>Time.now.utc.iso8601,
    'accepted_build_visible'=>false,
    'active_upload'=>false,
    'non_target_automatic_distribution'=>false,
  )
end

Dir.mktmpdir('journal-testflight-recovery-') do |directory|
  package = {'app_id'=>JournalRelease::APP_ID, 'version'=>'1.0', 'build'=>'202611280094'}
  ipa = File.join(directory, 'Journal.ipa')
  File.write(ipa, 'offline upload fixture')
  package['ipa_sha256'] = Digest::SHA256.file(ipa).hexdigest
  proof = receipt_proof(package)
  ledger = JournalRelease::Ledger.new(directory, package)
  upload_id = '811c447a-7f71-4342-901c-17039462a013'
  build_id = '22036b4f-5318-44a4-bc82-3098e23c25f6'

  # Completed records from the previous driver are still protected from retries.
  previous = package.merge('build'=>'202611270093')
  old_ledger = JournalRelease::Ledger.new(directory, previous)
  old_ledger.attempt!(receipt_proof(previous)) { {'status'=>'published_to_logseq_team'} }
  expect_release_failure('resume or inspect the existing build') do
    old_ledger.attempt!(receipt_proof(previous), retry_upload: true) { raise 'Published build was uploaded twice' }
  end

  JournalRelease.define_singleton_method(:asc_api_key!) { {} }
  JournalRelease.define_singleton_method(:automatic_receipt_check!) { |*, **| proof }
  JournalRelease.define_singleton_method(:transport_publish!) do |*|
    {'status'=>'tool_reported_success', 'upload_accepted'=>true, 'apple_upload_id'=>upload_id}
  end
  JournalRelease.define_singleton_method(:asc_app!) { |_| raise Interrupt }
  begin
    JournalRelease.publish!(package: package, ipa: ipa, state_dir: directory)
    raise 'Expected interruption after transport acceptance'
  rescue Interrupt
    # Interrupt as the publish entry starts checking processing.
  end
  key = Digest::SHA256.hexdigest(package.values_at('app_id', 'version', 'build').join('/'))
  record = JSON.parse(File.read(File.join(directory, "#{key}-0001.json")))
  raise 'Upload acceptance and receipt were lost on interruption' unless
    record['upload_accepted'] && record['apple_upload_id'] == upload_id
  expect_release_failure('resume or inspect the existing build') do
    ledger.attempt!(proof, retry_upload: true) { raise 'Accepted upload was started twice' }
  end

  composition = Struct.new(:internal_build_state).new('MISSING_EXPORT_COMPLIANCE')
  build = Struct.new(:id, :processing_state, :expired, :build_beta_detail, :uses_non_exempt_encryption)
                .new(build_id, 'VALID', false, composition, false)
  upload = JournalRelease::TestFlightUpload.new(id: upload_id, build_id: build_id, state: 'COMPLETE')
  target = Struct.new(:id, :name, :is_internal_group).new(JournalRelease::INTERNAL_GROUP_ID, 'Logseq Team', true)
  app = Struct.new(:id, :get_beta_groups).new(JournalRelease::APP_ID, [target])
  assignments = []
  build.define_singleton_method(:add_beta_groups) do |beta_groups:|
    raise 'Assigned before compliance cleared or outside Logseq Team' unless composition.internal_build_state == 'READY_FOR_BETA_TESTING' && beta_groups == [target]
    assignments << id
  end
  target.define_singleton_method(:fetch_builds) { assignments.include?(build_id) ? [build] : [] }
  JournalRelease.define_singleton_method(:testflight_uploads) { |**| [upload] }
  JournalRelease.define_singleton_method(:release_builds) { |**| [build] }

  resume = lambda do |id|
    ledger.resume_publish!(id) do |record, persist|
      JournalRelease.wait_for_testflight!(app, package, id, wait_timeout: 1,
                                        persist: persist, require_visible: record['apple_build_id'].nil?)
    end
  end
  expect_release_failure('differs from the recorded receipt') { resume.call('3ee01318-7ee4-4cef-b27f-7aa077da6fc1') }
  pending = resume.call(upload_id)
  raise 'Wrong build receipt or availability before compliance cleared' unless
    pending['apple_upload_id'] == upload_id && pending['apple_build_id'] == build_id &&
    pending['status'] == 'compliance_pending' && assignments.empty?

  composition.internal_build_state = 'READY_FOR_BETA_TESTING'
  result = resume.call(build_id)
  raise 'Exact build was not assigned and verified' unless result['status'] == 'published_to_logseq_team' &&
    result['target_group_assigned'] && result['ready_for_internal_testing']
  resume.call(upload_id)
  raise 'Resuming a completed attempt reassigned the group' unless assignments == [build_id]
end

puts 'TestFlight recovery regression passed'

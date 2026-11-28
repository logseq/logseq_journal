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
  proof = receipt_proof(package)
  ledger = JournalRelease::Ledger.new(directory, package)
  apple_id = '811c447a-7f71-4342-901c-17039462a013'

  # Completed records from the previous driver are still protected from retries.
  previous = package.merge('build'=>'202611270093')
  old_ledger = JournalRelease::Ledger.new(directory, previous)
  old_ledger.attempt!(receipt_proof(previous)) { {'status'=>'published_to_logseq_team'} }
  expect_release_failure('resume or inspect the existing build') do
    old_ledger.attempt!(receipt_proof(previous), retry_upload: true) { raise 'Published build was uploaded twice' }
  end

  begin
    ledger.attempt!(proof, mode: 'publish') do |persist|
      persist.call('status'=>'processing', 'upload_accepted'=>true)
      raise Interrupt
    end
  rescue Interrupt
    # The process stopped after acceptance and before saving Apple's build ID.
  end
  expect_release_failure('resume or inspect the existing build') do
    ledger.attempt!(proof, retry_upload: true) { raise 'Accepted upload was started twice' }
  end

  composition = Struct.new(:internal_build_state).new('MISSING_EXPORT_COMPLIANCE')
  build = Struct.new(:id, :processing_state, :expired, :build_beta_detail, :uses_non_exempt_encryption)
                .new(apple_id, 'VALID', false, composition, false)
  upload = Struct.new(:id, :platform, :state).new(apple_id, 'IOS', 'COMPLETE')
  target = Struct.new(:id, :name, :is_internal_group).new(JournalRelease::INTERNAL_GROUP_ID, 'Logseq Team', true)
  app = Struct.new(:id, :get_beta_groups).new(JournalRelease::APP_ID, [target])
  assignments = []
  build.define_singleton_method(:add_beta_groups) do |beta_groups:|
    raise 'Assigned before compliance cleared or outside Logseq Team' unless composition.internal_build_state == 'READY_FOR_BETA_TESTING' && beta_groups == [target]
    assignments << id
  end
  target.define_singleton_method(:fetch_builds) { assignments.include?(apple_id) ? [build] : [] }
  JournalRelease.define_singleton_method(:release_build_uploads) { |**| [upload] }
  JournalRelease.define_singleton_method(:release_builds) { |**| [build] }

  resume = lambda do |id|
    ledger.resume_publish!(id) do |record, persist|
      JournalRelease.wait_for_testflight!(app, package, id, wait_timeout: 1,
                                        persist: persist, require_visible: record['apple_build_id'].nil?)
    end
  end
  expect_release_failure('different active build') { resume.call('22036b4f-5318-44a4-bc82-3098e23c25f6') }
  pending = resume.call(apple_id)
  raise 'Wrong build receipt or availability before compliance cleared' unless
    pending['apple_build_id'] == apple_id && pending['status'] == 'compliance_pending' && assignments.empty?

  composition.internal_build_state = 'READY_FOR_BETA_TESTING'
  result = resume.call(apple_id)
  raise 'Exact build was not assigned and verified' unless result['status'] == 'published_to_logseq_team' &&
    result['target_group_assigned'] && result['ready_for_internal_testing']
  resume.call(apple_id)
  raise 'Resuming a completed attempt reassigned the group' unless assignments == [apple_id]
end

puts 'TestFlight recovery regression passed'

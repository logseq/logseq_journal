#!/usr/bin/env ruby
# Print the next TestFlight build number, using App Store Connect as the sequence authority.
require_relative 'lib/journal_release'

begin
  result = nil
  original_stdout = $stdout.dup
  begin
    $stdout.reopen(File::NULL, 'w')
    result = JournalRelease.next_testflight_build_number!
  ensure
    $stdout.reopen(original_stdout)
    original_stdout.close
  end
  puts result
rescue StandardError => error
  secrets = ENV.values_at('JOURNAL_ASC_KEY_ID', 'JOURNAL_ASC_ISSUER_ID', 'JOURNAL_ASC_PRIVATE_KEY', 'JOURNAL_ASC_PRIVATE_KEY_BASE64')
  warn "#{error.class}: #{JournalRelease.redact(error.message, secrets: secrets)}"
  exit 1
end

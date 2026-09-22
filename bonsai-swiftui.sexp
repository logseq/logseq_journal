(lang 4)

(app
 (name logseq_journal)
 (apple_root apple)
 (native_target app/native_embed.exe.o)
 (features network sqlite)
 (macos
  (bundle_identifier com.logseq.journal)
  (minimum_version 26.0)
  (architectures arm64)
  (entitlements
   (debug config/entitlements/macos-debug-profile.entitlements)
   (profile config/entitlements/macos-debug-profile.entitlements)
   (release config/entitlements/macos-release.entitlements)))
 (ios
  (bundle_identifier com.example.bonsaiFlutterLogseqJournalHost)
  (minimum_version 26.0)
  (architectures arm64)
  (entitlements
   (debug config/entitlements/ios-debug-profile.entitlements)
   (profile config/entitlements/ios-debug-profile.entitlements)
   (release config/entitlements/ios-release.entitlements)))
 (swift_packages
  (package
   (id amplify-swift)
   (url https://github.com/aws-amplify/amplify-swift.git)
   (requirement (exact 2.61.0))
   (products
    (product (name Amplify) (platforms macos ios))
    (product (name AWSCognitoAuthPlugin) (platforms macos ios))))))

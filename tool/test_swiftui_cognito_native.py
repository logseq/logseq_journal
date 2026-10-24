"""Exercise native adapters with only OS entry points replaced; never runs GUI or Keychain."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-cognito-native-') as directory:
    destination = Path(directory)
    native = (root/'swift/JournalCognitoNative.swift').read_text()
    substitutions = {
        'SecItemCopyMatching(': 'FixtureSecurity.copy(',
        'SecItemUpdate(': 'FixtureSecurity.update(',
        'SecItemAdd(': 'FixtureSecurity.add(',
        'SecItemDelete(': 'FixtureSecurity.delete(',
        'ASWebAuthenticationPresentationContextProviding': 'FixturePresentationContext',
        'ASWebAuthenticationSession(': 'FixtureWebAuthenticationSession(',
        'ASWebAuthenticationSession?': 'FixtureWebAuthenticationSession?',
        'session: ASWebAuthenticationSession)': 'session: FixtureWebAuthenticationSession)',
        'ASPresentationAnchor': 'FixtureAnchor',
        'NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow': 'FixtureBrowserState.anchor',
    }
    for before, after in substitutions.items():
        assert before in native, f'native fixture boundary changed: {before}'
        native = native.replace(before, after)
    # Swift file-private access stays intact; append the narrow native owner
    # fixture in the same compilation file rather than changing visibility.
    fixture = destination/'NativeTests.swift'
    binding = (root/'swift/JournalLocalAccountBindingStore.swift').read_text()
    for before, after in list(substitutions.items())[:4]:
        assert before in binding, f'binding fixture boundary changed: {before}'
        binding = binding.replace(before, after)
    fixture.write_text(native + '\n' + binding + '\n' + (root/'apple-tests/authentication/JournalCognitoNativeReasonTests.swift').read_text())
    sources = ['JournalPlatformWire.swift','JournalPlatformServices.swift','JournalAuthentication.swift',
               'JournalCognitoOAuth.swift','JournalCognitoSession.swift']
    command = ['xcrun','swiftc','-swift-version','6','-Xfrontend','-disable-sandbox',
        '-module-cache-path',str(destination/'modules'),*[str(root/'swift'/s) for s in sources]]
    subprocess.run([*command,str(fixture),'-o',str(destination/'tests')],check=True)
    subprocess.run([str(destination/'tests')],check=True,timeout=30)
    # The actual native framework types must still compile, without launching.
    subprocess.run([*command,str(root/'swift/JournalCognitoNative.swift'),'-typecheck'],check=True)

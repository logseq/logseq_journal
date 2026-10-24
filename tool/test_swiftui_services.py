"""Verify the native platform owner against isolated capability boundaries."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-platform-services-') as directory:
    diagnostics = Path(directory)/'diagnostic-tests'
    subprocess.run(['xcrun','swiftc','-swift-version','6','-module-cache-path',str(Path(directory)/'modules'),
                    str(root/'swift/JournalSafeDiagnostic.swift'),
                    str(root/'apple-tests/platform-services/JournalSafeDiagnosticTests.swift'),'-o',str(diagnostics)],check=True)
    subprocess.run([str(diagnostics)],check=True,timeout=15)
    executable = Path(directory)/'services-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(Path(directory)/'modules'),
                    str(root/'swift/JournalPlatformWire.swift'), str(root/'swift/JournalSafeDiagnostic.swift'),
                    str(root/'swift/JournalPlatformServices.swift'),
                    str(root/'apple-tests/platform-services/JournalPlatformServicesTests.swift'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
    bridge = Path(directory)/'application-platform-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-disable-sandbox',
                    '-module-cache-path', str(Path(directory)/'modules'),
                    str(root/'swift/JournalPlatformWire.swift'), str(root/'swift/JournalSafeDiagnostic.swift'),
                    str(root/'swift/JournalPlatformEvents.swift'),
                    str(root/'swift/JournalPlatformServices.swift'),
                    str(root/'swift/JournalApplicationPlatform.swift'),
                    str(root/'apple-tests/application-platform/JournalApplicationPlatformTests.swift'),
                    '-o', str(bridge)], check=True)
    subprocess.run([str(bridge)], check=True, timeout=15)
    recovery = Path(directory)/'recovery-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-Xfrontend', '-disable-sandbox',
                    '-module-cache-path', str(Path(directory)/'modules'),
                    str(root/'swift/JournalPlatformWire.swift'), str(root/'swift/JournalSafeDiagnostic.swift'),
                    str(root/'swift/JournalPlatformServices.swift'),
                    str(root/'swift/JournalLocalAccountBindingStore.swift'),
                    str(root/'apple-tests/platform-services/JournalAccountRecoveryTests.swift'),
                    '-o', str(recovery)], check=True)
    subprocess.run([str(recovery)], check=True, timeout=60)
    threading = Path(directory)/'account-threading-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(Path(directory)/'modules'),
                    str(root/'swift/JournalPlatformWire.swift'), str(root/'swift/JournalSafeDiagnostic.swift'),
                    str(root/'swift/JournalPlatformServices.swift'),
                    str(root/'swift/JournalStartupConfiguration.swift'),
                    str(root/'swift/JournalNativeServices.swift'),
                    str(root/'apple-tests/platform-services/JournalAccountThreadingTests.swift'),
                    '-o', str(threading)], check=True)
    subprocess.run([str(threading)], check=True, timeout=60)
    cold = Path(directory)/'cold-tests'
    subprocess.run(['xcrun','swiftc','-swift-version','6','-module-cache-path',str(Path(directory)/'modules'),
                    str(root/'swift/JournalPlatformWire.swift'), str(root/'swift/JournalSafeDiagnostic.swift'),
                    str(root/'swift/JournalPlatformServices.swift'),
                    str(root/'swift/JournalStartupConfiguration.swift'),
                    str(root/'swift/JournalNativeServices.swift'),
                    str(root/'apple-tests/platform-services/JournalAccountColdStartRecoveryTests.swift'),
                    '-o',str(cold)],check=True)
    for scenario in ['present','absent']:
        store = Path(directory)/scenario
        store.mkdir()
        for phase in ['stage','locked','recover']:
            subprocess.run([str(cold),phase,str(store),scenario],check=True,timeout=15)

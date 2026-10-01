"""Relink unchanged, verified native host objects with this checkout's OCaml object.
Does not mutate the source host cache. Run after dune builds the complete object.
"""
import json, pathlib, subprocess, sys, plistlib
root=pathlib.Path(__file__).resolve().parents[1]
source=pathlib.Path('/Users/rcmerci/Documents/Codex/2026-09-30/task-3/sources/logseq_journal')
mode=sys.argv[1] if len(sys.argv)>1 else 'production'
out=root/'review'/('JournalDesignFixture.app' if mode=='fixture' else 'LogseqJournalDesign.app')
out.mkdir(exist_ok=True)
obj=root/'review'/f'journal-{mode}-iossim.o'
subprocess.run(['xcrun','vtool','-set-build-version','7','26.0','26.1','-replace','-output',str(obj),str(root/'_build/default/app/native_embed.exe.o')],check=True)
info=plistlib.loads((root/'apple/Info.plist').read_bytes())
if mode=='fixture':
 info.update(CFBundleIdentifier='com.logseq.journal.designpreview',CFBundleDisplayName='Journal Design Preview',CFBundleName='Journal Design Preview')
(out/'Info.plist').write_bytes(plistlib.dumps(info))
ent=plistlib.loads((root/'config/entitlements/ios-debug-profile.entitlements').read_bytes())
ent['keychain-access-groups']=['K378MFWK59.'+info['CFBundleIdentifier']]
ent['application-identifier']='K378MFWK59.'+info['CFBundleIdentifier']
entfile=root/'review'/f'{mode}-entitlements.plist';entfile.write_bytes(plistlib.dumps(ent))
s=(source/'swift/.build/debug.yaml').read_text()
args=next(json.loads(line.strip()[6:]) for line in s.splitlines() if line.strip().startswith('args: [') and 'JournalApp.product/Objects.LinkFileList' in line and 'ios-simulator/debug' in line)
args[args.index('-o')+1]=str(out/'JournalApp')
for i,value in enumerate(args):
 if value.endswith('/journal_complete.o'): args[i]=str(obj)
 if value.endswith('/ios-sim-entitlements.plist'):args[i]=str(entfile)
(root/'review'/f'{mode}-link-command.json').write_text(json.dumps(args,indent=2))
subprocess.run(args,check=True)
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(out)],check=True)
print(out)

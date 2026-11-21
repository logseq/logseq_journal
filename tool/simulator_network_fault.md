# Simulator runtime network fault injection

This is acceptance-only runtime fault injection, not an ordinary production run.
No app source, binary, bundle, native inputs, TLS, credentials, or signatures are
changed. Only the main operator may launch the owned App A with this library.
Do not launch, terminate, attach, or manipulate the primary Simulator while its
owner has a pending mutation. No global network settings or dependencies change.

## Build and inspect (no Simulator interaction)

From the repository root:

```sh
sh tool/build_simulator_network_fault.sh

```

The helper builds arm64 iOS 26 Simulator code and ad-hoc signs only the separate
dylib. `__DATA,__interpose` is the standard dyld replacement/original pair pattern:
original-symbol calls from the interposer image remain original calls. It avoids
`dlsym`, allocation, lazy lookup, and recursive file-close resolution inside hooks.
SDK `sys/socket.h` supplies the exact `connectx` signature. This requires dyld
interposition to be honored; compilation/signature checks do not prove loading.

The helper uses a new private temporary directory, inspects and verifies the dylib,
and deletes its own build products on exit. Optional JOURNAL_TEST_DYLIB_DEST copies
the signed dylib exclusively (O_EXCL | O_NOFOLLOW) into a canonical owned mode-700
parent; it never overwrites a file. Runtime loading and acceptance remain pending.

## Build-only revision evidence

At HEAD `4a85af1ef08a2153a806ecea605f5695e38e10ba`, the revised source compiled
successfully for `arm64-apple-ios26.0-simulator` with `-Wall -Wextra -Werror`.
Shell syntax, ad-hoc signing and strict signature verification passed; otool/nm
inspection completed. The helper removed its temporary dylib and directory.

- C SHA-256: `df8c712bc84e54d79bb7d678fb14127155eb74b44bba2e4855ac5caf7c51da72`.
- Helper SHA-256: `4a0be9b08bfd94ca12bdc712b52da21a16940527f21acc45a5f7875599760f4f`.
- Built dylib SHA-256: `2fbc330c3a9dd16937a9c31e7164b601512841a04782b849923612ce4da479f1`.

No runtime smoke, Simulator operation or fault injection was performed. Main must
execute the heartbeat and actual-transport acceptance recipe below after re-review.

## Main-owner-only launch template (NOT executed by the implementation task)

After independent review and when the main owner can safely restart App A, obtain
its existing data container with `simctl get_app_container` using its full owned
Simulator UDID, not `booted`. Do not use App B's container. Choose a new private,
canonical task directory inside App A's data container, outside its `.app` bundle.
Set `A_CONTAINER` and `A_UDID` explicitly after checking ownership; do not infer
the full UDID from the abbreviated `9733B6DF...` identifier.

```sh
set -eu
: "${A_CONTAINER:?set owned App A data container}" "${A_UDID:?set full owned UDID}"
TASK_DIR=$(python3 - "$A_CONTAINER" <<'PY'
import os, sys, tempfile
container = os.path.realpath(sys.argv[1])
parent = os.path.join(container, "tmp")
if os.path.realpath(parent) != parent or os.stat(parent).st_uid != os.getuid():
    raise SystemExit("expected owned canonical container tmp")
path = tempfile.mkdtemp(prefix="network-fault-", dir=parent)
os.chmod(path, 0o700)
print(path)
PY
)
JOURNAL_TEST_DYLIB_DEST="$TASK_DIR/simulator_network_fault.dylib" \
sh tool/build_simulator_network_fault.sh
# Status must not already exist. Flag absent starts online.
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$TASK_DIR/simulator_network_fault.dylib" \
SIMCTL_CHILD_JOURNAL_TEST_NETWORK_FAULT_FLAG="$TASK_DIR/offline" \
SIMCTL_CHILD_JOURNAL_TEST_NETWORK_FAULT_STATUS="$TASK_DIR/status.json" \
xcrun simctl launch "$A_UDID" com.logseq.journal
```

These are command-local launch variables, not `launchctl setenv` or production
settings. The process needs both explicit absolute paths. A fresh status file is
created exclusively, without following a final symlink, mode 0600. Keep all path
components in the operator-owned private directory; no shared or symlink paths.
The injector enforces a canonical shared parent directory owned by the process user
with no group/other permissions. No library copy into the bundle, re-signing of the
App, protection bypass, or attach.

Main must capture process stderr through its launch/supervisor stream. Before EACH
case, require two valid schema-2/capacity-256 snapshots from this fresh process,
with heartbeat strictly increasing within 2 seconds, expected offline state,
terminal_error:false, infrastructure_errors:0 and shutdown_errors:0. Continue
checking at least every 500 ms and through the final case evidence. Missing,
unparseable or non-advancing heartbeat for 2 seconds, any counter error, process
exit, or terminal stderr diagnostic FAILS the case; a stale file is never readiness.
Retry incomplete concurrent JSON reads only within that deadline. Check heartbeat
again after flag transitions and after each case. A flag transition must also show
the expected offline state and, on entry, increased fault_generation. Heartbeat is
a monotonic per-process counter, not file mtime or wall clock. Do not reuse a status
file across launches. A pre-case check alone cannot validate the whole case.

Create the ephemeral signal exclusively; never overwrite status or another file:


```sh
python3 - "$TASK_DIR/offline" <<'PY'
import os, sys
os.close(os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
PY
# Wait for status.json offline:true, then exercise the actual owned App A.
# Remove the flag only when the acceptance case calls for recovery:
rm "$TASK_DIR/offline"
```

The monitor polls every 100 ms. It calls `shutdown(SHUT_RDWR)`, never `close`, on
registered connected IPv4/IPv6 sockets per fault generation; application ownership stays
intact. New IPv4/IPv6 `connect` and `connectx` attempts return -1/ENETDOWN while the
flag exists. AF_UNIX remains untouched. Removing the flag restores forwarding;
shutdown sockets do not resurrect, so the app must reconnect normally. The ledger
is process-local, mutex-protected, limited to 256 live sockets, cleared on close.
Overflow refuses socket creation with ENOBUFS and increments infrastructure errors
rather than silently permitting untracked traffic. Status contains only bounded
numeric counters and booleans, never addresses, tokens, payloads, or graph data.
Only the monitor writes status, every poll with an advancing heartbeat; read snapshots
with retry if concurrent writing yields incomplete JSON. Successful shutdowns and
rejected connects are distinct evidence; shutdown errors are never hidden.

The monitor has one thread, one status fd and a bounded ledger; unload joins after
its polling sleep and closes only its own status fd. There is no service/cache.
A blocked filesystem can delay join; use only the local Simulator data filesystem.
Fork handlers prevent an inherited locked ledger: a fork records ENOTSUP in the
parent, disables injection in the child, and emits a constant child diagnostic.
Fork is unsupported for acceptance, not silently represented as injected coverage.
Initialization failures report a constant stderr message and no valid readiness
status. Status-write failure latches a terminal acceptance error, emits one constant
stderr diagnostic and retries status at the bounded polling rate WITHOUT exiting
the physical monitor or disabling injection. If writes recover, the sticky error
counter remains visible. If the fd stays broken, no file-based error delivery is
promised: main must reject missing heartbeat advancement and supervise stderr.
The App is NOT stopped, signaled or claimed process-fail-closed. Any infrastructure
error invalidates acceptance even when physical shutdown continues.

Real connect/connectx runs outside the mutex. A bounded per-socket in-flight count
and descriptor identity protect completion reconciliation from slot/fd reuse.
After the original returns, current fault state is sampled under the ledger lock
and connected sockets are actually shut down. The monitor continues checking
pending/nonblocking connections; unconnected sockets are not completed coverage.
Only successful shutdown with no in-flight calls marks a generation covered;
failed shutdowns remain retryable. A later connection completion clears coverage.
Flag creation itself is not instantaneous network isolation; require actual main
transport smoke evidence after the monitor observes it.

## Required acceptance evidence and limits

The main owner must prove actual dyld loading first, then actual server connection
failure, persistent offline retry exhaustion and conflict behavior in App A, while
App B stays online and its server checkpoint advances. Retain the pending mutation
and its ID; after flag removal prove recovery of that same ID, without duplication.
Bind results to app/native provenance, HEAD, tool hashes and this injected launch.
Counters alone are not server-failure or sync-recovery proof.

Coverage is specifically sockets created via interposed `socket`, closed via
interposed `close`, and connections via interposed `connect`/`connectx`. Direct
syscalls, private/nocancel variants, duplicated/received/accepted descriptors,
connections predating library initialization, and out-of-process system services
are not fully covered. An intercepted offline connect on an unregistered network
fd is still rejected, but records ENOTSUP because shutdown coverage is incomplete. Unconnected UDP `sendto`/`sendmsg` is not blocked by these hooks;
shutdown can fail on such sockets. DNS delegated to a resolver service is not
process-local traffic. Do not claim whole-App offline, QUIC/DNS isolation, or use
this for acceptance if the actual app transport takes an uncovered path. A stricter
transport-specific extension needs review and actual-app proof, not a test-for-test.
There is no Simulator launch/attach/UI/kill or actual fault verification in the
implementation/build task. Dyld eligibility and all runtime acceptance remain pending.

## Cleanup (main owner, after preserving evidence and the mutation)

Remove the flag, recover and verify sync first. At an owner-approved restart,
launch App A without any of the three `SIMCTL_CHILD_*` variables. If the operator
exported them in a shell, unset them before that launch. After the injected process
has exited and evidence is saved, delete only this case's status/flag/dylib and new
task directory. Do not delete graph/container data. Remove the workspace build
artifact when no longer needed; keep these reusable tool sources. No commit or
production rollout before independent review.

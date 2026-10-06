# iCloud activation comparison

This experiment compares revision `22fa325` with the repository HEAD captured
at preparation time. Both signed iCloud Dev builds receive the identical lab
harness. The only other overlay allows the existing isolated lab factory to
configure automatic engine sync. Production sync changes are never copied
from the newer revision into the baseline. The instrumentation is captured
from the working tree and identified by its exact hash.

Use a fresh output directory outside the repository:

```sh
python3 Tools/CloudKit/run_activation_comparison.py prepare \
  /private/tmp/meh-activation-prepared --mac-publisher
python3 Tools/CloudKit/run_activation_comparison.py run \
  /private/tmp/meh-activation-prepared \
  /private/tmp/meh-activation-results --trials 3 \
  --publisher-app "/private/tmp/meh-activation-prepared/mac-publisher-build/\
Build/Products/Debug-iCloud/meh.md iCloud Dev.app"
```

The runner reuses the existing reserved simulator and never creates one.
If it contains an ordinary Dev app, the runner refuses replacement. One-time
adoption requires explicit owner authorization and a local backup of the
installed app bundle and its data container. The owner installs the verified
lab once; the runner can then reuse it. Installation retains notebook data,
though iOS may migrate the container and clear cached app screenshots. Check
existing file hashes against the backup before continuing.
The lab opens only fresh `SyncLab/<UUID>` directories and isolated fictional
cloud zones; it never automatically opens the ordinary notebook. No general
permission flag bypasses the installed-app guard.

Preparation archives both revisions, applies the shared instrumentation, and
builds thin arm64 `Debug-iCloud` apps with inherited flags and `SYNC_LAB`.
Signing stays on. With `--mac-publisher`, preparation also builds the same
harness as a signed Mac lab and pins its binary and harness hashes. The run
accepts only that prepared publisher. Both clients require available accounts
and access to the same private test zone.
The existing verifier checks signatures, lab entry points, bundle identity,
and embedded Development CloudKit entitlements. Preparation records exact
source revisions, harness hash, binary hashes, factory hashes, Xcode version,
and build commands. Existing package checkouts, artifacts and repositories
seed the task cache.
It does not install or launch either app unless `--account-preflight` is used.

The run command verifies prepared binaries again. It uses only the existing
`meh.md AI CloudKit` iPhone 18 Pro simulator with iOS 27.
Preparation requires exactly one compatible device and pins its UUID in the
manifest. Every later run verifies that exact UUID. It refuses duplicates,
unavailable devices, wrong identity/runtime, and installed ordinary Dev apps.
A hostwide lock serializes simulator use across worktrees. It may boot that
exact device; it never creates, erases, resets, or uninstalls a simulator or
app.

Run account-only preflight again without rebuilding:

```sh
python3 Tools/CloudKit/run_activation_comparison.py preflight \
  /private/tmp/meh-activation-prepared \
  /private/tmp/meh-activation-account-check
```

An account-only preflight also runs before any fictional cloud fixtures. If the
simulator lacks an available iCloud account, execution stops with evidence.
Sign into iCloud manually in that simulator's Settings and rerun with a fresh
results directory. The tool does not read, enter, save, or print credentials.
No experiment can establish live CloudKit performance before this succeeds.

Every variant trial gets a fresh UUID, fictional notebook, isolated cloud
zone, and local lab directories. The phase sequence is:

1. `activation-prepare`: seed the fictional source through CKSyncEngine and
   create one durable `receiver-startup` state.
2. `activation-update`: write the remote update directly through CKDatabase,
   verify its saved snapshot, and prepare the receiver's local backlog.
3. `activation-startup`: measure a fresh process starting that receiver's
   Workspace, then deliver its initial foreground callback after loading.
   Both stay timed.
4. `activation-foreground`: preload the same durable receiver state, retaining
   its acknowledged local edits. Write and verify a second remote update
   outside timing, create another local backlog, then trigger foreground
   activation.

Use `--notes` to choose 2 to 1000 notes (default 100).

Remote updates use the production immutable snapshot schema and record ID.
The synthetic fixture writer reads the exact saved record back and verifies
asset bytes, heads, and metadata before activation timing starts. Receiver
operations use the ordinary transport. With `--publisher-app`, the Mac writes
these remote fixtures. Only the UUID source notebook and matching manifest are
copied to the Mac lab; receiver state and transport tokens stay on the
simulator. Foreground preload finishes first, then the Mac publishes and
provides a verified UUID handoff. Local edits and timing start after it. This
keeps sender and receiver on separate systems while reusing one simulator.
It does not demonstrate delivery from another device's CKSyncEngine. The
initial source seed still uses the engine. Omitting the publisher uses a
same-simulator fixture writer; treat any incomplete exchange as a failed
experiment rather than a timing result.

The optional `activation-readback` diagnostic checks an exact source record
through CKDatabase, then uses a fresh isolated receiver to compare text and
heads. Its timings and checks diagnose fixture persistence versus receiver
fetch behavior; they are separate from activation performance samples.

Before/after ordering alternates between trial pairs. Cold-start uses automatic
engine scheduling. The controlled foreground sample enables Workspace
scheduling but disables automatic engine scheduling, keeping the new remote
change from arriving before the trigger. This distinguishes lifecycle behavior
from a background push race. It is not an OS icon-launch or native screen test.

Reports include expected and observed fictional text and timing samples for
`activation_visible` and `activation_complete`. Results preserve raw samples
and medians separately for each phase and variant. Visibility means the
replica contains the expected note text; it does not measure painted pixels.
Completion requires the expected remote text and the activation refresh to
finish, including outgoing work. `activation_initial_start` separates initial
loading/exchange from `activation_foreground_dispatch`. Results do
not establish APNs delivery latency, genuine cross-device SDK delivery,
physical-device behavior, or guaranteed background sync. The cold-start
backlog contains local replica edits, not previously staged engine saves;
restored-outbox gating has unit coverage.
Incomplete runs remain explicitly marked incomplete.

Run the pure orchestration tests without launching an app:

```sh
python3 -m unittest discover -s Tools/CloudKit \
  -p test_activation_comparison.py
```

Keep prepared products and evidence until review is complete. The runner does
not clean cloud zones or app containers; all writes use task-owned UUID scopes.

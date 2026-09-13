# Automatic notebook synchronization

Cloud builds use CKSyncEngine automatic scheduling and its database change
subscription. The app registers for silent remote notifications and creates
its notebook workspace early during launch. It does not request permission
to show alerts. The signed iCloud Dev configuration includes APNs entitlements
and the iOS remote-notification background mode.

## Triggers and durability

- Startup, foreground activation, saved local changes, and Sync Now retain
  explicit finite exchanges. Saved changes are coalesced for 750 milliseconds.
- CloudKit commits fetched changes and background upload acknowledgements to
  the transport store before notifying the workspace through an async stream.
  The workspace then applies the inbox through the existing coordinator.
- Empty or duplicate downloads do not request another workspace exchange.
  The delegate never awaits an exchange that could reenter the sync engine.
- Leaving the foreground requests one final exchange of saved changes. On
  iOS, a bounded background execution allowance helps finish checkpointing;
  expiration releases that allowance and durable pending work remains.
- Network restoration requests a foreground retry. Transient app/setup errors
  back off from 5 seconds to a maximum of 5 minutes, never earlier than a known
  server cooldown. Successful exchanges reset the backoff. Identity and corrupt
  data errors remain visible instead of triggering automatic retry loops.
- Failed engine events update status without starting another exchange,
  avoiding feedback loops for errors that need intervention.
- App retry timers stop on leaving the foreground. CloudKit owns background
  transport scheduling; activation resumes app reconciliation and pending work.

The cloud foreground polling timer is removed. The explicit loopback HTTP
mode retains foreground polling because that test service has no push channel.
`MEH_SYNC_AUTOMATIC=0` keeps automatic engine activity and notification
registration disabled for deterministic manual/device test workflows.

The Local build's Debug environment override can still use CloudKit, but its
signing configuration does not include APNs. Use the iCloud Dev scheme for
push/background acceptance. Notification registration failures appear in Sync
Details and the event log; activation and Sync Now remain available.

## What this does not guarantee

Apple decides when background work and silent notifications can run. Delivery
can be delayed, and force-quitting an app must not be treated as a promise of
background synchronization. Local editing remains available when CloudKit is
unavailable. No cloud reset or single-note compatibility bridge is introduced.

Deterministic tests exercise durable state, retry decisions, activity delivery,
and the app scheduler. Physical Mac/iPhone/iPad checks remain necessary for
APNs registration and actual system scheduling. See the
[validation plan](notebook-sync-validation.md) for local and CI commands.

## Physical-device checkpoint

Use disposable notes in the iCloud Dev build on both devices, with automatic
sync enabled. Keep Sync Details and the event log available for diagnosis.

1. Create or edit a note on Mac while iPhone is active. Check that iPhone
   receives it without Sync Now, then repeat in the other direction.
2. Background the receiving app without force-quitting it, edit on the other
   device, and reopen it. Check that the final content converges and inspect
   whether the log recorded `cloud scheduled changes delivered` before or
   during activation. `cloud manual changes delivered` identifies an explicit
   fetch, including startup, activation, saved edits, and Sync Now; it is not
   evidence of notification-triggered delivery.
3. Edit while one device is offline, then restore connectivity. Check both
   devices retain their edits and the sync indicator eventually becomes idle.
4. Leave both copies unchanged and verify they do not repeatedly report new
   uploads. If they do, keep the sync event logs from both devices.

Passing these checks provides device evidence for the configured integration;
it does not establish a fixed background-delivery deadline.

## References

- [CKSyncEngine][engine]
- [Apple's sample](https://github.com/apple/sample-cloudkit-sync-engine)

[engine]: https://developer.apple.com/documentation/cloudkit/cksyncengine

# Automatic notebook synchronization

Cloud builds use CKSyncEngine automatic scheduling and its database change
subscription. The app registers for silent remote notifications and creates
its notebook workspace early during launch. It does not request permission
to show alerts. The development and production cloud configurations include
APNs entitlements and the iOS remote-notification background mode.

## Triggers and durability

- Local note saves retain their 1-second idle / 5-second maximum delay.
  Automatic exchanges wait until 10 seconds after the last local edit, with
  a 60-second maximum from the first pending request. Further edits or cloud
  events do not reset that maximum. With no recent typing, requests retain
  the short 750-millisecond coalescing delay.
- Saved changes, foreground activation, incoming cloud activity, connectivity
  restoration, and development polling share that automatic schedule.
  Startup and Sync Now bypass the typing delay. An exchange already running
  finishes normally; requests received meanwhile are combined into a follow-up.
- CloudKit commits fetched changes and background upload acknowledgements to
  the transport store before notifying the workspace through an async stream.
  The workspace then applies the inbox through the existing coordinator.
- Empty or duplicate downloads do not request another workspace exchange.
  The delegate never awaits an exchange that could reenter the sync engine.
- Leaving the foreground flushes open notes locally and requests one final
  exchange without the typing delay, subject to server retry deadlines. On
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
Development push/background acceptance and TestFlight for Production
acceptance. Notification registration failures appear in Sync Details and the
event log; activation and Sync Now remain available.

## What this does not guarantee

Apple decides when background work and silent notifications can run. Delivery
can be delayed. The 60-second cap bounds the app's typing-related delay;
server cooldowns, an active exchange, and background limits can take longer.
CloudKit may transfer already queued data independently of this app scheduler.
This changes when main-thread reconciliation starts; it does not move that
work off the main thread. Force-quitting an app must not be treated as a
promise of
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

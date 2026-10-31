# S3 sync (beta)

meh.md can sync notes through a storage bucket you control instead of
iCloud. This is for people who don't use iCloud, or want their notes on their
own server. It works with Amazon S3 and with S3-compatible storage such as
MinIO.

Notes merge exactly as they do with iCloud. Every note is an Automerge
document, and the bucket only stores snapshots of those documents, so edits
made on several devices at once still come together without conflicts.

## Choosing where notes sync

iCloud is the default and needs no setup. Settings › Sync lists iCloud and
Off, and adds S3 once it has been set up. S3 itself lives under Advanced ›
S3 Storage, so it doesn't get in the way.

To set up S3, enter the server address, region, bucket, an optional folder,
and an access key ID with its secret key. Test Connection checks that the
bucket can be read and written, and tells you what it found:

- an empty folder, where your notes will be uploaded,
- your notebook, which this device joins,
- or a different notebook. After switching, you choose what to do with it
  (see [another notebook](#when-the-storage-holds-another-notebook)).

Every switch makes a local backup first and applies right away, without
restarting the app. The first sync uploads everything the storage is
missing. Switching back resumes where that storage left off, because each
storage keeps its own sync progress on the device. Changing the S3 bucket or
folder starts that storage fresh. After a switch, Settings reminds you to
switch your other devices too; until then they keep syncing with the old
storage and don't see changes from this device.

Off keeps notes on this device only. The copy in the storage you left stays
as it is.

The access key ID and secret key are saved in the keychain of this device
only. The address is saved in the app's preferences. Reset All Local Data
removes both and returns to iCloud.

## When the storage holds another notebook

Each storage holds one notebook. A device that never synced simply joins
the notebook it finds. A device whose notebook already synced elsewhere
stops before changing anything and offers three choices:

- **Combine notebooks.** This device's notes are added to the stored
  notebook in a folder such as "From iCloud", with their edit history. Notes
  that are already in both, for example after a second device combines the
  same notebooks, merge instead of being added twice. If two devices combine
  at the same moment, each note still appears once, and one of the two
  folders may stay empty.
- **Use the notes in the storage.** This device shows the stored notebook
  instead of its own. Its own notes stay in the backup and in the storage it
  used before. A note that is in both, for example after an earlier
  combine, is the same note, so this device's edits to it are kept, while
  its deletions are not applied.
- **Go back** to the storage used before.

Replacing the stored notebook with this device's one is not offered, because
other devices could upload the old notebook again.

## Setting up a bucket

On AWS, create a general purpose bucket, ideally one used only for meh.md,
and an IAM user with an access key. Its policy allows only `s3:ListBucket`
on the bucket and `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on
the folder. IAM roles and other temporary credentials don't work yet,
because they need a session token that the app can't send. Use the regional
endpoint, for example `https://s3.eu-central-1.amazonaws.com`, and the same
region.

For MinIO, create a bucket and an access key with the same permissions. Use
any region, for example `us-east-1`, unless the server sets one. Plain `http`
is only accepted for addresses on the local network, and the app says that
such a connection is not encrypted.

To try it on a Mac:

```sh
brew install minio awscli
MINIO_ROOT_USER=mehadmin MINIO_ROOT_PASSWORD=mehadmin-secret \
  minio server ~/minio-data --address 127.0.0.1:9000 &
AWS_ACCESS_KEY_ID=mehadmin AWS_SECRET_ACCESS_KEY=mehadmin-secret \
  aws --endpoint-url http://127.0.0.1:9000 --region us-east-1 \
  s3 mb s3://meh-notes
```

A simulator reaches it at `http://127.0.0.1:9000`.

## Limitations

- **No instant updates.** iCloud tells the app about changes through push
  notifications. S3 can't, so the app checks the bucket about once a minute
  while it is open, and when it opens or you tap Sync Now. Changes don't
  arrive while the app is closed.
- **One notebook per folder.** A notebook that has already synced
  elsewhere never joins a folder that holds a different notebook on its
  own. You choose to combine them or to use the stored one (see
  [another notebook](#when-the-storage-holds-another-notebook)). A device
  that has never synced adopts whatever notebook it finds.
- **Conditional writes.** Setup relies on `If-None-Match: *` so that two
  devices setting up at the same moment agree on one notebook. AWS S3 and
  MinIO support it. Storage that doesn't, such as some older or simpler
  services, gets a warning: set up one device first, then add the others.
- **Consistent listings.** Each device keeps a numbered log of what it
  uploaded, and other devices read it in order. That needs storage whose
  listings show new objects right away, as AWS S3 and MinIO do. S3 Express
  One Zone directory buckets don't list objects in order and are not
  supported.
- **More requests.** Every sync lists the logs of all devices, and each
  snapshot is its own object. That's fine for personal notebooks, but
  costs grow with request counts on paid storage.
- **One storage at a time.** Devices sync with either iCloud or S3. Devices
  on different storages don't see each other's changes until they switch.
- **Notes are readable in the bucket.** They are stored without
  end-to-end encryption, so whoever runs the storage, or holds the access
  key, can read them.
- **Set up each device.** The access key stays in the keychain of the
  device it was entered on, so every device needs the settings once.
- **The logs keep growing.** Cleanup removes redundant note snapshots, but
  not the small log entries and deletion markers, so listing them slowly
  takes more requests. iCloud keeps deletion markers too; the logs are
  specific to S3, because CloudKit tracks changes on the server.
- **Restored devices.** A device restored from a backup continues under a
  new log name when the storage supports conditional writes. On storage
  that doesn't, the original and the restored copy can overwrite each
  other's log entries, and some changes may not reach other devices.

## What AWS adds

These AWS features help, without the app depending on them:

- **Versioning and lifecycle rules.** Turn on bucket versioning to recover
  from a mistaken deletion, and add a lifecycle rule that expires old
  versions after some days. meh.md deletes redundant snapshots as part of
  cleanup, so without a rule the old versions keep growing.
- **Least-privilege IAM.** A policy that only allows the actions above on one
  folder limits what a leaked key can reach. `s3:ListBucket` on the bucket
  still lets the key list names outside the folder, unless you add an
  `s3:prefix` condition. A bucket used only for meh.md avoids the question.
- **Encryption at rest.** S3 encrypts new objects by default. SSE-KMS gives
  you your own key and an audit trail; the IAM user then also needs
  `kms:GenerateDataKey` and `kms:Decrypt` on that key.
- **Conditional writes with `If-Match`.** S3 can also replace an object only
  if it hasn't changed. A later version could use that instead of per-device
  logs.
- **Event notifications.** S3 can report new objects to SNS, SQS, or
  EventBridge. Turning that into push notifications for the app would need a
  server, so meh.md doesn't use it.

Sources: [conditional writes][conditional],
[ListObjectsV2 ordering][list], [event notifications][events].

## How it is stored

Everything lives under `<folder>/meh-notebook/` in the bucket. See
`Sources/NoteCore/S3SyncTransport.swift` for the layout, and
[sync backends](sync-backends.md) for how a backend plugs into sync.

[conditional]: https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html
[list]: https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html
[events]: https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-how-to-event-types-and-destinations.html

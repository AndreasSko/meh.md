# Automatic Markdown backups

The notebook keeps its current readable copy at
`Documents/Notebook Copies/Markdown`. Settings describes where to find this
folder and `Documents/Backups` in Finder or Files. These are local app
documents, not a shared iCloud Drive folder. A backup stored only here may
disappear if the app is removed from an iPhone or iPad.

Automatic backups default to daily with the latest 14 kept. Settings also
offers Off, Weekly, Monthly, a retention count, and Back Up Now. Include
attachments is off by default. Turn it on to copy active files alongside
their notes, with the same folder structure. This setting applies to both
scheduled backups and Back Up Now. Each backup keeps its own copies, so
large attachments can use much more storage across the retained backups.

A newly enabled schedule runs when due. The app checks on launch and
activation, uses a timer while running, and requests opportunistic iOS
background time.
iOS decides when or whether to grant that time, so a missed backup catches up
when the app next runs. Markdown-only backups need no network or successful
CloudKit exchange. Backups with attachments also work offline when all active
files are downloaded. Missing files are requested from iCloud; an unavailable
or damaged file stops the backup and leaves earlier completed backups intact.

Each completed backup is a dated, browsable folder. It contains the active
Markdown note bodies and folder hierarchy, including empty folders. Trash is
excluded. Before taking a backup, the app flushes open note sessions and
reads locally persisted snapshots. Back Up Now also asks the visible editor
to flush its buffer. Any failed local save stops the backup. The writer
stages a complete tree, compares Markdown with the expected bytes, and verifies
attachment checksums and sizes using bounded, streamed reads. Only then does
it publish the folder. A failed or cancelled attempt leaves
earlier completed backups alone. Retention removes only completed backup
folders marked as belonging to the current notebook.

The current Markdown copy and backups are one-way output. Editing them in
Finder or Files does not change the notebook. The app does not promise
operating-system write protection for exposed files. Backups preserve
Markdown text, optional attachment files, and folder structure; they do not
preserve notebook metadata or Automerge history. The existing file import can
copy files back into the notebook if needed; there is no separate backup
restore workflow.

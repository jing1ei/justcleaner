# Maintenance contracts

- All destructive entry points take `DiskOperation`; configuration updates
  use their separate lock. Never acquire the disk lock inside a settings update.
- Quarantine intent is journaled before an exclusive same-volume rename.
  A completion marker permits automatic expiry only after successful cleanup.
- Undo restores listed entries, never overwrites destinations, and removes only
  empty scaffolding. Unknown files remain available for inspection.
- Deletion traverses pinned directory descriptors without following symlinks or
  mounted volumes, with content safeguards and owning-process checks. These cannot
  freeze a live tree or prove application data is expendable. Keep classification
  conservative and test filesystem races with disposable data.
- Serialized reads reject links and special files and enforce size limits; logs
  reject symlinks and hard links. Recovery metadata is validated before use.
- Settings changes patch the latest value under a cross-process lock; statistics
  updates must not write a stale configuration snapshot.
- Command output is capped at 4 MiB. Exit codes 124/125/126 indicate timeout,
  truncation, and capture failure. Timeout does not supervise all descendants.
- Do not claim file block totals equal uniquely reclaimable disk space. APFS
  clones, snapshots, open files, and hard links affect reclamation.
- Before broad distribution, exercise permission denial, full disks, abrupt
  termination around journal/move boundaries, separate volumes, login/logout,
  and minimum-supported macOS. The local suite does not replace that matrix.

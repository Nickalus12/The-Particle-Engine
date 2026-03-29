Local unpublished work backup

Local branch: main
Local HEAD: 8a854fca647aaa59302ab1e141d32a6da7d6f6ca
Backup branch: codex/backup-20260329-091221
Bundle: local_backups/particle-engine-head-20260329-091221.bundle
Patch set:
- local_backups/patches-20260329-091221/0001-Overhaul-mobile-simulation-and-expand-performance-te.patch
- local_backups/patches-20260329-091221/0002-Improve-mobile-sandbox-performance-and-gameplay-feed.patch

Remote main at time of backup: 58fdbccb71e232c71840e5aa3cb461fea962eed9
Reason for remote backup: local git network transport could not resolve GitHub, so patch exports were preserved through the GitHub connector.

Restore notes:
- Apply patches on top of a branch created from the intended base commit after fetching latest main.
- Review overlaps with the remote mobile paint interaction fix commit on main before merge.

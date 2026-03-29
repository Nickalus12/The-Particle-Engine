Local unpublished work backup

Status:
- Authoritative preserved copy exists locally and was verified.
- This GitHub branch is a remote preservation breadcrumb created through the GitHub connector while local git network access was failing.
- Large patch payloads may be truncated when uploaded through the connector, so do not treat this branch alone as the only backup source.

Authoritative local backup sources:
- Local branch: main
- Local HEAD: 8a854fca647aaa59302ab1e141d32a6da7d6f6ca
- Verified backup branch: codex/backup-20260329-091221
- Verified bundle: local_backups/particle-engine-head-20260329-091221.bundle
- Patch set:
  - local_backups/patches-20260329-091221/0001-Overhaul-mobile-simulation-and-expand-performance-te.patch
  - local_backups/patches-20260329-091221/0002-Improve-mobile-sandbox-performance-and-gameplay-feed.patch

Remote main at time of backup:
- 58fdbccb71e232c71840e5aa3cb461fea962eed9

Why merge was not completed here:
- Local git transport could not resolve GitHub from this environment, so fetch/rebase/push could not be completed safely.
- Remote main is ahead of the stale local tracking ref, so an automatic merge without a real fetch would be risky.

Recommended restore flow once git networking is healthy again:
1. fetch latest main
2. create a recovery branch from updated main
3. apply or cherry-pick the preserved local work
4. resolve overlaps with the remote mobile paint interaction fix commit
5. push and open/merge a PR

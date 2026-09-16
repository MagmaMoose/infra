# Session: 2026-09-16 — media-arr-pipeline

## What changed
- nzbhydra2 + overseerr: config restored from ff-vm1 into Longhorn PVCs (both ran empty since 2026-06-26)
- recyclarr: config-templates pinned to the last v7-layout commit (failing since 2026-08-07)
- plex: memory limit 3Gi (nightly thumbnail task OOM loop)
- streaming-sync: Slack summary lists titles; unmonitor before deleting files
- Live, not in git: qBittorrent `dont_count_slow_torrents=true`, 5 active downloads; dead torrents blocklisted; 106 dead SABnzbd history entries deleted; Sonarr's dead Jackett indexer removed

## Decisions made
- Cloud-tier app state goes on Longhorn, never hostPath (COMMON_MISTAKES #38)
- Pin recyclarr templates rather than migrate to v8 now

## Files touched
- kubernetes/apps/{nzbhydra2,overseerr,recyclarr,plex,streaming-sync}/base/

## Follow-up / next steps
- Resume `prod-nzbhydra2` and `prod-overseerr` (suspended) once PR #737 merges
- Overseerr's Plex tokens are expired: sign in once with Plex, then pick libraries
- Prowlarr still uses hostPath on the cloud tier
- 1337x is Cloudflare-blocked (403) from the VPN exit

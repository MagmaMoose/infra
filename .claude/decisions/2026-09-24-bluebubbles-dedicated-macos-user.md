# BlueBubbles runs under its own Standard macOS user

Status: **accepted**
Date: 2026-09-24

## Context

Hermes gets iMessage through BlueBubbles Server on the Mac mini. BlueBubbles reads the running
user's `chat.db` with Full Disk Access and serves it over a password-protected REST API. That
covers every conversation and attachment, plus Contacts and Find My routes for devices and
friends. Hermes holds the password, and Hermes runs tools.

Until now, the Mac mini's only login belonged to a person. It held their full message history,
their iCloud account and their family's Find My.

## Options considered

**A. The person's login, with Messages switched to a bot Apple Account.** Rejected. The history
already in `chat.db` stays readable through the API, and so do Contacts and Find My. It would
also sign the person's own iMessage off the Mac.

**B. The person's login and Apple Account.** Rejected. Hermes could read everything, and it
would answer anyone who texts the person, or send them pairing codes.

**C. A dedicated Standard user, `nievah`, with its own Apple Account in Messages only.** Chosen.

## Decision

C. BlueBubbles and Messages run in the `nievah` login, which stays logged in through fast user
switching. `configure-user.sh` refuses to run for an admin user, and `install.sh` refuses to
stage the password for one.

## Consequences

- After a reboot, someone logs `nievah` in by hand. FileVault rules out auto-login, and the
  person's own login has to come first anyway.
- A second login session runs permanently. BlueBubbles #750 reports this exact setup working
  with Hermes. The one caveat there, an open Messages window holding webhooks back, is what the
  keep-alive agent handles.
- Full Disk Access and Accessibility are granted per app, system-wide. Never start BlueBubbles
  from a person's login.

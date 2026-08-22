# Auto-Update System

## Overview

This repository includes a centralized auto-update system that automatically updates servers and sends intelligent Slack notifications via GitHub Actions.

### ✨ Features

- 🎯 **One-liner installation** on any Linux server
- 🚨 **Intelligent channel routing**: 
  - Failed updates → `#engineering-alerts` 
  - Reboot required → `#engineering-warnings`
  - Success/Skipped → `#engineering-info`
- 🏗️ **Centralized GitHub Actions** workflow for all notifications
- 🔒 **Secure**: No Slack tokens stored on servers, only GitHub tokens
- 📊 **Rich notifications** with server details, uptime, and error information
- ⚡ **Smart load checking** (skips updates during high system load)
- 🛡️ **Systemd security hardening** with restricted permissions
- 📅 **Configurable scheduling** with randomized delays

### 🚀 Setup for New Servers

#### Step 1: Install Auto-Update System

Run this one-liner on your server:

```bash
# Basic installation
curl -sSL https://raw.githubusercontent.com/calebsargeant/reusable-workflows/main/install-auto-update.sh | sudo bash -s -- \
  --github-repo calebsargeant/infra

# Custom configuration
curl -sSL https://raw.githubusercontent.com/calebsargeant/reusable-workflows/main/install-auto-update.sh | sudo bash -s -- \
  --github-repo calebsargeant/infra \
  --server-name my-production-server \
  --schedule-time "02:30:00" \
  --randomized-delay 1800
```

#### Step 2: Configure GitHub Token (Required)

**🔑 Why is a GitHub token needed?**

The GitHub token allows servers to send notifications by:
- 🚀 Triggering GitHub Actions workflows via repository dispatch events
- 🔐 Authenticating with GitHub API to access your `calebsargeant/infra` repository
- 📡 Sending update status that gets routed to appropriate Slack channels

**Security Benefits:**
- ✅ No Slack tokens stored on servers (only in GitHub repository secrets)
- ✅ Centralized notification logic in GitHub Actions  
- ✅ Limited scope: only needs `repo` access

**Create a GitHub Personal Access Token:**

1. Go to **[GitHub Settings → Personal Access Tokens](https://github.com/settings/tokens)**
2. Click **"Generate new token (classic)"**
3. Set **Token name**: `Auto-Update System`
4. Set **Expiration**: `No expiration` (or your preferred timeframe)
5. Select **Scopes**: ✅ `repo` (Full control of private repositories)
6. Click **"Generate token"** 
7. **Copy the token immediately** (you won't see it again!)

**Add token to server configuration:**

```bash
sudo nano /etc/default/auto-update
```

Uncomment and set your GitHub token:
```bash
# GitHub Personal Access Token for repository dispatch
GITHUB_TOKEN="ghp_your_personal_access_token_here"
```

**⚠️ Important:** The same GitHub token can be used on multiple servers. Store it securely and never commit it to version control.

#### Step 3: Verify Installation

```bash
# Check timer status
sudo systemctl status auto-update-slack.timer

# View next run time
sudo systemctl list-timers auto-update-slack.timer

# Test manually
sudo systemctl start auto-update-slack.service

# View logs
sudo journalctl -u auto-update-slack.service -f
sudo tail -f /var/log/auto-update.log
```

### 🎛️ Configuration Options

| Option | Description | Default |
|--------|-------------|----------|
| `--github-repo` | GitHub repository for notifications | Required |
| `--server-name` | Server name shown in notifications | `$(hostname)` |
| `--schedule-time` | Update time (HH:MM:SS format) | `03:00:00` |
| `--randomized-delay` | Random delay in seconds | `3600` (1 hour) |
| `--github-token` | GitHub Personal Access Token | Set in config later |

### 📋 Required GitHub Repository Secrets

Ensure these secrets are configured in the GitHub repository:

| Secret Name | Description | Example |
|-------------|-------------|----------|
| `SLACK_BOT_TOKEN` | Slack bot token | `xoxb-...` |
| `SLACK_ENGINEERING_ALERTS_CHANNEL` | Channel for failed updates | `C09HS6M5CS3` |
| `SLACK_ENGINEERING_WARNINGS_CHANNEL` | Channel for reboot notifications | `C09J7KHQL4S` |
| `SLACK_ENGINEERING_INFO_CHANNEL` | Channel for success notifications | `C09J7K8L9J6` |

### 🔧 Advanced Configuration

#### Modify Update Schedule
```bash
# Edit the systemd timer
sudo systemctl edit auto-update-slack.timer

# Add override:
[Timer]
OnCalendar=*-*-* 01:00:00
RandomizedDelaySec=1800
```

#### Custom Notification Repository
To use a different repository for notifications:
```bash
# Edit configuration
sudo nano /etc/default/auto-update

# Change:
GITHUB_REPO="your-org/your-repo"
```

### 🏢 How It Works - Complete Architecture

```text
💻 Server (Proxmox/Ubuntu/etc)
     │
     │ GitHub Token (ghp_...)
     ↓ 
🌐 GitHub API
     │ POST /repos/calebsargeant/infra/dispatches
     │ {
     │   "event_type": "server-update",
     │   "client_payload": {
     │     "server_name": "proxmox",
     │     "status": "success|failed|reboot_required", 
     │     "message": "Updates completed",
     │     "uptime": "up 15 days"
     │   }
     │ }
     ↓
🏗️ GitHub Actions Workflow
     │ .github/workflows/server-update-notifications.yml
     │ 
     │ Channel Routing Logic:
     ├── if status == "failed" → ALERTS_CHANNEL
     ├── if status == "reboot_required" → WARNINGS_CHANNEL
     └── if status == "success|skipped" → INFO_CHANNEL
     ↓
🗨️ Slack API
     │ Using SLACK_BOT_TOKEN (stored in repo secrets)
     ↓
📱 Slack Channels
     ├── 🚨 #engineering-alerts (failures)
     ├── ⚠️ #engineering-warnings (reboots)
     └── ✅ #engineering-info (success)
```

**Key Points:**
- 🔒 **Servers only need**: GitHub token (no Slack credentials)
- 🏗️ **GitHub Actions handles**: All Slack integration and channel routing
- 🔐 **Slack credentials**: Stored securely as GitHub repository secrets
- 📡 **Notifications**: Automatically routed to appropriate channels based on update status

### 🔍 Monitoring

#### Check System Status
```bash
# View timer status
systemctl status auto-update-slack.timer

# List all timers
systemctl list-timers

# View service logs
journalctl -u auto-update-slack.service --since "24 hours ago"

# Monitor live updates
tail -f /var/log/auto-update.log
```

#### Troubleshooting

**No notifications received:**
1. Check GitHub token permissions (`repo` scope required)
2. Verify repository secrets are set correctly
3. Ensure Slack bot is added to all notification channels
4. Check service logs: `journalctl -u auto-update-slack.service`

**Updates failing:**
1. Check system logs: `/var/log/auto-update.log`
2. Verify internet connectivity
3. Check package manager functionality
4. Review disk space and system resources

### 🛡️ Security Features

- **No Slack tokens on servers**: Only GitHub tokens are stored locally
- **Systemd hardening**: Service runs with restricted permissions
- **Encrypted secrets**: GitHub repository secrets are encrypted at rest
- **Limited scope**: GitHub tokens only need `repo` access
- **Audit trail**: All notifications tracked through GitHub Actions

### 🏗️ Architecture Overview

```text
Server (Proxmox/Ubuntu/etc)
    ↓ (GitHub API)
    ↓ Repository Dispatch Event
    ↓
GitHub Actions Workflow
    ↓ (Channel Routing)
    ↓
Slack Notifications
    ├── 🚨 #engineering-alerts (failures)
    ├── ⚠️ #engineering-warnings (reboots)
    └── ✅ #engineering-info (success)
```

This architecture centralizes notification logic in GitHub Actions while keeping servers simple and secure.

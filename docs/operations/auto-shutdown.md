# Auto-Shutdown for macOS

This script sets up automatic shutdown after 30 minutes of system inactivity on macOS.

## Quick Setup

1. Download the setup script from the repository:
   ```bash
   curl -O https://raw.githubusercontent.com/CalebSargeant/infra/main/scripts/setup-auto-shutdown.sh
   chmod +x setup-auto-shutdown.sh
   ```

2. Run the installation:
   ```bash
   ./setup-auto-shutdown.sh install
   ```

That's it! Your Mac will now automatically shut down after 30 minutes of inactivity.

## Features

- **Smart Detection**: Monitors actual user interaction (mouse/keyboard) using macOS IOHIDSystem
- **Force Shutdown**: **WILL** shut down after 30 minutes regardless of running applications
- **Caffeinate Integration**: Use `caffeinate -d` to prevent shutdown when needed
- **User Notifications**: Shows a notification 5 seconds before shutdown
- **Automatic Startup**: Runs automatically when you log in
- **Comprehensive Logging**: All activity is logged for troubleshooting

## Usage

### Installation
```bash
./setup-auto-shutdown.sh install
```
- Installs and starts the auto-shutdown service
- Sets up all necessary permissions
- Configures automatic startup

### Check Status
```bash
./setup-auto-shutdown.sh status
```
- Shows current system status
- Displays recent log entries
- Shows current idle time

### Uninstall
```bash
./setup-auto-shutdown.sh uninstall
```
- Completely removes the auto-shutdown system
- Cleans up all files and permissions

## How It Works

1. **Monitoring**: The script runs in the background and checks system idle time every 60 seconds
2. **Idle Detection**: Uses `ioreg -c IOHIDSystem` to get precise idle time from hardware
3. **Force Shutdown**: After 30 minutes, it **WILL** shut down regardless of running applications
4. **Prevention**: Use `caffeinate -d` command to prevent shutdown when needed
5. **Graceful Warning**: Shows notification, waits 5 seconds, then initiates **force** shutdown

## File Locations

- **Monitoring Script**: `~/Library/Scripts/auto-shutdown-idle.sh`
- **Launch Agent**: `~/Library/LaunchAgents/com.sargeant.auto-shutdown-idle.plist`
- **Logs**: `~/Library/Logs/auto-shutdown-idle.log`
- **Sudo Config**: `/etc/sudoers.d/auto-shutdown-idle`

## Configuration

To change the idle timeout, edit the `IDLE_THRESHOLD` variable in the monitoring script:

```bash
# Edit the script
nano ~/Library/Scripts/auto-shutdown-idle.sh

# Change this line (value in seconds):
IDLE_THRESHOLD=1800  # 30 minutes

# Restart the service
./setup-auto-shutdown.sh uninstall
./setup-auto-shutdown.sh install
```

Common timeout values:
- 15 minutes: `900`
- 30 minutes: `1800` (default)
- 1 hour: `3600`
- 2 hours: `7200`

## Preventing Shutdown with Caffeinate

Since this system will **force shutdown** regardless of running applications, use `caffeinate` when you need to prevent shutdown:

```bash
# Prevent display sleep (keeps system awake)
caffeinate -d

# Prevent system sleep entirely
caffeinate -s

# Run a long command and prevent sleep during execution
caffeinate -s ./my-long-running-script.sh

# Prevent sleep for specific duration (in seconds)
caffeinate -t 3600  # Keep awake for 1 hour
```

**Important**: The auto-shutdown will **ignore** running applications, SSH sessions, and downloads. Only `caffeinate` can prevent the forced shutdown.

## Troubleshooting

### Service Not Running
```bash
# Check status
./setup-auto-shutdown.sh status

# If service is stopped, reinstall
./setup-auto-shutdown.sh install
```

### Check Logs
```bash
# View recent log entries
tail -20 ~/Library/Logs/auto-shutdown-idle.log

# Monitor live logs
tail -f ~/Library/Logs/auto-shutdown-idle.log
```

### Test Shutdown Prevention
The system won't shut down if:
- You have SSH sessions: `ps aux | grep ssh`
- Screen sharing is active: `ps aux | grep "Screen Sharing"`
- System assertions prevent sleep: `pmset -g assertions`

### Manual Service Control
```bash
# Stop service
launchctl unload ~/Library/LaunchAgents/com.sargeant.auto-shutdown-idle.plist

# Start service
launchctl load ~/Library/LaunchAgents/com.sargeant.auto-shutdown-idle.plist

# Check if running
launchctl list | grep auto-shutdown
```

## Security Notes

- The script requires sudo permission to run `/sbin/shutdown`
- Sudo is configured for passwordless shutdown only (secure and limited)
- All components run as your user account (not as root)
- The service is isolated and uses low system priority

## Requirements

- macOS (tested on macOS 10.15+)
- Administrative privileges (for sudo configuration)
- Terminal access

## Uninstalling

To completely remove the auto-shutdown system:

```bash
./setup-auto-shutdown.sh uninstall
```

This removes:
- The monitoring script
- LaunchAgent configuration
- Sudo permissions
- All log files (optional)

## Distribution

This script is self-contained and can be copied to any Mac. Simply:

1. Copy `setup-auto-shutdown.sh` to the target Mac
2. Run `./setup-auto-shutdown.sh install`
3. The system will be configured automatically

Perfect for deployment across multiple Macs in an organization.
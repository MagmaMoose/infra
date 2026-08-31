<#
.SYNOPSIS
    Keep retrying the cloudworkers `server` leaf until ff-oci3 and ff-oci4 are both
    RUNNING, then exit 0.

.DESCRIPTION
    The PowerShell twin of cloudworkers-await-a1.sh, for running from a Windows shell
    without Git Bash. Same behaviour, same guarantees, no bash or python dependency.

    WHY THIS EXISTS. OCI will not hand a new tenancy A1.Flex capacity in eu-amsterdam-1
    on demand. `terragrunt apply` returns `500-InternalError, Out of host capacity` and
    there is nothing to fix: the quota is free (41 cores available, 0 used), Oracle
    simply has no ARM host to place the instance on. The only known remedy is to keep
    asking, which is a job for a machine that stays on rather than for a session.

    Everything else in the stack (VCN, CHRs, IPSec) is already applied. This leaf is
    idempotent and only the two instances are missing, so re-running is safe.

    DO NOT run two of these at once, and do not run one while applying that leaf by
    hand. They share one GCS state file; concurrent applies fight over the lock and the
    loser dies mid-apply.

    Credentials are pulled from 1Password at run time into a temp directory locked to
    the current user and deleted on exit. Nothing is written to the repo.

.PARAMETER IntervalSeconds
    Seconds between attempts. Default 60. A minute is about as tight as this is worth
    running: each attempt is a real signed API call and a terragrunt plan+apply cycle,
    and OCI capacity does not free up faster than that.

.PARAMETER MaxAttempts
    Give up after this many attempts. 0 (the default) means keep going forever.

.EXAMPLE
    .\scripts\cloudworkers-await-a1.ps1
    Retry every minute until both nodes are up.

.EXAMPLE
    .\scripts\cloudworkers-await-a1.ps1 -IntervalSeconds 120 -MaxAttempts 50

.NOTES
    Requires: op (authenticated), oci, terragrunt, tofu, and working GCP
    application-default credentials for the Terraform state backend.
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 60,
    [int]$MaxAttempts = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Identifiers, not secrets. These OCIDs and the fingerprint are already committed
# elsewhere in this repo; only the private key is sensitive, and it is fetched at run
# time rather than stored.
$Tenancy     = 'ocid1.tenancy.oc1..aaaaaaaaataglyil3djobabznvcsqpqszsafgkeujqb55rf3aiugh5dj2lva'
$UserOcid    = 'ocid1.user.oc1..aaaaaaaaihbmjqxijzogpbsvdblgsa4727ozrmkcyfxobom2ktp3pbtrmpoa'
$Fingerprint = '71:5f:58:10:bf:fb:3c:2a:58:04:fb:24:e7:5b:ff:38'
$OpItem      = 'op://Magma Moose/6kbpuhvcmj6bmmujjifwtmlg4q'
$AvailDomain = 'TTzG:eu-amsterdam-1-AD-1'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Leaf     = Join-Path $RepoRoot 'terraform\oci\cloudworkers\prod\eu-amsterdam-1\server'

if (-not (Test-Path $Leaf)) {
    throw "server leaf not found at $Leaf - is this checkout on the branch that has it?"
}

foreach ($bin in 'op', 'oci', 'terragrunt', 'tofu') {
    if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
        throw "$bin is required but not on PATH"
    }
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("cw-a1-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null

try {
    # Lock the temp dir to the current user. Inheritance is disabled first, otherwise the
    # parent's ACEs survive and the restriction is decorative.
    $acl = Get-Acl $Work
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -Path $Work -AclObject $acl

    Write-Host 'fetching the API signing key from 1Password...'
    $rawKey = & op read "$OpItem/private key"
    if ($LASTEXITCODE -ne 0) { throw 'op read failed - is the 1Password CLI authenticated?' }

    # The 1Password copy is FLATTENED: its PEM newlines are spaces. Handed over as-is the
    # OCI SDK fails with "PEM data was not found in buffer", which reads like an auth
    # error and is not. Rebuild canonically: strip the markers, drop all whitespace,
    # re-wrap the base64 at 64 columns.
    $joined = ($rawKey -join "`n")
    $m = [regex]::Match($joined, '-----BEGIN ([A-Z ]+)-----(.*?)-----END \1-----', 'Singleline')
    if (-not $m.Success) { throw 'no PEM markers found in the 1Password field' }
    $label = $m.Groups[1].Value
    $body  = [regex]::Replace($m.Groups[2].Value, '\s+', '')
    $lines = for ($i = 0; $i -lt $body.Length; $i += 64) {
        $body.Substring($i, [Math]::Min(64, $body.Length - $i))
    }
    $pem = "-----BEGIN $label-----`n" + ($lines -join "`n") + "`n-----END $label-----`n"

    $KeyFile = Join-Path $Work 'key.pem'
    # WriteAllText, not Set-Content: the latter appends a trailing newline and can rewrite
    # line endings, and the OCI SDK is particular about the PEM it is handed.
    [System.IO.File]::WriteAllText($KeyFile, $pem)

    $CliConfig = Join-Path $Work 'oci_config'
    [System.IO.File]::WriteAllText($CliConfig, @"
[DEFAULT]
user=$UserOcid
fingerprint=$Fingerprint
tenancy=$Tenancy
region=eu-amsterdam-1
key_file=$($KeyFile -replace '\\', '/')
"@)

    # FORWARD SLASHES, AND THIS IS NOT COSMETIC. terraform/root.hcl interpolates this
    # path straight into the generated provider.tf as a double-quoted HCL string, where
    # a Windows path's backslashes are read as escape sequences: `C:\Users\...` fails the
    # whole plan with "Invalid escape sequence" on `\U`. HCL accepts forward slashes on
    # Windows, and so do the OCI CLI and SDK, so normalising here is the fix rather than
    # escaping at the far end.
    $KeyFilePosix = $KeyFile -replace '\\', '/'

    $env:OCI_CW_TENANCY_OCID     = $Tenancy
    $env:OCI_CW_COMPARTMENT_OCID = $Tenancy   # this tenancy has no child compartments
    $env:OCI_CW_USER_OCID        = $UserOcid
    $env:OCI_CW_FINGERPRINT      = $Fingerprint
    $env:OCI_CW_PRIVATE_KEY_PATH = $KeyFilePosix
    $env:TG_TF_PATH              = 'tofu'
    $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = 'True'
    $env:SUPPRESS_LABEL_WARNING  = 'True'

    # Ask OCI whether both nodes are up, rather than inferring it from terraform's exit
    # code. "apply succeeded" and "the VMs are running" are not the same claim.
    function Test-BothRunning {
        $prev = $env:OCI_CLI_CONFIG_FILE
        $env:OCI_CLI_CONFIG_FILE = $CliConfig
        try {
            $json = & oci compute instance list --compartment-id $Tenancy --all 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $json) { return $false }
            $data = ($json | ConvertFrom-Json).data
            if (-not $data) { return $false }
            $up = @($data | Where-Object {
                $_.'display-name' -in @('ff-oci3', 'ff-oci4') -and $_.'lifecycle-state' -eq 'RUNNING'
            })
            return $up.Count -eq 2
        } catch {
            # A malformed or empty response means "not yet", never a crash that ends the
            # loop while capacity might still appear.
            return $false
        } finally {
            $env:OCI_CLI_CONFIG_FILE = $prev
        }
    }

    if (Test-BothRunning) {
        Write-Host 'ff-oci3 and ff-oci4 are already RUNNING. Nothing to do.'
        exit 0
    }

    Write-Host ''
    Write-Host '=== cloudworkers A1 wait ===' -ForegroundColor Cyan
    Write-Host "  target      : ff-oci3 + ff-oci4 (VM.Standard.A1.Flex, 2 OCPU / 12 GB each)"
    Write-Host "  placement   : $AvailDomain, one per fault domain"
    Write-Host "  leaf        : $Leaf"
    Write-Host "  interval    : ${IntervalSeconds}s$(if ($MaxAttempts -gt 0) { ", max $MaxAttempts attempts" } else { ', no limit' })"
    Write-Host "  started     : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host '  Ctrl-C to stop. The key is wiped on exit.'
    Write-Host ''

    $attempt = 0
    $started = Get-Date
    $logFile = Join-Path $Work 'apply.log'

    while ($true) {
        $attempt++
        Push-Location $Leaf
        try {
            # 2>&1 merges the provider's stderr in, which is where both the capacity error
            # and the plugin crash surface.
            & terragrunt apply -input=false -auto-approve *>&1 | Out-File -FilePath $logFile -Encoding utf8
            $rc = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $log = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { '' }
        $stamp = (Get-Date).ToString('HH:mm:ss')

        # How long this has been going, so the terminal answers "should I give up on OCI
        # and pick another region" without anyone doing arithmetic. Computed BEFORE the
        # success check because the success message uses it too, and under StrictMode an
        # undefined $forStr would throw at the exact moment the VMs finally came up.
        $elapsed = (Get-Date) - $started
        $forStr = if ($elapsed.TotalHours -ge 1) { '{0:0}h{1:00}m' -f [int]$elapsed.TotalHours, $elapsed.Minutes }
                  else { '{0:0}m{1:00}s' -f [int]$elapsed.TotalMinutes, $elapsed.Seconds }
        $nextAt = (Get-Date).AddSeconds($IntervalSeconds).ToString('HH:mm:ss')

        if ($rc -eq 0 -and (Test-BothRunning)) {
            Write-Host ("$stamp attempt {0}: SUCCESS after {1}. ff-oci3 and ff-oci4 are RUNNING." -f $attempt, $forStr) -ForegroundColor Green
            Write-Host ''
            Write-Host 'Next, on the cluster (the kubelet may not self-set kubernetes.io labels,'
            Write-Host 'so the worker role label has to be applied by hand):'
            Write-Host '  kubectl label node ff-oci3 node-role.kubernetes.io/worker="" --overwrite'
            Write-Host '  kubectl label node ff-oci4 node-role.kubernetes.io/worker="" --overwrite'
            Write-Host ''
            Write-Host 'They will not join until the FortiGate tunnels are up, so expect NotReady'
            Write-Host 'until then. k3s-agent retries on its own; nothing to restart.'
            exit 0
        }

        if ($log -match 'Out of host capacity') {
            Write-Host ("$stamp attempt {0,-4} no A1 capacity  |  waiting {1}  |  next {2}" -f $attempt, $forStr, $nextAt)
            # Every tenth attempt, confirm the quota is still the thing that is NOT the
            # problem. If this ever drops it stops being a capacity wait and becomes a
            # limit problem, which needs a service request rather than patience.
            if ($attempt % 10 -eq 0) {
                $prev = $env:OCI_CLI_CONFIG_FILE
                $env:OCI_CLI_CONFIG_FILE = $CliConfig
                try {
                    $q = & oci limits resource-availability get --compartment-id $Tenancy `
                            --service-name compute --limit-name standard-a1-core-count `
                            --availability-domain $AvailDomain 2>$null | ConvertFrom-Json
                    Write-Host ("           quota check: {0} A1 cores available, {1} used (quota is not the blocker; host capacity is)" -f `
                        $q.data.available, $q.data.used) -ForegroundColor DarkGray
                } catch {
                    Write-Host '           quota check: could not read the limits API this round' -ForegroundColor DarkGray
                } finally { $env:OCI_CLI_CONFIG_FILE = $prev }
            }
        } elseif ($log -match 'Plugin did not respond|plugin process exited') {
            # Seen intermittently on Windows under memory pressure: the 250 MB oracle/oci
            # provider fails to load its schema. Transient and unrelated to capacity.
            Write-Host ("$stamp attempt {0,-4} provider plugin crashed (transient, not capacity)  |  waiting {1}  |  next {2}" -f $attempt, $forStr, $nextAt) -ForegroundColor DarkYellow
        } elseif ($rc -eq 0) {
            Write-Host ("$stamp attempt {0,-4} apply OK but both nodes not RUNNING yet  |  waiting {1}  |  next {2}" -f $attempt, $forStr, $nextAt) -ForegroundColor DarkYellow
        } else {
            # Anything else is a real problem and repeating it will not help.
            Write-Host "attempt ${attempt}: FAILED for a reason that is not capacity. Stopping." -ForegroundColor Red
            Write-Host ''
            ($log -split "`n" | Select-String -Pattern 'Error:' | Select-Object -First 10) | ForEach-Object {
                Write-Host ("  " + ($_.ToString().Trim() -replace '^\s*\|?\s*', ''))
            }
            $keep = Join-Path ([System.IO.Path]::GetTempPath()) 'cloudworkers-a1-failure.log'
            Copy-Item $logFile $keep -Force -ErrorAction SilentlyContinue
            Write-Host ''
            Write-Host "Full log copied to: $keep"
            exit 1
        }

        if ($MaxAttempts -gt 0 -and $attempt -ge $MaxAttempts) {
            Write-Host "gave up after ${attempt} attempts; still no A1 capacity." -ForegroundColor Yellow
            exit 2
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    # Runs on Ctrl-C too, so the private key does not outlive the script.
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

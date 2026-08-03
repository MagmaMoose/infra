# KRR - Kubernetes Resource Recommender

Prometheus-based resource recommendations for CPU and memory requests/limits.

## Overview

KRR analyzes your Prometheus metrics to provide data-driven recommendations for resource requests and limits, helping reduce costs and improve performance.

**Advantages over Goldilocks:**
- Uses existing Prometheus data (no VPA objects needed)
- Immediate results without waiting for data collection
- Better explainability with graphs and detailed analysis
- Multiple output formats (table, JSON, CSV, Slack)
- Can be run locally or in-cluster

## Architecture

This deployment runs KRR as a **CronJob** that:
- Executes every Monday at 9 AM
- Scans all namespaces
- Queries your Prometheus instance
- Outputs recommendations to the job logs

## Configuration

### Prometheus URL
The CronJob is configured to use:
```
http://prometheus-prometheus.observability.svc.cluster.local:9090
```

If your Prometheus service has a different name, update the `--prometheus-url` argument in `cronjob.yaml`.

### Schedule
Current schedule: `0 9 * * 1` (Mondays at 9 AM)

Modify the `schedule` field in the CronJob spec to change this.

### Slack Notifications (Optional)

To enable Slack notifications:

1. Create a Slack webhook URL
2. Create a secret:
   ```bash
   kubectl create secret generic krr-secrets \
     --from-literal=slack-webhook-url=YOUR_WEBHOOK_URL \
     -n observability
   ```
3. Uncomment the Slack-related lines in `cronjob.yaml`

## Usage

### View Recommendations

Check the logs of the most recent KRR job:
```bash
kubectl logs -n observability -l app=krr --tail=100
```

### Run Manually

Trigger a manual run:
```bash
kubectl create job -n observability krr-manual-$(date +%s) --from=cronjob/krr
```

### Run Locally (CLI)

Install KRR locally for interactive use:
```bash
# Using Homebrew
brew install robusta-dev/homebrew-krr/krr

# Run against your cluster
krr simple --prometheus-url=http://localhost:9090
```

Remember to port-forward Prometheus if running locally:
```bash
kubectl port-forward -n observability svc/prometheus-prometheus 9090:9090
```

## Output Formats

KRR supports multiple output formats. Update the `--format` argument:
- `table` - Human-readable table (default)
- `json` - Machine-readable JSON
- `csv` - CSV for spreadsheets
- `slack` - Formatted Slack message

## Advanced Options

Add these arguments to the CronJob spec as needed:

- `--cpu-min-value=0.01` - Minimum CPU recommendation
- `--memory-min-value=100Mi` - Minimum memory recommendation  
- `--history-duration=336h` - How far back to look (default: 2 weeks)
- `--prometheus-cluster-label=cluster` - Label to filter clusters

See the [KRR documentation](https://github.com/robusta-dev/krr) for more options.

## Removing Goldilocks

After validating KRR works for you, remove Goldilocks:
```bash
cd ../goldilocks
flux suspend helmrelease goldilocks -n observability
# Test for a while, then delete:
# rm -rf ../goldilocks
```

Also remove the `goldilocks.fairwinds.com/enabled=true` labels from namespaces.

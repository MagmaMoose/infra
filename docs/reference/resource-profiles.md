# Resource profiles

<!-- sources: kubernetes/apps, kubernetes/infrastructure -->

AWS-style size names for Kubernetes requests and limits. These are a naming convention that
workloads still refer to in comments, not a mechanism you can switch on. Read
[Status](#status) below before you use this page.

## Available Profiles
### P-type (Processing Intensive) - 2:1 CPU:Memory Ratio
**Best for:** Video transcoding, image processing, mathematical computations, ML inference

| Size   | CPU Request | Memory Request | CPU Limit | Memory Limit | Use Case |
|--------|-------------|----------------|-----------|--------------|----------|
| <span style="background-color: #e8f5e8; color: #2d5016; padding: 2px 6px; border-radius: 3px; font-weight: bold;">p.pico</span> | 100m | 64Mi | 250m | 128Mi | Tiny processing tasks |
| <span style="background-color: #fff3cd; color: #856404; padding: 2px 6px; border-radius: 3px; font-weight: bold;">p.nano</span> | 200m | 128Mi | 500m | 256Mi | Minimal processing |
| <span style="background-color: #d1ecf1; color: #0c5460; padding: 2px 6px; border-radius: 3px; font-weight: bold;">p.micro</span> | 300m | 192Mi | 1 core | 512Mi | Light computations |
| <span style="background-color: #d4edda; color: #155724; padding: 2px 6px; border-radius: 3px; font-weight: bold;">p.small</span> | 500m | 256Mi | 2 cores | 1Gi | Light media processing |
| <span style="background-color: #cce5ff; color: #004085; padding: 2px 6px; border-radius: 3px; font-weight: bold;">p.medium</span> | 1 core | 512Mi | 4 cores | 2Gi | Video processing |
| <span style="background-color: #e2d5f1; color: #5a2d82; padding: 2px 6px; border-radius: 3px; font-weight: bold;">p.large</span> | 2 cores | 1Gi | 8 cores | 4Gi | Heavy computational tasks |
| <span style="background-color: #ffd6cc; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">p.xlarge</span> | 4 cores | 2Gi | 16 cores | 8Gi | Batch processing |
| <span style="background-color: #f8d7da; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">p.2xlarge</span> | 8 cores | 4Gi | 32 cores | 16Gi | Large-scale processing |

### T-type (Burstable) - 1:1 CPU:Memory Ratio
**Best for:** Web servers, APIs, general-purpose applications

| Size   | CPU Request | Memory Request | CPU Limit | Memory Limit | Use Case |
|--------|-------------|----------------|-----------|--------------|----------|
| <span style="background-color: #e8f5e8; color: #2d5016; padding: 2px 6px; border-radius: 3px; font-weight: bold;">t.pico</span> | 25m | 32Mi | 100m | 128Mi | Tiny services |
| <span style="background-color: #fff3cd; color: #856404; padding: 2px 6px; border-radius: 3px; font-weight: bold;">t.nano</span> | 50m | 64Mi | 200m | 256Mi | Micro services |
| <span style="background-color: #d1ecf1; color: #0c5460; padding: 2px 6px; border-radius: 3px; font-weight: bold;">t.micro</span> | 100m | 128Mi | 500m | 512Mi | Small utilities |
| <span style="background-color: #d4edda; color: #155724; padding: 2px 6px; border-radius: 3px; font-weight: bold;">t.small</span> | 250m | 256Mi | 1 core | 1Gi | Web frontends |
| <span style="background-color: #cce5ff; color: #004085; padding: 2px 6px; border-radius: 3px; font-weight: bold;">t.medium</span> | 500m | 512Mi | 2 cores | 2Gi | API services |
| <span style="background-color: #e2d5f1; color: #5a2d82; padding: 2px 6px; border-radius: 3px; font-weight: bold;">t.large</span> | 1 core | 1Gi | 4 cores | 4Gi | Medium applications |
| <span style="background-color: #ffd6cc; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">t.xlarge</span> | 2 cores | 2Gi | 8 cores | 8Gi | Large applications |
| <span style="background-color: #f8d7da; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">t.2xlarge</span> | 4 cores | 4Gi | 16 cores | 16Gi | High-scale services |

### C-type (Compute Optimized) - 1:2 CPU:Memory Ratio
**Best for:** CPU-intensive applications, web servers with moderate memory needs

| Size   | CPU Request | Memory Request | CPU Limit | Memory Limit | Use Case |
|--------|-------------|----------------|-----------|--------------|----------|
| <span style="background-color: #e8f5e8; color: #2d5016; padding: 2px 6px; border-radius: 3px; font-weight: bold;">c.pico</span> | 100m | 256Mi | 250m | 512Mi | Tiny compute tasks |
| <span style="background-color: #fff3cd; color: #856404; padding: 2px 6px; border-radius: 3px; font-weight: bold;">c.nano</span> | 150m | 384Mi | 500m | 1Gi | Small compute jobs |
| <span style="background-color: #d1ecf1; color: #0c5460; padding: 2px 6px; border-radius: 3px; font-weight: bold;">c.micro</span> | 200m | 512Mi | 750m | 1.5Gi | Light compute workloads |
| <span style="background-color: #d4edda; color: #155724; padding: 2px 6px; border-radius: 3px; font-weight: bold;">c.small</span> | 250m | 512Mi | 1 core | 2Gi | Load balancers |
| <span style="background-color: #cce5ff; color: #004085; padding: 2px 6px; border-radius: 3px; font-weight: bold;">c.medium</span> | 500m | 1Gi | 2 cores | 4Gi | Application servers |
| <span style="background-color: #e2d5f1; color: #5a2d82; padding: 2px 6px; border-radius: 3px; font-weight: bold;">c.large</span> | 1 core | 2Gi | 4 cores | 8Gi | High-traffic APIs |
| <span style="background-color: #ffd6cc; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">c.xlarge</span> | 2 cores | 4Gi | 8 cores | 16Gi | Compute clusters |
| <span style="background-color: #f8d7da; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">c.2xlarge</span> | 4 cores | 8Gi | 16 cores | 32Gi | Heavy compute workloads |

### M-type (Memory Optimized) - 1:4 CPU:Memory Ratio
**Best for:** Applications with moderate memory requirements

| Size   | CPU Request | Memory Request | CPU Limit | Memory Limit | Use Case |
|--------|-------------|----------------|-----------|--------------|----------|
| <span style="background-color: #e8f5e8; color: #2d5016; padding: 2px 6px; border-radius: 3px; font-weight: bold;">m.pico</span> | 100m | 512Mi | 250m | 1Gi | Tiny memory apps |
| <span style="background-color: #fff3cd; color: #856404; padding: 2px 6px; border-radius: 3px; font-weight: bold;">m.nano</span> | 150m | 768Mi | 500m | 2Gi | Small memory workloads |
| <span style="background-color: #d1ecf1; color: #0c5460; padding: 2px 6px; border-radius: 3px; font-weight: bold;">m.micro</span> | 200m | 1Gi | 750m | 3Gi | Light memory apps |
| <span style="background-color: #d4edda; color: #155724; padding: 2px 6px; border-radius: 3px; font-weight: bold;">m.small</span> | 250m | 1Gi | 1 core | 4Gi | Small databases |
| <span style="background-color: #cce5ff; color: #004085; padding: 2px 6px; border-radius: 3px; font-weight: bold;">m.medium</span> | 500m | 2Gi | 2 cores | 8Gi | Application caches |
| <span style="background-color: #e2d5f1; color: #5a2d82; padding: 2px 6px; border-radius: 3px; font-weight: bold;">m.large</span> | 1 core | 4Gi | 4 cores | 16Gi | Medium databases |
| <span style="background-color: #ffd6cc; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">m.xlarge</span> | 2 cores | 8Gi | 8 cores | 32Gi | Large applications |
| <span style="background-color: #f8d7da; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">m.2xlarge</span> | 4 cores | 16Gi | 16 cores | 64Gi | High-memory applications |

### R-type (Memory Intensive) - 1:8 CPU:Memory Ratio
**Best for:** In-memory databases, caches, analytics, large datasets

| Size   | CPU Request | Memory Request | CPU Limit | Memory Limit | Use Case |
|--------|-------------|----------------|-----------|--------------|----------|
| <span style="background-color: #e8f5e8; color: #2d5016; padding: 2px 6px; border-radius: 3px; font-weight: bold;">r.pico</span> | 100m | 1Gi | 250m | 2Gi | Tiny cache instances |
| <span style="background-color: #fff3cd; color: #856404; padding: 2px 6px; border-radius: 3px; font-weight: bold;">r.nano</span> | 150m | 1.5Gi | 500m | 4Gi | Small memory stores |
| <span style="background-color: #d1ecf1; color: #0c5460; padding: 2px 6px; border-radius: 3px; font-weight: bold;">r.micro</span> | 200m | 2Gi | 750m | 6Gi | Light memory-intensive apps |
| <span style="background-color: #d4edda; color: #155724; padding: 2px 6px; border-radius: 3px; font-weight: bold;">r.small</span> | 250m | 2Gi | 1 core | 8Gi | Cache instances |
| <span style="background-color: #cce5ff; color: #004085; padding: 2px 6px; border-radius: 3px; font-weight: bold;">r.medium</span> | 500m | 4Gi | 2 cores | 16Gi | Search engines |
| <span style="background-color: #e2d5f1; color: #5a2d82; padding: 2px 6px; border-radius: 3px; font-weight: bold;">r.large</span> | 1 core | 8Gi | 4 cores | 32Gi | Large databases |
| <span style="background-color: #ffd6cc; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">r.xlarge</span> | 2 cores | 16Gi | 8 cores | 64Gi | Big data analytics |
| <span style="background-color: #f8d7da; color: #721c24; padding: 2px 6px; border-radius: 3px; font-weight: bold;">r.2xlarge</span> | 4 cores | 32Gi | 16 cores | 128Gi | Massive memory workloads |

## Status

!!! warning "The components that applied these profiles were deleted"
    `kubernetes/**/resource-profiles/` was removed on 2026-08-07 in
    [#569](https://github.com/CalebSargeant/infra/pull/569). There is no component to
    reference any more, and the `_components/` path this page used to name hasn't existed
    since the kustomize tree was restructured.

The size names survive as a **vocabulary**. Workloads now carry their requests and limits
inline, with a comment naming the profile the numbers came from:

```yaml
resources:
  requests:
    cpu: 150m
    memory: 768Mi
  limits:
    cpu: 500m
    memory: 2Gi   # m.nano
```

The tables above are the decoder ring for those comments. When you read `# c.pico` in a
manifest, this page tells you what the author meant.

## Copying a profile into a workload

!!! warning "Copy the limit, not just the request"
    A profile sets both. `m.nano` is 150m/768Mi requested and 500m/2Gi limited. Carrying the
    profile's *request* figure into the *limit* line is the easiest mistake to make here, and
    it produces a container that's OOMKilled on every start with no logs at all, because it
    dies before writing any. See
    [Troubleshooting](../operations/troubleshooting.md#a-container-is-oomkilled-and-there-are-no-logs).

Measure before you inline. A limit within about 10% of the real working set is a deferred
OOM, not a right-sizing:

```bash
kubectl exec <pod> -n <ns> -- cat /sys/fs/cgroup/memory.current
```

Requests are reserved by the scheduler; limits aren't. On a node that's already near capacity
you often can't raise the request, but raising the limit alone is free and is usually the
correct fix. Keep the request honest for scheduling and give the limit headroom for spikes.

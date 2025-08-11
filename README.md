# cgstats.sh

`cgstats.sh` is a lightweight POSIX-compatible shell script that shows **live CPU, memory, and disk usage** directly from Linux **cgroups v1/v2**.

It is designed to run **inside containers** (or any Linux system with `/sys/fs/cgroup` mounted) and gives you instant visibility into CPU, memory, and disk usage compared to configured limits.  
Unlike Kubernetes- or Prometheus-based monitoring, it requires **no agents, sidecars, or external services** — just drop it into a pod or container and run it.

The script has **zero dependencies** (pure `/bin/sh`) and outputs either **human-readable tables** (with colorized thresholds) or **machine-readable JSON** for easy integration into dashboards, editors, or CI pipelines.

> ⚠️ While the script includes support for both **cgroup v1 and v2**, it has been primarily developed and tested against **cgroup v2**.  
> cgroup v1 support should work, but is not thoroughly tested.

## Features

- Live updates at a configurable interval
- Reports CPU cores used vs limit, memory usage vs limit, and disk usage for arbitrary paths
- Configurable warning/critical thresholds with colorized output
- Flexible flags to disable CPU, memory, or disk reporting
- Output as **table (default)** or **JSON**
- No external dependencies, pure POSIX `sh`

## Install cgstats

```sh
curl -L https://raw.githubusercontent.com/DataLabHell/cgstats/main/cgstats.sh \
  -o /usr/local/bin/cgstats && chmod +x /usr/local/bin/cgstats
```

## Usage

```sh
./cgstats.sh [-i SECONDS] [-p PATHS]
             [--once]
             [--no-cpu] [--no-mem] [--no-disk]
             [--cpu-limit CORES] [--mem-limit MIB]
             [--cpu-warn PCT] [--cpu-crit PCT]
             [--mem-warn PCT] [--mem-crit PCT]
             [--disk-warn PCT] [--disk-crit PCT]
             [--output table|json]
```

## Options

| Flag                | Description                                   | Default        |
| ------------------- | --------------------------------------------- | -------------- |
| `-i SECONDS`        | Refresh interval in seconds                   | `1`            |
| `-p PATHS`          | Comma-separated list of disk paths to monitor | ''             |
| `--once`            | Print a single sample and exit                | (loop forever) |
| `--no-cpu`          | Disable CPU stats                             | enabled        |
| `--no-mem`          | Disable memory stats                          | enabled        |
| `--no-disk`         | Disable disk stats                            | enabled        |
| `--cpu-limit CORES` | Override CPU limit in cores                   | from cgroup    |
| `--mem-limit MIB`   | Override memory limit in Mib                  | from cgroup    |
| `--cpu-warn PCT`    | CPU usage warning threshold (%)               | `50`           |
| `--cpu-crit PCT`    | CPU usage critical threshold (%)              | `80`           |
| `--mem-warn PCT`    | Memory usage warning threshold (%)            | `70`           |
| `--mem-crit PCT`    | Memory usage critical threshold (%)           | `90`           |
| `--disk-warn PCT`   | Disk usage warning threshold (%)              | `80`           |
| `--disk-crit PCT`   | Disk usage critical threshold (%)             | `90`           |
| `--output table`    | Human-readable output with colors             | `table`        |
| `--output json`     | JSON output for scripting                     | none           |

## Examples

Run with defaults:

```sh
./cgstats.sh
```

Sample multiple paths:

```sh
./cgstats.sh -i 2 -p "/home/jovyan,/data"
```

JSON output once:

```sh
./cgstats.sh --no-disk --once --output json
```

Custom thresholds:

```sh
./cgstats.sh --cpu-limit 2 --mem-limit 4096 --cpu-warn 60 --cpu-crit 85 --mem-warn 70 --mem-crit 90
```

## Output Examples

### Table mode (default)

```
Container usage (cgroup v2)
Fri Aug 22 07:54:01 UTC 2025

  • CPU: 0.08 cores  (limit: 0.60 cores, used%: 13%)
  • MEM: 289 MiB     (limit: 1228 MiB, used%: 23%)
  • Disk /home/jovyan: 195 MiB / 4955 MiB (used%: 4%)
```

### JSON mode

```json
{
  "container_usage": {
    "cgroup_version": "v2",
    "timestamp": "2025-08-22T07:54:01Z",
    "cpu": {
      "used_cores": 0.08,
      "limit_cores": 0.6,
      "percent": 13
    },
    "memory": {
      "used_mib": 289,
      "limit_mib": 1228,
      "percent": 23
    },
    "disks": [
      {
        "path": "/home/jovyan",
        "used_mib": 195,
        "total_mib": 4955,
        "percent": 4
      }
    ]
  }
}
```

## Possible Use Case ideas

- **VS Code extension backend**  
  Run `cgstats.sh --output json` inside a pod and parse the JSON in a VS Code extension to display live CPU, memory, and disk stats in the editor UI.

- **Lightweight container introspection**  
  Add the script directly into container images. This gives developers and operators a zero-dependency way to inspect live resource usage without setting up Prometheus, Grafana, or external agents.

- **Interactive containers / notebooks**  
  Particularly useful in environments like **Kubeflow Notebooks** or **VS Code Server in Kubernetes**, where users often need a quick way to check their CPU, memory, and disk limits from inside the running container.

## Requirements

- Linux with cgroups v1 or v2 mounted at `/sys/fs/cgroup`
- POSIX-compatible shell (`/bin/sh`)
- Standard tools: awk and df
- No extra dependencies for table or JSON output
- JSON mode is implemented internally — **`jq` is not required**

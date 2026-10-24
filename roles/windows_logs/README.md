# windows_logs

The role installs Grafana Alloy on a Windows server. Alloy sends the event logs
of the server to Loki, and Grafana shows them.

## What it does

1. It finds which logs of `windows_logs_channels` the server has.
2. If the installed Alloy is not `windows_logs_alloy_version`, it downloads the
   installer from GitHub, checks its SHA-256 and runs it.
3. It sets the arguments of the `Alloy` service. Alloy sends no usage reports
   to Grafana Labs and has no profiling endpoint.
4. It writes `C:\Program Files\GrafanaLabs\Alloy\config.alloy`. Alloy reads
   each log and sends each event as one JSON line to `windows_logs_push_url`.
5. It starts the `Alloy` service and sets it to start at boot (delayed start).

If the version, the arguments or the configuration change, the role restarts
the service.

## Where the logs go

The Alloy in the cluster receives the events on `172.16.1.23` port 3100 and
sends them to Loki (LINDS-Kubernetes `applications/monitoring-loki.yaml`).
Each event has these labels:

| Label | Value |
| --- | --- |
| `job` | `windows` |
| `hostname` | The short name of the server, for example `jd-dc-01`. |
| `channel` | The log, for example `System` or `Directory Service`. |
| `level` | `critical`, `error`, `warning`, `info` or `debug`. |

The provider (`source`) and the event ID (`event_id`) are structured metadata.

To see the events, open the Grafana dashboard **Logs / Windows** (folder
Logs). In Explore, use queries like these:

- `{job="windows", level=~"critical|error"}`
- `{job="windows", hostname="linds-dc"} | event_id="4625"`

## Requirements

- The server can connect to `github.com` with HTTPS.
- The server can connect to `172.16.1.23` port 3100.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_logs_alloy_version` | `v1.21.2` | The Alloy release, as its GitHub tag. |
| `windows_logs_alloy_installer_sha256` | (the digest of the release) | The SHA-256 of `alloy-installer-windows-amd64.exe`. |
| `windows_logs_push_url` | `http://172.16.1.23:3100/loki/api/v1/push` | The Loki push API of the Alloy in the cluster. |
| `windows_logs_channels` | See `defaults/main.yml` | The logs to send. `query` is an XPath filter. Without it, Alloy sends every event of the log. |

The role sends all events of these logs: `Application`, `System`,
`Directory Service`, `DNS Server`, `DFS Replication` and
`Active Directory Web Services`. From `Security` it sends only the failures
and the changes to accounts, groups, the audit policy and the log. From the
Defender log it sends only errors, warnings and the actions on threats.

## How to use it

`playbooks/windows.yml` applies the role to each server in `windows_managed`
(tag `logs`):

```shell
ansible-playbook playbooks/windows.yml --tags logs
```

To upgrade Alloy, do these steps:

1. Get the digest of the installer of the new release:

   ```shell
   gh api repos/grafana/alloy/releases/tags/<tag> --jq '.assets[] | select(.name == "alloy-installer-windows-amd64.exe") | .digest'
   ```

2. Set `windows_logs_alloy_version` and `windows_logs_alloy_installer_sha256`
   together.
3. Run the playbook.

## Safety

**NOTE:** Alloy sends only the events that occur after it starts. The events
from before the installation stay only on the server.

**NOTE:** If the cluster does not receive the events, Alloy tries again until
it does. When its queue is full, it stops reading. The events then wait in the
event log, which keeps several days of events.

**NOTE:** Alloy writes its own warnings and errors to the `Application` log,
with the source `Alloy`.

## Known problems

- If you add a log to `windows_logs_channels`, Alloy sends the events of that
  log from the next restart of Alloy only.

# deploy

Merging to `main` applies the playbooks in [`playbooks`](playbooks) to their
hosts. [`linds-ansible-deploy`](linds-ansible-deploy) runs on `jd-jump-01`
from a systemd user timer. It looks for a new commit on `main` every five
minutes.

## What it does

For a new commit on `main`, the deploy does these steps for each entry in
`playbooks`, in order:

1. It finds the files that changed since the commit that it last applied to
   the hosts of the entry. If the playbook uses none of these files, it goes
   to the next entry.
2. It runs the playbook with `--check --diff`. If the check shows no change,
   it records the commit and goes to the next entry.
3. If the check shows that a task would reboot a host, it stops.
4. It runs the check again, from the commit that it applied last. If this
   check shows a change, a person changed the hosts outside the repository.
   The deploy stops, so that it does not undo that change.
5. It applies the playbook.

After each entry, it sets the commit status `deploy/<name>` on GitHub. If an
entry stops or fails, Alertmanager sends the alert `LindsAnsibleDeployFailed`
to Discord. A later success of the entry resolves the alert. If a commit
changes no file that a playbook uses, the status is `deploy/ansible`.

These are the files that a playbook uses:

- The playbook, the files of its roles, and the files of the roles that
  those roles use.
- The inventory files of its hosts and of the groups of its hosts.
- `ansible.cfg`, `requirements.yml` and `requirements-windows.txt`.
- Any other file that the playbook or its roles name, for example
  `windows-state/`.

Markdown files, `docs/` and `deploy/` change no host.

The deploy installs Ansible, the collections and the Galaxy roles that
`requirements-windows.txt` and `requirements.yml` of the commit pin. It keeps
them in its state folder. A merged Renovate update is used from the next
deploy.

## What it does not do

- **Reboot a host.** Apply a change that reboots by hand, for example a
  changed `.link` file on the router.
- **Undo a change that a person made on a host.** If a host has a change from
  outside the repository, the deploy stops for each merge that changes that
  playbook. When the change is merged, the hosts match again and the deploy
  continues.
- **Run the other playbooks.** `wsl.yml`, `minecraft.yml` and the
  `windows-*.yml` playbooks make or remove servers, ask for input, or are for
  a host that is off. Run them by hand.
- **Deploy `linds-router-01`.** Add an entry for it after the cutover.
- **Run during a Talos deploy.** If `linds-tf-deploy` runs, the deploy waits
  for the next poll.
- **Run at the same time as a playbook that a person runs.** If an
  `ansible-playbook` process runs on `jd-jump-01`, the deploy waits for the
  next poll.

**CAUTION:** The deploy cannot see a playbook that runs on a different
computer, or a job that is between two playbooks. Before you build, replace
or retire a Windows server, pause the entry `windows`:

```shell
touch ~/.local/state/linds-ansible-deploy/paused.windows
```

When you are done, remove the file and run `linds-ansible-deploy --retry`.
For work on other hosts, pause their entry the same way, or pause all entries
with the file `paused`.

## Windows

`windows.yml` uses Kerberos. The deploy gets a ticket in one of two ways:

- If the file `~/.local/state/linds-ansible-deploy/windows.keytab` exists, the
  deploy gets a ticket of its own with it.
- If not, it uses the ticket of the person on `jd-jump-01`
  (`kinit -f Administrator@LINDS.COM.AU`). It renews that ticket if it can.

If there is no ticket, the deploy does not apply `windows.yml`, and it sets
the status to failure. When a ticket exists again, the next poll tries again.

**NOTE:** A change to `windows.yml` takes about 40 minutes: two checks of
about 12 minutes each, then the apply.

## Why a timer, not GitHub Actions

The playbooks must run inside the network. The hosts are only reachable from
the LAN. This rules out the runners that GitHub hosts.

The repository is public, which rules out a self-hosted runner. On a public
repository, a runner takes jobs from any workflow that a pull request from a
fork brings, after that run is approved. The runner would hold root SSH
access to both sites, the vault password and a domain administrator ticket.
The logs of every run would be public. The timer only runs what is on
`main`. It needs nothing from GitHub but a fetch, and its logs stay on the
box.

## Install

On `jd-jump-01`, as `jayden` (user lingering is already on):

```shell
git clone https://github.com/Jayden-Lind/LINDS-Ansible.git ~/.local/state/linds-ansible-deploy/repo
mkdir -p ~/.config/systemd/user
cp ~/.local/state/linds-ansible-deploy/repo/deploy/systemd/linds-ansible-deploy.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload

~/.local/state/linds-ansible-deploy/repo/deploy/linds-ansible-deploy --dry-run   # read what it would do
systemctl --user enable --now linds-ansible-deploy.timer
```

The vault password comes from `~/LINDS-Ansible/vault_password`. To use a
different file, set `LINDS_ANSIBLE_DEPLOY_VAULT_PASSWORD` in the service.

The first deploy records each entry whose hosts match `main`. For an entry
whose hosts do not match, the status is failure. Apply that playbook by hand,
then run `linds-ansible-deploy --retry`.

## Use it

The commands are in `~/.local/state/linds-ansible-deploy/repo/deploy/`.

| To | Do this |
| --- | --- |
| Deploy now, not at the next poll | `systemctl --user start linds-ansible-deploy.service` |
| See what a deploy would do | `linds-ansible-deploy --dry-run`. It changes nothing. |
| See what a branch would do | `linds-ansible-deploy --dry-run --ref <branch>` |
| Try a failed entry again | `linds-ansible-deploy --retry`, optionally with `--only <name>` |
| Pause the deploy | `touch ~/.local/state/linds-ansible-deploy/paused`. Remove the file to continue. |
| Pause one entry, for example `windows` | `touch ~/.local/state/linds-ansible-deploy/paused.windows`. Its commit status is pending. Remove the file, then run `--retry`. |
| Read the log | `journalctl --user -t linds-ansible-deploy` |
| Read the output of a run | `~/.local/state/linds-ansible-deploy/logs/`, kept for 30 days |

## The state folder

`~/.local/state/linds-ansible-deploy/` contains:

| File | Contents |
| --- | --- |
| `repo/` | The clone. The timer runs the script from it. |
| `previous/` | A worktree for the check from the commit that the deploy applied last |
| `dry-run/` | A worktree for `--dry-run` |
| `env/` | The Ansible environments, one for each set of requirements |
| `logs/` | The output of each run of a playbook, and its summary |
| `seen.json` | The last commit of `main` that the deploy did |
| `deployed.json` | For each entry: the commit that its hosts match |
| `failed.json` | For each entry that stopped or failed: the commit and why |
| `paused` | If it exists, the deploy does nothing |
| `paused.<name>` | If it exists, the deploy does not apply that entry |
| `windows.keytab` | Optional: the keytab for the Windows playbooks |

## If it fails

- **"differ from ..., and there is no earlier deploy"**: the hosts did not
  match `main` when the deploy saw the entry first. Apply the playbook by
  hand, then run `--retry`.
- **"have changes that are not in ..."**: a person changed the hosts outside
  the repository. Merge that change, or apply `main` by hand. Then run
  `--retry`.
- **"the change reboots ..."**: apply the playbook by hand at a good time.
  Then run `--retry`.
- **"no Kerberos ticket"**: run `kinit -f Administrator@LINDS.COM.AU` on
  `jd-jump-01`. The next poll tries again.
- **"the apply failed"**: read the output in `logs/`. Fix the cause, then run
  `--retry`.

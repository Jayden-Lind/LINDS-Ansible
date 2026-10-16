# kubernetes

The `kubernetes` role installs Kubernetes with kubeadm and CRI-O. It makes
the cluster on the master and joins the other nodes to it.

## What it does

1. Loads `vars/vars.yml` into the variable `k8s_var`.
2. On RedHat-family hosts, adds the CRI-O and Kubernetes `v1.30` yum
   repositories. It installs `kubelet`, `kubeadm`, `kubectl`, `cri-o` and
   `nfs-utils`, and starts the services.
3. On Debian-family hosts, adds the CRI-O and Kubernetes `v1.34` apt
   repositories. It installs `kubelet`, `kubeadm`, `kubectl`, `cri-o` and
   `nfs-common`, and starts the services.
4. Turns off swap and removes the swap lines from `/etc/fstab`.
5. Sets `DefaultLimitNOFILE=1048576` and `DefaultTasksMax=20000` for systemd,
   the inotify limits and `net.ipv4.tcp_mtu_probing=1`.
6. Sets `short_name_mode = "disabled"` in
   `/etc/crio/crio.conf.d/10-crio.conf`.
7. Turns on IP forwarding and loads `br_netfilter` in the running kernel.
8. Installs `kubectl` bash completion. It sets
   `KUBECONFIG=/etc/kubernetes/admin.conf` in `/root/.bashrc`.
9. On the master: if `kubectl get nodes` does not list the master, runs
   `kubeadm init`. The pod network is `10.244.0.0/16` and the endpoint is
   `jd-kube-01.linds.com.au:6443`.
10. On the master: makes a new join command with
    `kubeadm token create --print-join-command`.
11. On the other nodes: if `/etc/kubernetes/kubelet.conf` does not exist,
    runs the join command.
12. Adds a weekly cron job that runs `crictl rmi --prune`.
13. On the master: clones `LINDS-Kubernetes` to `/root/k8s/` and copies
    `files/linds-secret.yml` (stored in the vault) to
    `/root/k8s/base/linds-secret.yml`. It installs Helm and sets the global
    Git user.

## Requirements

- The group `master` in `inventory/kubernetes.yaml` has one host. The group
  `nodes` has the other hosts.
- A node that joins must be in the same run as the master. The node reads the
  join command from the result of the master.
- The `vault_password` file must be in the repository root.

## Variables

The role has no defaults. `vars/vars.yml` sets the variables below, under
`k8s_var`.

| Variable | Default | Description |
| --- | --- | --- |
| `local_k8s_dir` | `/root/k8s/` | Where the master clones `LINDS-Kubernetes`. |

No task uses the other variables in `vars/vars.yml` (`user`, `arr_*`,
`truenas_host`). The Kubernetes version, the pod network and the endpoint
are written in the task files.

## How to use it

`playbooks/kubernetes.yml` applies `common` and then this role to the group
`kubernetes`. See [playbooks/kubernetes.md](../../playbooks/kubernetes.md).

## Safety

**WARNING:** If `kubectl get nodes` fails on the master for any reason, the
role runs `kubeadm init`. Make sure that the API server answers before you
run the role.

**WARNING:** `make kubeadm-reset` runs `kubeadm reset -f` on every host in
the group `kubernetes`. This removes the cluster from those hosts.

**CAUTION:** The packages have `state: latest`. A run can upgrade `kubelet`,
`kubeadm`, `kubectl` and `cri-o`.

## Known problems

- `tasks/master.yml` uses `apt`. On a RedHat-family master, the Helm tasks
  fail.
- RedHat-family hosts get Kubernetes `v1.30`. Debian-family hosts get
  `v1.34`.
- The role sets IP forwarding and `br_netfilter` only in the running kernel.
  It writes no file that keeps them after a reboot.
- The router DHCP files (`roles/router/files/*/etc/kea/kea-dhcp4.conf`) list
  Talos nodes (`talos-*`), not `jd-kube-*` or `linds-kube-*`. Not known if
  the hosts in `inventory/kubernetes.yaml` still exist.

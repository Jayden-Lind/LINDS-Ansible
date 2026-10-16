# kubernetes.yml

The `kubernetes.yml` playbook installs the kubeadm cluster. It applies the
roles `common` and `kubernetes`. Use it to set up the cluster or to join a
new node.

## Before you start

- Read [roles/kubernetes/README.md](../roles/kubernetes/README.md).
- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the Galaxy roles and collections: `make update-requirements`.
- Make sure that the API server on the master answers.

## Procedure

**WARNING:** If `kubectl get nodes` fails on the master, the role runs
`kubeadm init` on it.

1. Run `ansible-playbook playbooks/kubernetes.yml`.
2. To join one new node, add it to the group `nodes` in
   `inventory/kubernetes.yaml`.
3. Run `ansible-playbook playbooks/kubernetes.yml --limit master,<node>`.

## What it changes

- The group `kubernetes` in `inventory/kubernetes.yaml`. The group `master`
  is `jd-kube-01`. The group `nodes` is `jd-kube-02` to `jd-kube-04`,
  `linds-kube-01` and `linds-kube-02`. Ansible connects as `root`.
- For the settings, see the two role READMEs.

## If it fails

- `kubernetes_join_command` is undefined: the master was not in the run. Add
  `master` to `--limit`.

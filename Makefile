lint:
	ansible-lint --project-dir . --fix 

update-requirements:
	ansible-galaxy install -r requirements.yml --force

# --- Windows ------------------------------------------------------------------
# See docs/windows/README.md. Every target needs a Kerberos ticket (make kinit),
# except venv, kinit, windows-prepare and windows-data-disk.

# The Python environment for WinRM with Kerberos. Build it with /usr/bin/python3:
# pykerberos links to the system MIT Kerberos and does not load under nix.
venv:
	/usr/bin/python3 -m venv .venv
	./.venv/bin/pip install --quiet --upgrade pip
	./.venv/bin/pip install --quiet "pywinrm[kerberos]" ansible-core
	./.venv/bin/python -c "from winrm.transport import HAVE_KERBEROS; \
	  assert HAVE_KERBEROS, 'kerberos transport unavailable'; print('winrm+kerberos ready')"

# Get a Kerberos ticket. It asks for the password. Nothing is stored.
KINIT_PRINCIPAL ?= Administrator@LINDS.COM.AU
kinit:
	KRB5_CONFIG=$(CURDIR)/krb5.conf kinit $(KINIT_PRINCIPAL)
	@klist | head -4

WINDOWS_PLAY = KRB5_CONFIG=$(CURDIR)/krb5.conf ./.venv/bin/ansible-playbook
WINDOWS_STATE ?= $(CURDIR)/windows-state

# The settings of the domain. TAGS: topology, recovery, dfsr, gpo or directory.
windows:
	$(WINDOWS_PLAY) playbooks/windows.yml $(if $(TAGS),--tags $(TAGS))

windows-check:
	$(WINDOWS_PLAY) playbooks/windows.yml --check --diff $(if $(TAGS),--tags $(TAGS))

windows-directory-check:
	$(WINDOWS_PLAY) playbooks/windows.yml --tags directory --check --diff

windows-directory:
	$(WINDOWS_PLAY) playbooks/windows.yml --tags directory

# The baseline of one server. UPDATES=true also installs updates; TAGS=<tag>
# applies one setting only.
windows-baseline:
	$(WINDOWS_PLAY) playbooks/windows-baseline.yml -e target=$(HOST) \
	  -e windows_baseline_updates=$(or $(UPDATES),false) $(if $(TAGS),--tags $(TAGS))

# Build a server from a clone of the template, in this order.
# HOST is the inventory name; ADDRESS is the DHCP address of the clone.
windows-prepare:
	$(WINDOWS_PLAY) playbooks/windows-prepare.yml -e target=$(HOST) -e bootstrap_address=$(ADDRESS)

# Asks for the product key and gives it to Ansible in the environment only.
# With ADDRESS: a clone that is not in the domain. Without: a domain member.
windows-edition:
	@bash -c 'read -r -s -p "Product key for the edition to convert to: " key && echo && \
	  WINDOWS_PRODUCT_KEY="$$key" $(WINDOWS_PLAY) playbooks/windows-edition.yml -e target=$(HOST) \
	  $(if $(ADDRESS),-e bootstrap_address=$(ADDRESS))'

windows-join:
	$(WINDOWS_PLAY) playbooks/windows-join.yml -e target=$(HOST) $(if $(ADDRESS),-e bootstrap_address=$(ADDRESS))

# Asks for the restore-mode password. Press Enter to use the one in the vault.
windows-promote:
	@bash -c 'read -r -s -p "Restore-mode password for $(HOST) (Enter for the one in the vault): " pw && echo && \
	  WINDOWS_DSRM_PASSWORD="$$pw" $(WINDOWS_PLAY) playbooks/windows-promote.yml -e target=$(HOST)'

# Retire a domain controller. REPLACING=true when a new server with the same
# name comes next.
windows-retire-dc:
	$(WINDOWS_PLAY) playbooks/windows-retire-dc.yml -e target=$(HOST) \
	  -e windows_dc_retire_keep_bridgehead=$(or $(REPLACING),false)

# Attach the data disks of HOST to its VM, on the hypervisor (SSH as root).
windows-data-disk:
	./.venv/bin/ansible-playbook playbooks/windows-data-disk.yml -e target=$(HOST)

# The certification authority on HOST: restored from the backup if there is one.
windows-ca:
	$(WINDOWS_PLAY) playbooks/windows-ca.yml -e target=$(HOST) -e windows_state_dir=$(WINDOWS_STATE)

# Back up the CA to windows-state/ca/backup, encrypted with the vault.
windows-ca-backup:
	$(WINDOWS_PLAY) playbooks/windows-ca-backup.yml -e windows_state_dir=$(WINDOWS_STATE)

# Write the state of the domain to windows-state/. It changes nothing.
windows-capture:
	$(WINDOWS_PLAY) playbooks/windows-capture.yml -e windows_state_dir=$(WINDOWS_STATE)

# A decrypted copy of windows-state/ in DEST. Use memory (/dev/shm) and delete it after.
windows-state-plain:
	./.venv/bin/python scripts/windows_state.py decrypt-tree $(DEST) $(WINDOWS_STATE) vault_password

lint:
	ansible-lint --project-dir . --fix 

update-requirements:
	ansible-galaxy install -r requirements.yml --force

kubeadm-reset:
	ansible kubernetes -a "kubeadm reset -f"

# --- Windows domain ---------------------------------------------------------
# The venv MUST be built against /usr/bin/python3. pykerberos links against the
# system MIT krb5 and will not load under the nix Python's glibc.
venv:
	/usr/bin/python3 -m venv .venv
	./.venv/bin/pip install --quiet --upgrade pip
	./.venv/bin/pip install --quiet "pywinrm[kerberos]" ansible-core
	./.venv/bin/python -c "from winrm.transport import HAVE_KERBEROS; \
	  assert HAVE_KERBEROS, 'kerberos transport unavailable'; print('winrm+kerberos ready')"

# Prompts for the domain admin password. Nothing is stored; the ticket lands in
# the caller's credential cache and expires on its own.
kinit:
	KRB5_CONFIG=$(CURDIR)/krb5.conf kinit Administrator@LINDS.COM.AU
	@klist | head -4

windows:
	KRB5_CONFIG=$(CURDIR)/krb5.conf ./.venv/bin/ansible-playbook playbooks/windows.yml

windows-check:
	KRB5_CONFIG=$(CURDIR)/krb5.conf ./.venv/bin/ansible-playbook playbooks/windows.yml --check --diff

# --- Building a Windows server from the template -----------------------------
# The VM comes from LINDS-Terraform (packer/windows, proxmox/vms-linds.tf).
# HOST is its inventory name; ADDRESS is the DHCP address the fresh clone has
# (terraform output windows_bootstrap_addresses). See docs/windows-domain.md.
WINDOWS_PLAY = KRB5_CONFIG=$(CURDIR)/krb5.conf ./.venv/bin/ansible-playbook

windows-build:
	$(WINDOWS_PLAY) playbooks/windows-build.yml --tags bootstrap,baseline,join \
	  -e target=$(HOST) -e bootstrap_address=$(ADDRESS)

# The product key is typed here and passed in the environment. It is not
# stored, logged or put on a command line.
windows-edition:
	@bash -c 'read -r -s -p "Product key for the edition to convert to: " key && echo && \
	  WINDOWS_PRODUCT_KEY="$$key" $(WINDOWS_PLAY) playbooks/windows-build.yml --tags edition -e target=$(HOST)'

# The restore-mode password comes from the vault unless one is typed here.
windows-promote:
	@bash -c 'read -r -s -p "Restore-mode password for $(HOST) (Enter for the one in the vault): " pw && echo && \
	  WINDOWS_DSRM_PASSWORD="$$pw" $(WINDOWS_PLAY) playbooks/windows-build.yml --tags promote -e target=$(HOST)'

# One existing server at a time; see the header of the playbook.
windows-baseline:
	$(WINDOWS_PLAY) playbooks/windows-baseline.yml -e target=$(HOST) \
	  -e windows_baseline_updates=$(or $(UPDATES),false)

windows-retire-dc:
	$(WINDOWS_PLAY) playbooks/windows-retire-dc.yml -e target=$(HOST)


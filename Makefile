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
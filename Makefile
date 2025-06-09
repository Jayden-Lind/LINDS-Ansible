lint:
	ansible-lint --project-dir . --fix 

update-requirements:
	ansible-galaxy install -r requirements.yml --force

kubeadm-reset:
	ansible kubernetes -a "kubeadm reset -f"
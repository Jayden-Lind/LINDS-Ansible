lint:
	ansible-lint --offline --project-dir . --fix 

update-requirements:
	ansible-galaxy install -r requirements.yml --force
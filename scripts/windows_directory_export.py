#!/usr/bin/env python3
"""Write the directory's desired state from the last capture.

Run once, to start managing the directory from code with what is there now:

    windows_directory_export.py <state dir> <group_vars dir> <vault password file>

It writes two variable files:

    directory.yml         OUs, the GPOs linked to each, and the groups   (plain)
    directory.vault.yml   users, who is in which group, password policy  (vault)

From then on those files are edited by hand (`ansible-vault edit` for the
second) and the windows_directory role makes the domain match them. Running
this again would overwrite those edits with whatever the domain looks like.
"""
import pathlib
import sys

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import windows_state as state  # noqa: E402

# Accounts and groups Windows or a product created. They are left alone.
BUILTIN_USERS = {'Administrator', 'Guest', 'krbtgt', 'DefaultAccount'}
# Groups whose membership is power. Their members are listed exactly, and
# anything else found in them is removed.
PRIVILEGED = ['Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators', 'Account Operators', 'Server Operators',
              'Backup Operators', 'Print Operators', 'DnsAdmins', 'Group Policy Creator Owners', 'Protected Users']


def main():
    state_dir, out, vault_file = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]), sys.argv[3]
    state.open_vault(state_dir, vault_file)

    def read(name):
        return yaml.safe_load(state.read_stored(state_dir / name))

    domain, ous, groups, users = read('domain/domain.yml'), read('domain/ous.yml'), read('domain/groups.yml'), read('domain/users.yml')
    suffix = ',' + ous[0]['dn']

    def relative(dn):
        return '' if dn == ous[0]['dn'] else dn[:-len(suffix)]

    custom = [g for g in groups if not g['container'].startswith(('CN=Builtin,', 'CN=Users,'))]
    leftover = [g['name'] for g in groups if g['container'].startswith('CN=Users,') and g['members'] is not None
                and g['name'] in ('ADSyncAdmins', 'ADSyncBrowse', 'ADSyncOperators', 'ADSyncPasswordSet', 'docker-users', 'IPAMUG',
                                  'WSUS Administrators', 'WSUS Reporters')]
    managed_users = [u for u in users if u['name'] not in BUILTIN_USERS and not u['name'].startswith(('MSOL_', 'AAD_'))]
    unmanaged_users = sorted(u['name'] for u in users if u not in managed_users)

    plain = {
        'windows_directory_ous': [
            {'ou': relative(o['dn']), 'description': o['description'], 'protected': bool(o['protected_from_deletion'])}
            for o in ous[1:] if not o['dn'].startswith('OU=Domain Controllers,')],
        'windows_directory_gpo_links': {
            (relative(o['dn']) or 'domain'): [
                {k: v for k, v in (('gpo', link['gpo']), ('enabled', link['enabled']), ('enforced', link['enforced']))
                 if k == 'gpo' or (k == 'enabled' and not v) or (k == 'enforced' and v)}
                for link in o['gpo_links']]
            for o in ous if o['gpo_links']},
        'windows_directory_groups': [
            {'name': g['name'], 'ou': relative(g['container']), 'scope': g['scope'].lower(), 'category': g['category'].lower(),
             'description': g['description']}
            for g in custom],
    }
    by_name = {g['name']: g for g in groups}
    secret = {
        'windows_directory_password_policy': domain['default_password_policy'],
        'windows_directory_machine_account_quota': domain['machine_account_quota'],
        'windows_directory_users': [
            {'name': u['name'], 'display_name': u['display_name'], 'ou': relative(u['container']), 'upn': u['upn'],
             'enabled': u['enabled'], 'description': u['description'], 'password_never_expires': u['password_never_expires']}
            for u in managed_users],
        'windows_directory_members': {g['name']: g['members'] for g in custom},
        'windows_directory_privileged': {name: by_name[name]['members'] for name in PRIVILEGED if name in by_name},
    }

    out.mkdir(parents=True, exist_ok=True)
    head = ('# The directory as it should be. Generated once from the capture of 11 October\n'
            '# 2026 by scripts/windows_directory_export.py; edited by hand since.\n'
            '# The other half (people, memberships, password policy) is in\n'
            '# directory.vault.yml: `ansible-vault edit` it.\n'
            '#\n# Paths are relative to the domain: "OU=Kubernetes", not "OU=Kubernetes,DC=...".\n'
            '# In windows_directory_gpo_links the key "domain" is the domain root, and the\n'
            '# list is in order of precedence, first wins.\n')
    dump = lambda data: yaml.dump(state.clean(data), Dumper=state.Dumper, sort_keys=False, allow_unicode=True, width=140)  # noqa: E731
    (out / 'directory.yml').write_text('---\n' + head + dump(plain))
    note = ('# People, who is in which group, and the password policy. Vault-encrypted:\n'
            '# the repository is public.\n#\n'
            '# windows_directory_members      exact membership of the groups this repository owns\n'
            '# windows_directory_privileged   exact membership of the groups that are power;\n'
            '#                                anything else found in them is removed\n'
            '# Not managed, left as found: ' + ', '.join(unmanaged_users) + '\n'
            '# Groups left by products, not managed: ' + ', '.join(leftover) + '\n')
    vault, key = state._vault
    (out / 'directory.vault.yml').write_bytes(vault.encrypt(('---\n' + note + dump(secret)).encode(), key))
    print('ous %d, groups %d, users %d, privileged groups %d; not managed: %s' % (
        len(plain['windows_directory_ous']), len(custom), len(managed_users), len(secret['windows_directory_privileged']),
        ', '.join(unmanaged_users)))


if __name__ == '__main__':
    main()

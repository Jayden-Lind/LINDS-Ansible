#!/usr/bin/env python3
"""Turn what playbooks/windows-capture.yml collected into files worth diffing.

The playbook leaves one JSON document per source in a work directory. This
writes them out as small YAML files with a fixed layout and ordering, so that
`git diff` in the state directory shows what changed in the domain and
nothing else, and unpacks the GPO backups beside them.

The state directory is committed to a public repository. Files that name
people, say who holds which rights, or show what is weak or switched off are
therefore encrypted with the Ansible vault as they are written (SENSITIVE
below); the structure of the domain stays readable. An encrypted file is only
rewritten when what it holds has changed, so an unchanged domain still gives
an empty diff.

    windows_state.py write            <work dir> <state dir> <vault password file>
    windows_state.py ca-backup        <work dir> <state dir> <vault password file>
    windows_state.py verify-ca-backup -          <state dir> <vault password file>
    windows_state.py view             <file>     <state dir> <vault password file>
    windows_state.py decrypt-tree     <dest dir> <state dir> <vault password file>

Nothing here talks to a server.
"""
import fnmatch
import json
import os
import pathlib
import re
import shutil
import sys
import zipfile

import yaml

# The vault library is Ansible's; keep its start-up chatter out of the output.
os.environ.setdefault('ANSIBLE_DEPRECATION_WARNINGS', 'False')


class Dumper(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def _str(dumper, value):
    style = '|' if '\n' in value else None
    return dumper.represent_scalar('tag:yaml.org,2002:str', value, style=style)


Dumper.add_representer(str, _str)


def clean(value):
    """Empty PowerShell collections arrive as null, {} or [null]."""
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean(v) for v in value if v is not None]
    return value


# What is encrypted, relative to the state directory. Everything else is
# plain: sites, the OU tree and its GPO links, DNS records, each server's
# features and addresses, the CA's settings and the public certificates.
SENSITIVE = [
    'domain/domain.yml',            # password policy, account quota
    'domain/users.yml',             # who the people are
    'domain/groups.yml',            # who is in what
    'domain/computers.yml',         # every machine and what it runs
    'domain/service-accounts.yml',
    'domain/privileged.yml',        # who holds the keys
    'domain/delegation.yml',        # who may do what to whom
    'gpo/*/gpo.yml',                # who may edit each policy
    'gpo/*/report.xml',             # what policy switches on and off
    'gpo/*/backup/*',               # the same, in restorable form
    'dns/zones.yml',                # who may update and copy the zones
    'ca/templates.yml',             # who may be issued which certificate
    'ca/backup/*.p12',              # the CA's private key
    'ca/backup/*.zip',              # the CA's database
    'ca/backup/password.yml',
    'hosts/*/shares.yml',           # what is shared with whom
    'hosts/*/services.yml',         # remote-control tools and the like
    'hosts/*/software.yml',         # versions, including the old ones
    'hosts/*/security.yml',         # what is switched off
]

_vault = None
_state = None


def open_vault(state, vault_password_file):
    global _vault, _state
    from ansible.parsing.vault import VaultLib, VaultSecret
    secret = VaultSecret(pathlib.Path(vault_password_file).read_bytes().strip())
    _vault = (VaultLib([('default', secret)]), secret)
    _state = state


def is_sensitive(path):
    relative = path.relative_to(_state).as_posix()
    # fnmatch's * crosses directories, which is what gpo/*/backup/* wants.
    return any(fnmatch.fnmatch(relative, pattern) for pattern in SENSITIVE)


def read_stored(path):
    """The content of a state file, decrypted if it is encrypted."""
    data = path.read_bytes()
    if data.startswith(b'$ANSIBLE_VAULT'):
        return _vault[0].decrypt(data)
    return data


def emit(path, data):
    """Write one state file, encrypted or not according to SENSITIVE."""
    if isinstance(data, str):
        data = data.encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not is_sensitive(path):
        path.write_bytes(data)
        return
    # Encrypting the same content twice gives two different files. Leave the
    # stored one alone unless what it holds has really changed.
    if path.exists():
        try:
            if read_stored(path) == data:
                return
        except Exception:
            pass
    path.write_bytes(_vault[0].encrypt(data, _vault[1]))


def write(path, data, header=None):
    text = yaml.dump(clean(data), Dumper=Dumper, sort_keys=False, allow_unicode=True, width=140, default_flow_style=False)
    if header:
        text = ''.join('# %s\n' % line for line in header.splitlines()) + text
    emit(path, text)


def safe(name):
    return re.sub(r'[^A-Za-z0-9._-]+', '-', name).strip('-')


def load(work, name):
    path = work / name
    return json.loads(path.read_text()) if path.exists() else None


def write_domain(work, state):
    data = load(work, 'domain.json')
    if not data:
        return
    out = state / 'domain'
    write(out / 'domain.yml', data['domain'], 'The domain itself: levels, role holders, password policy.')
    write(out / 'sites.yml', data['sites'], 'AD sites, their subnets and the links between them.')
    write(out / 'ous.yml', data['ous'], 'The domain root and every OU, with the GPOs linked to each, in order.')
    write(out / 'groups.yml', data['groups'], 'Every group and its direct members.')
    write(out / 'users.yml', data['users'], 'Every user account. No logon times: they change by themselves.')
    write(out / 'computers.yml', data['computers'], 'Every computer account.')
    write(out / 'service-accounts.yml', data['service_accounts'], 'Managed service accounts and who may use them.')
    write(out / 'privileged.yml', data['privileged'],
          'Who ends up in the groups that matter, nesting followed. Groups are not listed, only the accounts in them.')
    write(out / 'delegation.yml', data['delegation'],
          'Explicit (not inherited) permissions on the domain root, the default containers,\nAdminSDHolder and every OU.')


def write_gpos(work, state):
    data = load(work, 'gpo.json')
    if not data:
        return
    out = state / 'gpo'
    archive = work / 'gpo.zip'
    unpacked = work / 'gpo-unpacked'
    if archive.exists():
        if unpacked.exists():
            shutil.rmtree(unpacked)
        with zipfile.ZipFile(archive) as z:
            # Windows writes backslashes into the names.
            for member in z.infolist():
                target = unpacked / member.filename.replace('\\', '/')
                if member.is_dir() or member.filename.endswith(('/', '\\')):
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(z.read(member))

    index_path = out / 'index.yml'
    previous = {}
    if index_path.exists():
        previous = {g['id']: g for g in (yaml.safe_load(index_path.read_text()) or {}).get('gpos', [])}

    index = []
    wanted = set()
    for gpo in data['gpos']:
        folder = out / safe(gpo['name'])
        wanted.add(folder.name)
        backup_id = gpo.pop('backup_id')
        before = previous.get(gpo['id'], {})
        unchanged = (before.get('computer_version') == gpo['computer_version']
                     and before.get('user_version') == gpo['user_version']
                     and (folder / 'backup').exists())
        report = unpacked / 'report' / ('%s.xml' % gpo['id'])
        if report.exists():
            # The report is UTF-16 and stamps the time it was read.
            text = report.read_bytes().decode('utf-16')
            text = re.sub(r'\s*<ReadTime>.*?</ReadTime>', '', text)
            text = text.replace('encoding="utf-16"', 'encoding="utf-8"')
            emit(folder / 'report.xml', text)
        # A backup gets a new identity every time it is taken, so it is only
        # replaced when the GPO's version numbers have moved.
        source = unpacked / 'backup' / ('{%s}' % backup_id)
        if not source.exists():
            source = unpacked / 'backup' / ('{%s}' % backup_id.upper())
        if source.exists() and not unchanged:
            if (folder / 'backup').exists():
                shutil.rmtree(folder / 'backup')
            for item in sorted(source.rglob('*')):
                if item.is_file():
                    emit(folder / 'backup' / source.name / item.relative_to(source), item.read_bytes())
        write(folder / 'gpo.yml', gpo)
        index.append({'name': gpo['name'], 'folder': folder.name, 'id': gpo['id'], 'status': gpo['status'],
                      'computer_version': gpo['computer_version'], 'user_version': gpo['user_version']})
    write(index_path, {'gpos': index, 'wmi_filters': data.get('wmi_filters') or []},
          'Every Group Policy object. Each has a folder with its settings report,\nits permissions and a backup that Import-GPO can restore.')
    # A GPO that no longer exists should not linger here looking current.
    if out.exists():
        for folder in out.iterdir():
            if folder.is_dir() and folder.name not in wanted:
                shutil.rmtree(folder)


def write_dns(work, state):
    data = load(work, 'dns.json')
    if not data:
        return
    out = state / 'dns'
    summary = []
    wanted = set()
    for zone in data['zones']:
        records = zone.pop('static_records', None)
        summary.append(zone)
        if records is not None:
            name = '%s.yml' % safe(zone['name'])
            wanted.add(name)
            write(out / 'records' / name, records,
                  'Records in %s that somebody created. Records machines register for\nthemselves are not listed.' % zone['name'])
    write(out / 'zones.yml', summary, 'DNS zones and their settings.')
    if (out / 'records').exists():
        for path in (out / 'records').iterdir():
            if path.name not in wanted:
                path.unlink()


def write_ca(work, state):
    data = load(work, 'ca.json')
    if not data:
        return
    out = state / 'ca'
    write(out / 'ca.yml', data['ca'], 'The certification authority: settings and who may manage it.')
    write(out / 'templates.yml', data['templates'],
          'Every certificate template in the directory. "published" says whether the CA issues it.')
    write(out / 'trust.yml', data['trust'], 'What the directory trusts: the stores every domain member downloads.')
    if data.get('certificate_pem'):
        emit(out / ('%s.cer' % safe(data['ca']['name'])), data['certificate_pem'])


def write_hosts(work, state):
    wanted = set()
    for path in sorted(work.glob('host-*.json')):
        data = json.loads(path.read_text())
        name = data['host']['name'].lower()
        wanted.add(name)
        out = state / 'hosts' / name
        write(out / 'host.yml', data['host'], 'What this server is and what is installed on it.')
        write(out / 'shares.yml', {'smb': data['shares'], 'nfs': data.get('nfs_shares') or []},
              'What this server shares, to whom, and the permissions one level down.')
        write(out / 'services.yml', {'services': data['services'], 'scheduled_tasks': data['scheduled_tasks']},
              'Services that did not come with Windows or that log on as an account,\nand scheduled tasks outside \\Microsoft.')
        write(out / 'software.yml', data['software'], 'Installed programs.')
        write(out / 'security.yml', data['security'], 'Security settings as they are on the server, whatever set them.')
        if data.get('dns_server'):
            write(out / 'dns-server.yml', data['dns_server'], 'DNS server settings that are per server, not per zone.')
    return wanted


def ca_backup(work, state):
    """Store the CA backup: key, database and password encrypted, settings readable."""
    out = state / 'ca' / 'backup'
    stored = []
    for source in sorted(work.glob('ca-backup/*')):
        if source.suffix == '.reg':
            # Settings, not secrets. Windows exports UTF-16.
            emit(out / source.name, source.read_bytes().decode('utf-16').replace('\r\n', '\n'))
        else:
            emit(out / source.name, source.read_bytes())
        stored.append(source.name)
    password = (work / 'ca-backup-password').read_text().strip()
    emit(out / 'password.yml', 'windows_ca_backup_password: "%s"\n' % password)
    print('stored: ' + ', '.join(stored + ['password.yml']))


README = """\
# State of the Windows domain

Written by `make windows-capture` and `make windows-ca-backup`. Do not edit by
hand: capture again and read the diff.

| Folder | What |
| --- | --- |
| `domain/` | The domain, sites, OUs with their GPO links, groups, users, computers, service accounts, who is privileged, delegation |
| `gpo/` | Every Group Policy object: `report.xml` (settings), `gpo.yml` (status, permissions), `backup/` (restorable with `Import-GPO`) |
| `dns/` | Zones and the records somebody created |
| `ca/` | The CA's settings, certificate templates and trust stores; `backup/` holds the CA key and database |
| `hosts/` | Per server: features, shares and permissions, services, scheduled tasks, software, security settings |

## What is encrypted

This repository is public. Files that name people, say who holds which rights
or show what is weak or switched off are encrypted with the Ansible vault;
the structure of the domain is plain text. The list is `SENSITIVE` in
`scripts/windows_state.py` and is mirrored in `.gitattributes` here.

To read an encrypted file: `ansible-vault view <file>`.

To make `git diff` and `git log -p` show them in the clear on your machine,
once per clone:

    git config diff.ansible-vault.textconv "ansible-vault view"

To get a readable copy of everything, for example to restore a GPO with
`Import-GPO -Path <copy>/gpo/<name>/backup`:

    make windows-state-plain DEST=/dev/shm/windows-state

An encrypted file is only rewritten when its content changes, so a capture of
an unchanged domain still leaves `git status` clean.

Everything encrypted here, the CA's private key included, is exactly as safe
as the vault password.
"""


def write_gitattributes(state):
    lines = ['# Written by scripts/windows_state.py from its SENSITIVE list.',
             '# Vault-encrypted files; see README.md for making their diffs readable.']
    for pattern in SENSITIVE:
        # In .gitattributes a trailing /* does not descend; ** does.
        lines.append('%s diff=ansible-vault' % (pattern[:-1] + '**' if pattern.endswith('/*') else pattern))
    (state / '.gitattributes').write_text('\n'.join(lines) + '\n')


def decrypt_tree(dest, state):
    """A readable copy of the whole state directory."""
    for path in sorted(state.rglob('*')):
        if path.is_file() and '.git' not in path.relative_to(state).parts[:1]:
            target = dest / path.relative_to(state)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(read_stored(path))
    print('readable copy in %s' % dest)


def verify_ca_backup(state):
    """Prove the stored backup opens and holds the CA's private key. Prints no secret."""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.serialization import pkcs12
    out = state / 'ca' / 'backup'
    password = yaml.safe_load(read_stored(out / 'password.yml'))['windows_ca_backup_password']
    for path in sorted(out.glob('*.p12')):
        key, cert, extra = pkcs12.load_key_and_certificates(read_stored(path), password.encode())
        if key is None or cert is None:
            sys.exit('%s holds no private key or no certificate' % path.name)
        matches = key.public_key().public_numbers() == cert.public_key().public_numbers()
        print('%s: %s, private key %d bits, key matches certificate: %s, thumbprint %s, valid to %s' % (
            path.name, cert.subject.rfc4514_string(), key.key_size, matches,
            cert.fingerprint(hashes.SHA1()).hex().upper(), cert.not_valid_after_utc.date()))
        if not matches:
            sys.exit('the key in %s does not belong to its certificate' % path.name)


def main():
    command, first, state, vault_file = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]).resolve(), sys.argv[4]
    state.mkdir(parents=True, exist_ok=True)
    open_vault(state, vault_file)
    if command == 'view':
        sys.stdout.buffer.write(read_stored(first))
        return
    if command == 'decrypt-tree':
        decrypt_tree(first, state)
        return
    if command == 'verify-ca-backup':
        verify_ca_backup(state)
        return
    (state / 'README.md').write_text(README)
    write_gitattributes(state)
    if command == 'write':
        write_domain(first, state)
        write_gpos(first, state)
        write_dns(first, state)
        write_ca(first, state)
        write_hosts(first, state)
    elif command == 'ca-backup':
        ca_backup(first, state)
    else:
        sys.exit('unknown command %s' % command)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Turn what playbooks/windows-capture.yml collected into files worth diffing.

The playbook leaves one JSON document per source in a work directory. This
writes them out as small YAML files with a fixed layout and ordering, so that
`git diff` in the state directory shows what changed in the domain and
nothing else, and unpacks the GPO backups beside them.

    windows_state.py write            <work dir> <state dir>
    windows_state.py ca-backup        <work dir> <state dir> <vault password file>
    windows_state.py verify-ca-backup -          <state dir> <vault password file>

Nothing here talks to a server.
"""
import json
import pathlib
import re
import shutil
import sys
import zipfile

import yaml


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


def write(path, data, header=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = yaml.dump(clean(data), Dumper=Dumper, sort_keys=False, allow_unicode=True, width=140, default_flow_style=False)
    if header:
        text = ''.join('# %s\n' % line for line in header.splitlines()) + text
    path.write_text(text)


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

    index = []
    wanted = set()
    for gpo in data['gpos']:
        folder = out / safe(gpo['name'])
        wanted.add(folder.name)
        backup_id = gpo.pop('backup_id')
        meta_path = folder / 'gpo.yml'
        previous = yaml.safe_load(meta_path.read_text()) if meta_path.exists() else {}
        unchanged = (previous.get('computer_version') == gpo['computer_version']
                     and previous.get('user_version') == gpo['user_version']
                     and (folder / 'backup').exists())
        report = unpacked / 'report' / ('%s.xml' % gpo['id'])
        if report.exists():
            # The report is UTF-16 and stamps the time it was read.
            text = report.read_bytes().decode('utf-16')
            text = re.sub(r'\s*<ReadTime>.*?</ReadTime>', '', text)
            text = text.replace('encoding="utf-16"', 'encoding="utf-8"')
            (folder).mkdir(parents=True, exist_ok=True)
            (folder / 'report.xml').write_text(text)
        # A backup gets a new identity every time it is taken, so it is only
        # replaced when the GPO's version numbers have moved.
        source = unpacked / 'backup' / ('{%s}' % backup_id)
        if not source.exists():
            source = unpacked / 'backup' / ('{%s}' % backup_id.upper())
        if source.exists() and not unchanged:
            if (folder / 'backup').exists():
                shutil.rmtree(folder / 'backup')
            shutil.copytree(source, folder / 'backup' / source.name)
        write(meta_path, gpo)
        index.append({'name': gpo['name'], 'folder': folder.name, 'id': gpo['id'], 'status': gpo['status'],
                      'computer_version': gpo['computer_version'], 'user_version': gpo['user_version']})
    write(out / 'index.yml', {'gpos': index, 'wmi_filters': data.get('wmi_filters') or []},
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
        (out / ('%s.cer' % safe(data['ca']['name']))).write_text(data['certificate_pem'])


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


def ca_backup(work, state, vault_password_file):
    """Store the CA backup encrypted with the Ansible vault."""
    from ansible.parsing.vault import VaultLib, VaultSecret
    secret = VaultSecret(pathlib.Path(vault_password_file).read_bytes().strip())
    vault = VaultLib([('default', secret)])
    out = state / 'ca' / 'backup'
    out.mkdir(parents=True, exist_ok=True)
    stored = []
    for source in sorted(work.glob('ca-backup/*')):
        if source.suffix == '.reg':
            # Settings, not secrets: kept readable. Windows exports UTF-16.
            (out / source.name).write_text(source.read_bytes().decode('utf-16').replace('\r\n', '\n'))
        else:
            (out / source.name).write_bytes(vault.encrypt(source.read_bytes(), secret))
        stored.append(source.name)
    password = (work / 'ca-backup-password').read_text().strip()
    (out / 'password.yml').write_bytes(vault.encrypt(('windows_ca_backup_password: "%s"\n' % password).encode(), secret))
    print('stored: ' + ', '.join(stored + ['password.yml']))


README = """\
# State of the Windows domain

Written by `make windows-capture` and `make windows-ca-backup` in LINDS-Ansible.
Do not edit by hand: capture again and read the diff.

| Folder | What |
| --- | --- |
| `domain/` | The domain, sites, OUs with their GPO links, groups, users, computers, service accounts, who is privileged, delegation |
| `gpo/` | Every Group Policy object: `report.xml` (settings), `gpo.yml` (versions, permissions), `backup/` (restorable with `Import-GPO`) |
| `dns/` | Zones and the records somebody created |
| `ca/` | The CA's settings, certificate templates and trust stores; `backup/` holds the CA key and database, encrypted with the Ansible vault |
| `hosts/` | Per server: features, shares and permissions, services, scheduled tasks, software, security settings |

Everything outside `ca/backup/` is plain text and describes users, permissions
and weaknesses. Everything in `ca/backup/` except the `.reg` file is only as
safe as the vault password.
"""


def verify_ca_backup(state, vault_password_file):
    """Prove the stored backup opens and holds the CA's private key. Prints no secret."""
    from ansible.parsing.vault import VaultLib, VaultSecret
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.serialization import pkcs12
    secret = VaultSecret(pathlib.Path(vault_password_file).read_bytes().strip())
    vault = VaultLib([('default', secret)])
    out = state / 'ca' / 'backup'
    password = yaml.safe_load(vault.decrypt((out / 'password.yml').read_bytes()))['windows_ca_backup_password']
    for path in sorted(out.glob('*.p12')):
        key, cert, extra = pkcs12.load_key_and_certificates(vault.decrypt(path.read_bytes()), password.encode())
        if key is None or cert is None:
            sys.exit('%s holds no private key or no certificate' % path.name)
        matches = key.public_key().public_numbers() == cert.public_key().public_numbers()
        print('%s: %s, private key %d bits, key matches certificate: %s, thumbprint %s, valid to %s' % (
            path.name, cert.subject.rfc4514_string(), key.key_size, matches,
            cert.fingerprint(hashes.SHA1()).hex().upper(), cert.not_valid_after_utc.date()))
        if not matches:
            sys.exit('the key in %s does not belong to its certificate' % path.name)


def main():
    command, work, state = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    if not (state / 'README.md').exists():
        state.mkdir(parents=True, exist_ok=True)
        (state / 'README.md').write_text(README)
    if command == 'verify-ca-backup':
        verify_ca_backup(state, sys.argv[4])
        return
    if command == 'write':
        write_domain(work, state)
        write_gpos(work, state)
        write_dns(work, state)
        write_ca(work, state)
        write_hosts(work, state)
    elif command == 'ca-backup':
        ca_backup(work, state, sys.argv[4])
    else:
        sys.exit('unknown command %s' % command)


if __name__ == '__main__':
    main()

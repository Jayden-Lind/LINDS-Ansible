"""Tests for files/usr/local/sbin/storage-health-exporter.

    python3 -m unittest discover -s roles/storage_health/tests

Every tool's output below is cut down from what jd-proxmox-02 (ZFS behind an
HBA) and linds-proxmox-01 (PERC H730, LVM thin) printed on 2026-10-11, so the
key names and odd values are the real ones.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, '..', 'files', 'usr', 'local', 'sbin', 'storage-health-exporter')

_loader = importlib.machinery.SourceFileLoader('storage_health_exporter', SCRIPT)
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
exporter = importlib.util.module_from_spec(_spec)
_loader.exec_module(exporter)


class FakeHost:
    """Stands in for run(): answers a command with whatever was registered for
    the longest matching prefix, and "not installed" for everything else."""

    def __init__(self, answers):
        self.answers = {k: v if isinstance(v, str) else json.dumps(v) for k, v in answers.items()}

    def __call__(self, argv, timeout=60):
        command = ' '.join(argv)
        for prefix in sorted(self.answers, key=len, reverse=True):
            if command.startswith(prefix):
                return 0, self.answers[prefix]
        return None, ''


def samples(metrics):
    """{(name, (label, value) pairs): value} for everything that was recorded."""
    found = {}
    for name, (_, rows) in metrics._families.items():
        for labels, value in rows:
            found[(name, tuple(sorted(labels.items())))] = value
    return found


def value(metrics, name, /, **labels):
    """The value of the one sample of `name` whose labels include `labels`."""
    hits = [v for (n, pairs), v in samples(metrics).items()
            if n == name and set(labels.items()) <= set(pairs)]
    if len(hits) != 1:
        raise AssertionError('%s%r: %d samples' % (name, labels, len(hits)))
    return hits[0]


def has(metrics, name, /, **labels):
    return any(n == name and set(labels.items()) <= set(pairs) for (n, pairs) in samples(metrics))


def config(**overrides):
    return dict(exporter.CONFIG_DEFAULTS, **overrides)


def attribute(attr_id, name, raw, when_failed=''):
    return {'id': attr_id, 'name': name, 'value': 100, 'worst': 100, 'thresh': 10,
            'when_failed': when_failed, 'raw': {'value': raw, 'string': str(raw)}}


def statistic(name, number, valid=True):
    return {'name': name, 'value': number, 'flags': {'valid': valid}}


def ata_test(kind, status, hours):
    return {'type': {'value': kind}, 'status': {'value': status}, 'lifetime_hours': hours}


SAMSUNG = {
    'device': {'name': '/dev/sde', 'type': 'sat', 'protocol': 'ATA'},
    'model_name': 'Samsung SSD 870 EVO 2TB', 'serial_number': 'S5Y3NF0RA03724J',
    'firmware_version': 'SVT02B6Q', 'rotation_rate': 0, 'logical_block_size': 512,
    'smart_status': {'passed': True},
    'power_on_time': {'hours': 41744}, 'temperature': {'current': 32},
    'endurance_used': {'current_percent': 20},
    'spare_available': {'current_percent': 49, 'threshold_percent': 10},
    'ata_smart_attributes': {'table': [
        attribute(5, 'Reallocated_Sector_Ct', 1231),
        attribute(177, 'Wear_Leveling_Count', 469),
        attribute(187, 'Uncorrectable_Error_Cnt', 171599),
        attribute(199, 'CRC_Error_Count', 0),
        attribute(241, 'Total_LBAs_Written', 259842305699),
    ]},
    'ata_device_statistics': {'pages': [{'table': [
        statistic('Logical Sectors Written', 259842305699),
        statistic('Number of Reported Uncorrectable Errors', 171599),
    ]}]},
    'ata_smart_data': {'self_test': {'status': {'value': 0}}},
    'ata_smart_self_test_log': {'extended': {'count': 0}},
}

# HP-branded Intel: no attribute 187, 197, 198, 199 or 241 at all.
VK0600 = {
    'device': {'name': '/dev/sdd', 'type': 'sat', 'protocol': 'ATA'},
    'model_name': 'VK0600GDUTQ', 'serial_number': 'PHWL5456008E600TGN',
    'firmware_version': '4IWVHPG1', 'rotation_rate': 0, 'logical_block_size': 512,
    'smart_status': {'passed': True}, 'power_on_time': {'hours': 64224},
    'ata_smart_attributes': {'table': [attribute(5, 'Reallocated_Sector_Ct', 0)]},
    'ata_device_statistics': {'pages': [{'table': [
        statistic('Logical Sectors Written', 335184480133),
        statistic('Number of Reported Uncorrectable Errors', 0),
        statistic('Number of Interface CRC Errors', 3),
        statistic('Number of Reallocated Logical Sectors', 99, valid=False),
    ]}]},
    'ata_smart_self_test_log': {'extended': {'table': [ata_test(1, 0, 64224)]}},
}

SAS = {
    'device': {'name': '/dev/bus/4', 'type': 'megaraid,0', 'protocol': 'SCSI'},
    'scsi_model_name': 'HGST HUS724040ALS640', 'model_name': 'HGST HUS724040ALS640',
    'serial_number': 'PAJZ0JBX', 'scsi_revision': 'A1C4', 'rotation_rate': 7200,
    'smart_status': {'passed': True}, 'power_on_time': {'hours': 42123, 'minutes': 12},
    'temperature': {'current': 39}, 'scsi_grown_defect_list': 1,
    'scsi_error_counter_log': {
        'read': {'total_uncorrected_errors': 0, 'gigabytes_processed': '293093.532'},
        'write': {'total_uncorrected_errors': 2, 'gigabytes_processed': '120074.436'},
        'verify': {'total_uncorrected_errors': 1, 'gigabytes_processed': '0.000'}},
    'scsi_self_test_0': {'code': {'value': 1, 'string': 'Background short'},
                         'result': {'value': 0, 'string': 'Completed'},
                         'power_on_time': {'hours': 42123}},
}

NVME = {
    'device': {'name': '/dev/nvme0', 'type': 'nvme', 'protocol': 'NVMe'},
    'model_name': 'KXG50ZNV512G TOSHIBA', 'serial_number': '19EA24YMK5YS',
    'firmware_version': 'AAHA4102', 'smart_status': {'passed': True},
    'power_on_time': {'hours': 20824}, 'temperature': {'current': 41},
    'endurance_used': {'current_percent': 25},
    'spare_available': {'current_percent': 100, 'threshold_percent': 5},
    'nvme_smart_health_information_log': {'critical_warning': 0, 'media_errors': 0,
                                          'data_units_written': 87419673},
    'nvme_self_test_log': {
        'current_self_test_operation': {'value': 0},
        'table': [{'self_test_code': {'value': 1}, 'self_test_result': {'value': 0},
                   'power_on_hours': 7673}]},
}

# What `smartctl -d scsi` says about one of the PERC's virtual disks.
PERC_VIRTUAL_DISK = {
    'smartctl': {'exit_status': 4},
    'device': {'name': '/dev/sda', 'type': 'scsi', 'protocol': 'SCSI'},
    'model_name': 'DELL PERC H730 Adp', 'smart_support': {'available': False},
}


def smart_metrics(*drives, **answers):
    scan = {'devices': [d['device'] for d in drives]}
    host = {'smartctl --scan-open -j': scan}
    for drive in drives:
        dev = drive['device']
        host['smartctl -j -x -n standby -d %s %s' % (dev['type'], dev['name'])] = drive
    host.update(answers)
    m = exporter.Metrics()
    exporter.collect_smart(m, FakeHost(host), config())
    return m


class MetricsTest(unittest.TestCase):
    def test_render_groups_samples_under_one_header(self):
        m = exporter.Metrics()
        m.add('a_total', 'First.', 1, pool='VM')
        m.add('b_total', 'Second.', True)
        m.add('a_total', 'First.', 2.5, pool='NAS-SSD')
        self.assertEqual(m.render().splitlines(), [
            '# HELP a_total First.', '# TYPE a_total gauge',
            'a_total{pool="VM"} 1', 'a_total{pool="NAS-SSD"} 2.5',
            '# HELP b_total Second.', '# TYPE b_total gauge', 'b_total 1'])

    def test_unknown_values_are_left_out(self):
        m = exporter.Metrics()
        m.add('a', 'x', None, pool='VM')
        self.assertEqual(m.render(), '\n')

    def test_label_values_are_escaped_and_a_label_may_be_called_name(self):
        m = exporter.Metrics()
        m.add('a', 'x', 1, name='say "hi"\\\n')
        self.assertIn('a{name="say \\"hi\\"\\\\\\n"} 1', m.render())


class HoursSinceTest(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(exporter._hours_since(41744, 41000, 65536), 744)

    def test_hour_stamp_that_wrapped(self):
        # Drive at 66000 hours, tested at hour 65600, which the log stores as 64.
        self.assertEqual(exporter._hours_since(66000, 64, 65536), 400)

    def test_wd_blue_whose_two_clocks_disagree(self):
        # linds-proxmox-01 bay 4: reports 0 power-on hours and a test at 1633.
        self.assertIsNone(exporter._hours_since(0, 1633, 65536))

    def test_unknown(self):
        self.assertIsNone(exporter._hours_since(None, 5, None))
        self.assertIsNone(exporter._hours_since(5, None, None))


class SmartTest(unittest.TestCase):
    def test_ata_counters_come_from_the_attribute_table(self):
        m = smart_metrics(SAMSUNG)
        labels = {'device': 'sde', 'serial': 'S5Y3NF0RA03724J', 'model': 'Samsung SSD 870 EVO 2TB'}
        self.assertEqual(value(m, 'storage_smart_healthy', **labels), 1)
        self.assertEqual(value(m, 'storage_smart_reallocated_sectors', **labels), 1231)
        self.assertEqual(value(m, 'storage_smart_uncorrectable_errors', **labels), 171599)
        self.assertEqual(value(m, 'storage_smart_crc_errors', **labels), 0)
        self.assertEqual(value(m, 'storage_smart_attributes_failing', **labels), 0)
        self.assertEqual(value(m, 'storage_smart_endurance_used_ratio', **labels), 0.2)
        self.assertEqual(value(m, 'storage_smart_spare_available_ratio', **labels), 0.49)
        self.assertEqual(value(m, 'storage_smart_spare_threshold_ratio', **labels), 0.1)
        self.assertEqual(value(m, 'storage_smart_wear_leveling_cycles', **labels), 469)
        self.assertEqual(value(m, 'storage_smart_written_bytes', **labels), 259842305699 * 512)
        self.assertEqual(value(m, 'storage_smart_temperature_celsius', **labels), 32)
        self.assertEqual(value(m, 'storage_smart_device_info', media='ssd', protocol='ATA',
                               firmware='SVT02B6Q', **labels), 1)
        self.assertFalse(has(m, 'storage_smart_pending_sectors'))

    def test_a_failing_attribute_is_counted(self):
        drive = json.loads(json.dumps(SAMSUNG))
        drive['ata_smart_attributes']['table'][0]['when_failed'] = 'now'
        drive['ata_smart_attributes']['table'][1]['when_failed'] = 'past'
        drive['smart_status']['passed'] = False
        m = smart_metrics(drive)
        self.assertEqual(value(m, 'storage_smart_attributes_failing'), 1)
        self.assertEqual(value(m, 'storage_smart_healthy'), 0)

    def test_device_statistics_stand_in_for_missing_attributes(self):
        m = smart_metrics(VK0600)
        self.assertEqual(value(m, 'storage_smart_uncorrectable_errors'), 0)
        self.assertEqual(value(m, 'storage_smart_crc_errors'), 3)
        self.assertEqual(value(m, 'storage_smart_written_bytes'), 335184480133 * 512)
        # Attribute 5 is there, so the statistic (invalid anyway) is not asked.
        self.assertEqual(value(m, 'storage_smart_reallocated_sectors'), 0)

    def test_a_drive_never_long_tested_is_as_overdue_as_it_is_old(self):
        m = smart_metrics(SAMSUNG)
        self.assertEqual(value(m, 'storage_smart_selftest_long_age_seconds'), 41744 * 3600)
        self.assertFalse(has(m, 'storage_smart_selftest_last_passed'))

    def test_a_short_test_gives_a_verdict_but_is_not_a_long_test(self):
        m = smart_metrics(VK0600)
        self.assertEqual(value(m, 'storage_smart_selftest_last_passed'), 1)
        self.assertEqual(value(m, 'storage_smart_selftest_long_age_seconds'), 64224 * 3600)

    def test_long_test_age_and_a_failure(self):
        drive = dict(SAMSUNG, ata_smart_self_test_log={'extended': {'table': [
            ata_test(2, 0x10, 41740),       # aborted by host: proves nothing
            ata_test(0x82, 0x70, 41700),    # extended captive, read failure
            ata_test(2, 0x00, 41000),
        ]}})
        m = smart_metrics(drive)
        self.assertEqual(value(m, 'storage_smart_selftest_last_passed'), 0)
        self.assertEqual(value(m, 'storage_smart_selftest_long_age_seconds'), 44 * 3600)

    def test_a_test_in_progress(self):
        drive = dict(SAMSUNG, ata_smart_data={'self_test': {'status': {'value': 0xf9}}})
        self.assertEqual(value(smart_metrics(drive), 'storage_smart_selftest_in_progress'), 1)
        self.assertEqual(value(smart_metrics(SAMSUNG), 'storage_smart_selftest_in_progress'), 0)

    def test_sas_drive_behind_megaraid(self):
        m = smart_metrics(SAS)
        labels = {'device': 'megaraid,0', 'serial': 'PAJZ0JBX'}
        self.assertEqual(value(m, 'storage_smart_reallocated_sectors', **labels), 1)
        self.assertEqual(value(m, 'storage_smart_uncorrectable_errors', **labels), 3)
        self.assertEqual(value(m, 'storage_smart_written_bytes', **labels), 120074436000000)
        self.assertEqual(value(m, 'storage_smart_selftest_last_passed', **labels), 1)
        self.assertEqual(value(m, 'storage_smart_selftest_long_age_seconds', **labels),
                         42123 * 3600)
        self.assertEqual(value(m, 'storage_smart_device_info', media='hdd', firmware='A1C4',
                               **labels), 1)

    def test_sata_drive_behind_megaraid_is_labelled_by_its_bay(self):
        drive = dict(SAMSUNG, device={'name': '/dev/bus/4', 'type': 'sat+megaraid,5',
                                      'protocol': 'ATA'})
        self.assertTrue(has(smart_metrics(drive), 'storage_smart_healthy', device='megaraid,5'))

    def test_nvme(self):
        m = smart_metrics(NVME)
        labels = {'device': 'nvme0'}
        self.assertEqual(value(m, 'storage_smart_nvme_critical_warning', **labels), 0)
        self.assertEqual(value(m, 'storage_smart_uncorrectable_errors', **labels), 0)
        self.assertEqual(value(m, 'storage_smart_written_bytes', **labels), 87419673 * 512000)
        self.assertEqual(value(m, 'storage_smart_selftest_last_passed', **labels), 1)
        self.assertEqual(value(m, 'storage_smart_selftest_long_age_seconds', **labels),
                         20824 * 3600)
        self.assertEqual(value(m, 'storage_smart_device_info', media='nvme', **labels), 1)

    def test_raid_virtual_disks_are_skipped_and_silent_drives_are_reported(self):
        silent = {'device': {'name': '/dev/sdq', 'type': 'sat', 'protocol': 'ATA'}}
        asleep = {'device': {'name': '/dev/sdr', 'type': 'sat', 'protocol': 'ATA'},
                  'power_mode': {'ata_value': 0, 'name': 'STANDBY'}}
        m = smart_metrics(PERC_VIRTUAL_DISK, SAMSUNG, silent, asleep,
                          **{'smartctl -j -x -n standby -d sat /dev/sdq': 'no json here'})
        self.assertEqual(value(m, 'storage_smart_devices'), 1)
        self.assertEqual(value(m, 'storage_smart_read_success', device='sde'), 1)
        self.assertEqual(value(m, 'storage_smart_read_success', device='sdq'), 0)
        self.assertFalse(has(m, 'storage_smart_read_success', device='sda'))
        self.assertFalse(has(m, 'storage_smart_read_success', device='sdr'))
        self.assertEqual(value(m, 'storage_smart_selftest_long_max_age_seconds'), 45 * 86400)


def pool(state='ONLINE', errors=0, scan=None, vdevs=None):
    return {'state': state, 'error_count': errors, 'scan_stats': scan or {},
            'vdevs': vdevs or {}}


def scrub(state, start, end):
    return {'function': 'SCRUB', 'state': state, 'start_time': start, 'end_time': end}


def zfs_metrics(pools, cfg=None, state=None):
    host = FakeHost({
        'zpool status': {'pools': pools},
        'zpool list': {'pools': {name: {'properties': {'size': {'value': 1000},
                                                       'allocated': {'value': 380}}}
                                 for name in pools}},
        'zfs get': ''.join('%s\t1755687131\n' % name for name in pools),
    })
    m = exporter.Metrics()
    applies = exporter.collect_zfs(m, host, cfg or config(), state or exporter.State(None))
    return m, applies


class ZfsTest(unittest.TestCase):
    def test_pool_and_device_state_and_errors(self):
        vdevs = {
            'NAS-SSD': {'name': 'NAS-SSD', 'vdev_type': 'root', 'state': 'ONLINE'},
            'raidz1-0': {'name': 'raidz1-0', 'vdev_type': 'raidz', 'state': 'DEGRADED',
                         'read_errors': 0, 'write_errors': 0, 'checksum_errors': 0},
            'ata-A': {'name': 'ata-A', 'vdev_type': 'disk', 'state': 'FAULTED',
                      'read_errors': 3, 'write_errors': 0, 'checksum_errors': 8},
        }
        m, applies = zfs_metrics({'NAS-SSD': pool('DEGRADED', 4, vdevs=vdevs)})
        self.assertTrue(applies)
        self.assertEqual(value(m, 'storage_zfs_pool_state', pool='NAS-SSD', state='DEGRADED'), 1)
        self.assertEqual(value(m, 'storage_zfs_pool_data_errors', pool='NAS-SSD'), 4)
        self.assertEqual(value(m, 'storage_zfs_vdev_state', vdev='ata-A', state='FAULTED',
                               type='disk'), 1)
        self.assertEqual(value(m, 'storage_zfs_vdev_errors', vdev='ata-A', kind='checksum'), 8)
        self.assertEqual(value(m, 'storage_zfs_vdev_errors', vdev='ata-A', kind='read'), 3)
        self.assertFalse(has(m, 'storage_zfs_vdev_state', type='root'))
        self.assertEqual(value(m, 'storage_zfs_pool_size_bytes'), 1000)
        self.assertEqual(value(m, 'storage_zfs_pool_allocated_bytes'), 380)
        self.assertEqual(value(m, 'storage_zfs_pool_created_timestamp_seconds'), 1755687131)

    def test_expected_pools_are_named_even_when_nothing_imported(self):
        cfg = config(zfs_pools={'VM': {'scrub_max_age_days': 9}})
        m, applies = zfs_metrics({}, cfg)
        self.assertTrue(applies)
        self.assertEqual(value(m, 'storage_zfs_pool_expected', pool='VM'), 1)
        self.assertFalse(has(m, 'storage_zfs_pool_state'))

    def test_a_host_without_pools_has_nothing_to_say(self):
        m, applies = zfs_metrics({})
        self.assertFalse(applies)
        self.assertEqual(samples(m), {})

    def test_scrub_age_limit_is_per_pool(self):
        cfg = config(zfs_pools={'VM': {'scrub_max_age_days': 9}, 'NAS-SSD': {}})
        m, _ = zfs_metrics({'VM': pool(), 'NAS-SSD': pool(), 'scratch': pool()}, cfg)
        self.assertEqual(value(m, 'storage_zfs_scrub_max_age_seconds', pool='VM'), 9 * 86400)
        self.assertEqual(value(m, 'storage_zfs_scrub_max_age_seconds', pool='NAS-SSD'), 40 * 86400)
        self.assertEqual(value(m, 'storage_zfs_scrub_max_age_seconds', pool='scratch'), 40 * 86400)

    def test_last_finished_scrub_is_remembered_through_the_next_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'state.json')
            state = exporter.State(path)
            m, _ = zfs_metrics({'VM': pool(scan=scrub('FINISHED', 100, 900))}, state=state)
            self.assertEqual(value(m, 'storage_zfs_scrub_last_end_timestamp_seconds'), 900)
            self.assertEqual(value(m, 'storage_zfs_scrub_last_start_timestamp_seconds'), 100)
            self.assertEqual(value(m, 'storage_zfs_scrub_in_progress'), 0)
            state.save()

            for later in (scrub('SCANNING', 5000, 0), scrub('CANCELED', 5000, 5100),
                          {'function': 'RESILVER', 'state': 'FINISHED', 'end_time': 7000}):
                m, _ = zfs_metrics({'VM': pool(scan=later)}, state=exporter.State(path))
                self.assertEqual(value(m, 'storage_zfs_scrub_last_end_timestamp_seconds'), 900)
            m, _ = zfs_metrics({'VM': pool(scan=scrub('SCANNING', 5000, 0))},
                               state=exporter.State(path))
            self.assertEqual(value(m, 'storage_zfs_scrub_in_progress'), 1)
            self.assertEqual(value(m, 'storage_zfs_scrub_last_start_timestamp_seconds'), 5000)

    def test_a_pool_never_seen_to_finish_a_scrub_reports_no_end(self):
        m, _ = zfs_metrics({'VM': pool(scan=scrub('SCANNING', 5000, 0))})
        self.assertFalse(has(m, 'storage_zfs_scrub_last_end_timestamp_seconds'))
        m, _ = zfs_metrics({'VM': pool(scan={'function': 'RESILVER', 'state': 'FINISHED',
                                              'start_time': 6000, 'end_time': 7000})})
        self.assertFalse(has(m, 'storage_zfs_scrub_last_start_timestamp_seconds'))


def perc(answer):
    return {'Controllers': [{'Command Status': {'Controller': 0, 'Status': 'Success'},
                             'Response Data': answer}]}


def properties(**props):
    return {'Controller Properties': [{'Ctrl_Prop': k.replace('_', ' '), 'Value': v}
                                      for k, v in props.items()]}


def raid_metrics(patrol_read=None, consistency=None, **answers):
    host = {
        'perccli /call show all': perc({
            'Basics': {'Model': 'PERC H730 Adapter'},
            'Status': {'Controller Status': 'Optimal'},
            'BBU_Info': [{'Model': 'BBU', 'State': 'Optimal'}],
            'VD LIST': [
                {'DG/VD': '0/0', 'TYPE': 'RAID5', 'State': 'Optl', 'Name': 'NAS'},
                {'DG/VD': '1/1', 'TYPE': 'RAID1', 'State': 'Dgrd', 'Name': 'OS'},
                {'DG/VD': '2/3', 'TYPE': 'RAID5', 'State': 'Optl', 'Name': 'RAID-5'}],
            'PD LIST': [
                {'EID:Slt': '32:0', 'DG': 0, 'Med': 'HDD'},
                {'EID:Slt': '32:4', 'DG': '-', 'Med': 'SSD'},
                {'EID:Slt': '32:5', 'DG': 1, 'Med': 'SSD'},
                {'EID:Slt': '32:7', 'DG': 2, 'Med': 'HDD'}]}),
        'perccli /call show patrolread': perc(patrol_read or properties(
            PR_Mode='Auto', PR_iterations_completed='507', PR_on_SSD='OnlyMixed',
            PR_Excluded_VDs='1')),
        'perccli /call show cc': perc(consistency or properties(
            CC_Operation_Mode='Sequential', CC_Number_of_iterations='1',
            CC_Excluded_VDs='0,3')),
        'perccli /call/vall show bbmt': perc([
            {'VD': 0, 'Name': 'NAS', 'Corrected entries': 0, 'Un-Corrected entries': 0},
            {'VD': 1, 'Name': 'OS', 'Corrected entries': 78, 'Un-Corrected entries': 1011}]),
        'perccli /call/eall/sall show all': perc({
            'Drive /c0/e32/s5': [{'EID:Slt': '32:5', 'State': 'Onln', 'Model': 'Samsung '}],
            'Drive /c0/e32/s5 - Detailed Information': {
                'Drive /c0/e32/s5 State': {
                    'Media Error Count': 7734, 'Other Error Count': 6,
                    'Predictive Failure Count': 0, 'S.M.A.R.T alert flagged by drive': 'No'},
                'Drive /c0/e32/s5 Device attributes': {
                    'SN': 'S74ZNL0X502776K     ', 'Model Number': 'Samsung SSD 870 EVO 1TB'}},
            'Drive /c0/e32/s6': [{'EID:Slt': '32:6', 'State': 'Rbld', 'Model': 'Samsung '}],
            'Drive /c0/e32/s6 - Detailed Information': {}}),
    }
    host.update(answers)
    m = exporter.Metrics()
    applies = exporter.collect_raid(m, FakeHost(host), config())
    return m, applies


class RaidTest(unittest.TestCase):
    def test_controller_virtual_disks_and_battery(self):
        m, applies = raid_metrics()
        self.assertTrue(applies)
        self.assertEqual(value(m, 'storage_raid_controller_state', state='Optimal',
                               controller='0', model='PERC H730 Adapter'), 1)
        self.assertEqual(value(m, 'storage_raid_battery_state', state='Optimal'), 1)
        self.assertEqual(value(m, 'storage_raid_vd_state', vd='1', name='OS', raid='RAID1',
                               state='Dgrd'), 1)
        self.assertEqual(value(m, 'storage_raid_vd_bad_blocks', vd='1', kind='uncorrected'), 1011)
        self.assertEqual(value(m, 'storage_raid_vd_bad_blocks', vd='1', kind='corrected'), 78)
        self.assertEqual(value(m, 'storage_raid_patrol_read_iterations'), 507)
        self.assertEqual(value(m, 'storage_raid_consistency_check_iterations'), 1)

    def test_physical_disks(self):
        m, _ = raid_metrics()
        labels = {'slot': '32:5', 'serial': 'S74ZNL0X502776K', 'model': 'Samsung SSD 870 EVO 1TB'}
        self.assertEqual(value(m, 'storage_raid_pd_state', state='Onln', **labels), 1)
        self.assertEqual(value(m, 'storage_raid_pd_media_errors', **labels), 7734)
        self.assertEqual(value(m, 'storage_raid_pd_other_errors', **labels), 6)
        self.assertEqual(value(m, 'storage_raid_pd_predictive_failures', **labels), 0)
        self.assertEqual(value(m, 'storage_raid_pd_smart_alert', **labels), 0)
        self.assertEqual(value(m, 'storage_raid_pd_state', slot='32:6', state='Rbld'), 1)
        self.assertFalse(has(m, 'storage_raid_pd_media_errors', slot='32:6'))

    def test_each_virtual_disk_is_patrolled_one_way_or_the_other(self):
        m, _ = raid_metrics()
        scheduled = {vd: (value(m, 'storage_raid_vd_patrol_read_scheduled', vd=vd),
                          value(m, 'storage_raid_vd_consistency_check_scheduled', vd=vd))
                     for vd in '013'}
        self.assertEqual(scheduled, {'0': (1, 0), '1': (0, 1), '3': (1, 0)})

    def test_what_the_controller_was_doing_until_2026_10_10(self):
        # Patrol read "on" but excluding every virtual disk, no consistency check.
        m, _ = raid_metrics(
            patrol_read=properties(PR_Mode='Auto', PR_on_SSD='OnlyMixed', PR_Excluded_VDs='0,1,3'),
            consistency=properties(CC_Operation_Mode='Disabled', CC_Excluded_VDs='None'))
        for vd in '013':
            self.assertEqual(value(m, 'storage_raid_vd_patrol_read_scheduled', vd=vd), 0)
            self.assertEqual(value(m, 'storage_raid_vd_consistency_check_scheduled', vd=vd), 0)

    def test_patrol_read_skips_an_all_ssd_array_unless_told_to_read_ssds(self):
        nothing_excluded = dict(PR_Mode='Auto', PR_Excluded_VDs='None')
        m, _ = raid_metrics(patrol_read=properties(PR_on_SSD='OnlyMixed', **nothing_excluded))
        self.assertEqual(value(m, 'storage_raid_vd_patrol_read_scheduled', vd='1'), 0)
        self.assertEqual(value(m, 'storage_raid_vd_patrol_read_scheduled', vd='0'), 1)
        m, _ = raid_metrics(patrol_read=properties(PR_on_SSD='Enabled', **nothing_excluded))
        self.assertEqual(value(m, 'storage_raid_vd_patrol_read_scheduled', vd='1'), 1)
        m, _ = raid_metrics(patrol_read=properties(PR_Mode='Manual', PR_Excluded_VDs='None'))
        self.assertEqual(value(m, 'storage_raid_vd_patrol_read_scheduled', vd='0'), 0)

    def test_number_lists(self):
        self.assertEqual(exporter._number_list('0,3'), {0, 3})
        self.assertEqual(exporter._number_list('0-2,5'), {0, 1, 2, 5})
        self.assertEqual(exporter._number_list('None'), set())
        self.assertEqual(exporter._number_list(None), set())

    def test_no_cli_or_no_controller_means_nothing_to_say(self):
        m = exporter.Metrics()
        self.assertFalse(exporter.collect_raid(m, FakeHost({}), config()))
        failure = {'Controllers': [{'Command Status': {'Status': 'Failure'}}]}
        self.assertFalse(exporter.collect_raid(
            m, FakeHost({'perccli /call show all': failure}), config()))
        self.assertEqual(samples(m), {})

    def test_unless_the_host_is_meant_to_have_one(self):
        with self.assertRaises(exporter.CollectorError):
            exporter.collect_raid(exporter.Metrics(), FakeHost({}), config(raid_expected=True))


class LvmTest(unittest.TestCase):
    REPORT = {'report': [{'lv': [
        {'lv_name': 'NAS', 'vg_name': 'NAS', 'lv_attr': 'twi-aotz--',
         'lv_size': '11966571610112', 'data_percent': '52.25', 'metadata_percent': '11.48',
         'lv_health_status': ''},
        {'lv_name': 'vm-102-disk-0', 'vg_name': 'NAS', 'lv_attr': 'Vwi-aotz--',
         'lv_size': '11995116208128', 'data_percent': '52.12', 'metadata_percent': '',
         'lv_health_status': ''},
        {'lv_name': 'data', 'vg_name': 'pve', 'lv_attr': 'twi-aotzD-',
         'lv_size': '879507832832', 'data_percent': '100.00', 'metadata_percent': '5.09',
         'lv_health_status': 'out_of_data'},
        {'lv_name': 'root', 'vg_name': 'pve', 'lv_attr': '-wi-ao----', 'lv_size': '1',
         'data_percent': '', 'metadata_percent': '', 'lv_health_status': ''}]}]}

    def test_thin_pools_only(self):
        m = exporter.Metrics()
        self.assertTrue(exporter.collect_lvm(m, FakeHost({'lvs': self.REPORT})))
        self.assertEqual(value(m, 'storage_lvm_thin_used_ratio', vg='NAS', lv='NAS',
                               space='data'), 0.5225)
        self.assertEqual(value(m, 'storage_lvm_thin_used_ratio', vg='NAS', space='metadata'),
                         0.1148)
        self.assertEqual(value(m, 'storage_lvm_thin_size_bytes', vg='NAS'), 11966571610112)
        self.assertEqual(value(m, 'storage_lvm_thin_healthy', vg='NAS'), 1)
        self.assertEqual(value(m, 'storage_lvm_thin_used_ratio', vg='pve', space='data'), 1.0)
        self.assertEqual(value(m, 'storage_lvm_thin_healthy', vg='pve'), 0)
        self.assertFalse(has(m, 'storage_lvm_thin_used_ratio', lv='vm-102-disk-0'))

    def test_no_thin_pools(self):
        m = exporter.Metrics()
        only_root = {'report': [{'lv': [self.REPORT['report'][0]['lv'][3]]}]}
        self.assertFalse(exporter.collect_lvm(m, FakeHost({'lvs': only_root})))


class CollectTest(unittest.TestCase):
    def test_a_broken_collector_is_reported_and_the_others_still_run(self):
        host = FakeHost({
            'zpool status': 'cannot open /dev/zfs',
            'lvs': LvmTest.REPORT,
        })
        complaints = io.StringIO()
        with contextlib.redirect_stderr(complaints):
            m = exporter.collect(host, config(), exporter.State(None))
        self.assertIn('storage-health-exporter: zfs: CollectorError', complaints.getvalue())
        self.assertEqual(value(m, 'storage_health_collector_success', collector='zfs'), 0)
        self.assertEqual(value(m, 'storage_health_collector_success', collector='lvm'), 1)
        # smartctl and perccli are not installed on this imaginary host.
        self.assertFalse(has(m, 'storage_health_collector_success', collector='smart'))
        self.assertFalse(has(m, 'storage_health_collector_success', collector='raid'))
        self.assertGreater(value(m, 'storage_health_last_run_timestamp_seconds'), 1700000000)

    def test_main_writes_the_file_whole_and_saves_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = os.path.join(tmp, 'storage_health.prom')
            state = os.path.join(tmp, 'state.json')
            real = exporter.run
            exporter.run = FakeHost({
                'zpool status': {'pools': {'VM': pool(scan=scrub('FINISHED', 100, 900))}},
                'zpool list': {'pools': {}}, 'zfs get': ''})
            try:
                status = exporter.main(['--config', os.path.join(tmp, 'absent.json'),
                                        '--state', state, '--output', output])
            finally:
                exporter.run = real
            self.assertEqual(status, 0)
            self.assertEqual(sorted(os.listdir(tmp)), ['state.json', 'storage_health.prom'])
            with open(output) as f:
                text = f.read()
            self.assertIn('storage_zfs_scrub_last_end_timestamp_seconds{pool="VM"} 900\n', text)
            self.assertEqual(oct(os.stat(output).st_mode & 0o777), '0o644')
            with open(state) as f:
                self.assertEqual(json.load(f), {'zfs_scrub_end/VM': 900})


if __name__ == '__main__':
    unittest.main()

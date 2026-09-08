"""Unit tests for the wan-failover Controller (pure state machine).

    python3 -m unittest discover -s roles/router/tests
"""
import importlib.machinery
import sys
sys.dont_write_bytecode = True
import importlib.util
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_path = os.path.join(HERE, "..", "files", "usr", "local", "sbin", "wan-failover")   # no .py suffix: load explicitly
_loader = importlib.machinery.SourceFileLoader("wan_failover", _path)
wf = importlib.util.module_from_spec(importlib.util.spec_from_loader("wan_failover", _loader))
sys.modules["wan_failover"] = wf   # dataclasses resolve annotations via sys.modules
_loader.exec_module(wf)


def cands():
    return [
        wf.Candidate("backup", "lan0.99", "192.168.0.1", 10, ["192.168.0.1"], onlink=True),
        wf.Candidate("primary", "wan0", "121.221.64.1", 1, ["8.8.8.8", "8.8.4.4"], onlink=True),
    ]


def kinds(actions):
    return [(k, c.name if c else None) for k, c in actions]


class ControllerTests(unittest.TestCase):
    def test_sorted_by_metric_and_bootstrap_installs_immediately(self):
        ctl = wf.Controller(cands(), rise=3, fall=3)
        self.assertEqual([c.name for c in ctl.candidates], ["primary", "backup"])
        a = ctl.step({"primary": [True, True], "backup": [True]})
        self.assertEqual(kinds(a), [("add", "primary"), ("add", "backup")])
        self.assertEqual(ctl.active, "primary")

    def test_first_step_never_flushes(self):
        ctl = wf.Controller(cands())
        a = ctl.step({"primary": [True, True], "backup": [True]})
        self.assertNotIn(("flush", None), kinds(a))

    def test_fall_hysteresis(self):
        ctl = wf.Controller(cands(), rise=3, fall=3)
        ctl.step({"primary": [True, True], "backup": [True]})
        self.assertEqual(kinds(ctl.step({"primary": [False, False], "backup": [True]})), [])
        self.assertEqual(kinds(ctl.step({"primary": [False, False], "backup": [True]})), [])
        a = ctl.step({"primary": [False, False], "backup": [True]})
        self.assertEqual(kinds(a), [("del", "primary"), ("flush", None)])
        self.assertEqual(ctl.active, "backup")

    def test_rise_hysteresis_after_recovery(self):
        ctl = wf.Controller(cands(), rise=3, fall=1)
        ctl.step({"primary": [True, True], "backup": [True]})
        ctl.step({"primary": [False, False], "backup": [True]})   # primary withdrawn
        self.assertEqual(kinds(ctl.step({"primary": [True, True], "backup": [True]})), [])
        self.assertEqual(kinds(ctl.step({"primary": [True, True], "backup": [True]})), [])
        a = ctl.step({"primary": [True, True], "backup": [True]})
        self.assertEqual(kinds(a), [("add", "primary"), ("flush", None)])
        self.assertEqual(ctl.active, "primary")

    def test_one_failure_resets_the_rise_count(self):
        ctl = wf.Controller(cands(), rise=3, fall=1)
        ctl.step({"primary": [True, True], "backup": [True]})
        ctl.step({"primary": [False, False], "backup": [True]})
        ctl.step({"primary": [True, True], "backup": [True]})
        ctl.step({"primary": [True, True], "backup": [True]})
        ctl.step({"primary": [False, False], "backup": [True]})   # streak broken
        self.assertEqual(kinds(ctl.step({"primary": [True, True], "backup": [True]})), [])

    def test_carrier_loss_withdraws_immediately(self):
        ctl = wf.Controller(cands(), rise=3, fall=3)
        ctl.step({"primary": [True, True], "backup": [True]})
        a = ctl.step({"primary": None, "backup": [True]})
        self.assertEqual(kinds(a), [("del", "primary"), ("flush", None)])

    def test_no_carrier_is_never_installed(self):
        ctl = wf.Controller(cands())
        a = ctl.step({"primary": None, "backup": None})
        self.assertEqual(kinds(a), [])
        self.assertIsNone(ctl.active)
        self.assertEqual(ctl.up_candidates(), [])

    def test_any_vs_all_policy(self):
        c = wf.Candidate("p", "wan0", "gw", 1, ["a", "b"])
        self.assertTrue(c.healthy([True, False]))
        c.policy = "all-available"
        self.assertFalse(c.healthy([True, False]))
        self.assertTrue(c.healthy([True, True]))
        self.assertFalse(c.healthy([]))

    def test_all_down_then_backup_flushes(self):
        ctl = wf.Controller(cands(), rise=1, fall=1)
        ctl.step({"primary": [True, True], "backup": None})
        a = ctl.step({"primary": [False, False], "backup": None})
        self.assertEqual(kinds(a), [("del", "primary"), ("flush", None)])
        self.assertIsNone(ctl.active)
        a = ctl.step({"primary": [False, False], "backup": [True]})
        self.assertEqual(kinds(a), [("add", "backup"), ("flush", None)])

    def test_flush_can_be_disabled(self):
        ctl = wf.Controller(cands(), rise=1, fall=1, flush_conntrack=False)
        ctl.step({"primary": [True, True], "backup": [True]})
        a = ctl.step({"primary": [False, False], "backup": [True]})
        self.assertEqual(kinds(a), [("del", "primary")])

    def test_from_dict(self):
        c = wf.Candidate.from_dict({"name": "x", "dev": "d", "gateway": "g", "metric": "5", "targets": ["t"], "onlink": True})
        self.assertEqual((c.metric, c.onlink, c.policy), (5, True, "any-available"))


if __name__ == "__main__":
    unittest.main()


class GatewayResolutionTests(unittest.TestCase):
    """Runner.resolve: a candidate may take its gateway from the DHCP lease
    instead of carrying a hardcoded one that goes stale."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        # lo always exists; name the lease after whatever ifindex it has, the
        # way systemd-networkd does.
        with open("/sys/class/net/lo/ifindex") as f:
            self.ifindex = f.read().strip()
        self.runner = wf.Runner(timeout=1)
        self.runner.LEASE_DIR = self.tmp

    def lease(self, body):
        with open(os.path.join(self.tmp, self.ifindex), "w") as f:
            f.write(body)

    def dhcp_candidate(self):
        return wf.Candidate("primary", "lo", None, 1, ["8.8.8.8"], onlink=True)

    def test_from_dict_reads_dhcp_and_literal_gateways(self):
        base = {"name": "p", "dev": "wan0", "metric": 1, "targets": ["8.8.8.8"]}
        self.assertIsNone(wf.Candidate.from_dict({**base, "gateway": "dhcp"}).gateway)
        self.assertIsNone(wf.Candidate.from_dict(base).gateway)   # omitted
        self.assertEqual(wf.Candidate.from_dict({**base, "gateway": "10.0.0.1"}).gateway, "10.0.0.1")

    def test_lease_gateway_parses_router(self):
        self.lease("ADDRESS=1.159.28.218\nROUTER=1.159.127.254\nSERVER_ADDRESS=58.162.26.204\n")
        self.assertEqual(self.runner.lease_gateway("lo"), "1.159.127.254")

    def test_lease_gateway_takes_first_of_several(self):
        self.lease("ROUTER=1.159.127.254 1.159.127.253\n")
        self.assertEqual(self.runner.lease_gateway("lo"), "1.159.127.254")

    def test_lease_gateway_none_when_absent(self):
        self.assertIsNone(self.runner.lease_gateway("lo"))          # no lease file
        self.lease("ADDRESS=1.159.28.218\n")                        # lease, no ROUTER
        self.assertIsNone(self.runner.lease_gateway("lo"))

    def test_static_gateway_wins_and_never_reads_the_lease(self):
        self.lease("ROUTER=1.159.127.254\n")
        c = wf.Candidate("primary", "lo", "10.0.0.1", 1, ["8.8.8.8"])
        self.assertEqual(self.runner.resolve(c), "10.0.0.1")

    def test_resolve_follows_a_changed_lease(self):
        c = self.dhcp_candidate()
        self.lease("ROUTER=1.159.127.254\n")
        self.assertEqual(self.runner.resolve(c), "1.159.127.254")
        self.lease("ROUTER=1.159.127.1\n")
        self.assertEqual(self.runner.resolve(c), "1.159.127.1")

    def test_resolve_keeps_last_known_gateway_while_the_lease_is_rewritten(self):
        c = self.dhcp_candidate()
        self.lease("ROUTER=1.159.127.254\n")
        self.assertEqual(self.runner.resolve(c), "1.159.127.254")
        os.unlink(os.path.join(self.tmp, self.ifindex))
        self.assertEqual(self.runner.resolve(c), "1.159.127.254")

    def test_resolve_none_when_never_seen(self):
        self.assertIsNone(self.runner.resolve(self.dhcp_candidate()))

    def test_delete_matches_regardless_of_gateway(self):
        """The withdraw must not name a gateway: DHCP may have moved it since
        we installed the route, and `ip route del` would then match nothing."""
        c = self.dhcp_candidate()
        self.assertEqual(wf.Runner._route_match(c), ["default", "dev", "lo", "metric", "1"])
        self.assertEqual(wf.Runner._route(c, "1.159.127.254"),
                         ["default", "via", "1.159.127.254", "dev", "lo", "metric", "1", "onlink"])

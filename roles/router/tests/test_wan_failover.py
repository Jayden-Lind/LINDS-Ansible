"""Unit tests for the wan-failover Controller (pure state machine).

    python3 -m unittest discover -s roles/router/tests
"""
import importlib.machinery
import sys
sys.dont_write_bytecode = True
import importlib.util
import os
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

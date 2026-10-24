"""Unit tests for k8s-port-forward (request parsing, checks, nft text, metrics).

    python3 -m unittest discover -s roles/router/tests
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
_path = os.path.join(HERE, "..", "files", "usr", "local", "sbin", "k8s-port-forward")   # no .py suffix: load explicitly
_loader = importlib.machinery.SourceFileLoader("k8s_port_forward", _path)
pf = importlib.util.module_from_spec(importlib.util.spec_from_loader("k8s_port_forward", _loader))
sys.modules["k8s_port_forward"] = pf   # dataclasses resolve annotations via sys.modules
_loader.exec_module(pf)


def cfg(**over):
    c = dict(pf.DEFAULTS)
    c.update(over)
    return c


def svc(name, ports, request=None, ns="default", ip="172.16.1.10", created="2026-01-01T00:00:00Z",
        typ="LoadBalancer", policy="Local"):
    meta = {"name": name, "namespace": ns, "creationTimestamp": created, "annotations": {}}
    if request is not None:
        meta["annotations"][pf.ANNOTATION] = request
    spec = {"type": typ, "externalTrafficPolicy": policy,
            "ports": [{"port": p, "protocol": proto.upper()} for p, proto in ports]}
    status = {"loadBalancer": {"ingress": [{"ip": ip}]}} if ip else {}
    return {"metadata": meta, "spec": spec, "status": status}


class ParsePortsTests(unittest.TestCase):
    def test_single_range_list_and_mapping(self):
        self.assertEqual(pf.parse_ports("443/tcp"), [(443, 443, "tcp")])
        self.assertEqual(pf.parse_ports("2456-2457/udp"), [(2456, 2456, "udp"), (2457, 2457, "udp")])
        self.assertEqual(pf.parse_ports(" 25565/tcp , 25565/UDP "), [(25565, 25565, "tcp"), (25565, 25565, "udp")])
        self.assertEqual(pf.parse_ports("8443:443/tcp"), [(8443, 443, "tcp")])

    def test_bad_values_fail(self):
        for bad in ["", "443", "443/sctp", "0/tcp", "65536/tcp", "2457-2456/udp", "1-65535/udp",
                    "10-20:30/tcp", "80:0/tcp", "abc/tcp", "443/tcp;rm -rf /"]:
            with self.assertRaises(ValueError, msg=bad):
                pf.parse_ports(bad)

    def test_range_limit_is_inclusive(self):
        self.assertEqual(len(pf.parse_ports(f"1000-{1000 + pf.MAX_RANGE - 1}/udp")), pf.MAX_RANGE)


class DesiredTests(unittest.TestCase):
    def test_services_without_the_annotation_are_ignored(self):
        fw, rej = pf.desired([svc("plain", [(80, "tcp")])], cfg())
        self.assertEqual((fw, rej), ([], []))

    def test_forward_to_the_service_address_and_port(self):
        fw, rej = pf.desired([svc("valheim", [(2456, "udp"), (2457, "udp")], "2456-2457/udp")], cfg())
        self.assertEqual(rej, [])
        self.assertEqual([(f.proto, f.wan_port, f.backend_ip, f.backend_port) for f in fw],
                         [("udp", 2456, "172.16.1.10", 2456), ("udp", 2457, "172.16.1.10", 2457)])
        self.assertEqual(fw[0].traffic_policy, "Local")

    def test_wan_port_can_differ_from_the_service_port(self):
        fw, _ = pf.desired([svc("web", [(443, "tcp")], "8443:443/tcp")], cfg())
        self.assertEqual([(f.wan_port, f.backend_port) for f in fw], [(8443, 443)])

    def test_port_or_protocol_the_service_lacks_is_rejected(self):
        fw, rej = pf.desired([svc("web", [(443, "tcp")], "443/udp,444/tcp,443/tcp")], cfg())
        self.assertEqual([(f.proto, f.wan_port) for f in fw], [("tcp", 443)])
        self.assertEqual(sorted(r.request for r in rej), ["443/udp", "444/tcp"])

    def test_reserved_ports_are_refused(self):
        fw, rej = pf.desired([svc("ike", [(500, "udp"), (4500, "udp")], "500/udp,4500/udp")], cfg())
        self.assertEqual(fw, [])
        self.assertTrue(all("reserved" in r.reason for r in rej))

    def test_address_outside_the_pool_is_refused(self):
        fw, rej = pf.desired([svc("odd", [(80, "tcp")], "80/tcp", ip="10.0.50.20")], cfg())
        self.assertEqual(fw, [])
        self.assertIn("outside", rej[0].reason)

    def test_no_address_yet_and_not_a_load_balancer(self):
        _, rej = pf.desired([svc("pending", [(80, "tcp")], "80/tcp", ip=None),
                             svc("cip", [(80, "tcp")], "80/tcp", typ="ClusterIP")], cfg())
        self.assertEqual(sorted(r.reason for r in rej), ["no LoadBalancer address yet", "not a LoadBalancer Service"])

    def test_ipv6_address_is_not_used(self):
        s = svc("dual", [(80, "tcp")], "80/tcp")
        s["status"]["loadBalancer"]["ingress"] = [{"ip": "2001:db8::1"}, {"ip": "172.16.1.30"}]
        fw, _ = pf.desired([s], cfg())
        self.assertEqual(fw[0].backend_ip, "172.16.1.30")

    def test_older_service_keeps_a_contested_port(self):
        new = svc("new", [(443, "tcp")], "443/tcp", ns="b", ip="172.16.1.20", created="2026-06-01T00:00:00Z")
        old = svc("old", [(443, "tcp")], "443/tcp", ns="a", ip="172.16.1.12", created="2026-01-01T00:00:00Z")
        for order in ([new, old], [old, new]):
            fw, rej = pf.desired(order, cfg())
            self.assertEqual([(f.namespace, f.service) for f in fw], [("a", "old")])
            self.assertEqual(rej[0].service, "new")
            self.assertIn("taken by a/old", rej[0].reason)

    def test_same_port_on_two_protocols_is_two_forwards(self):
        fw, rej = pf.desired([svc("mc", [(25565, "tcp"), (25565, "udp")], "25565/tcp,25565/udp")], cfg())
        self.assertEqual(rej, [])
        self.assertEqual(len(fw), 2)

    def test_max_forwards(self):
        fw, rej = pf.desired([svc("many", [(p, "udp") for p in range(3000, 3010)], "3000-3009/udp")],
                             cfg(max_forwards=4))
        self.assertEqual(len(fw), 4)
        self.assertEqual(len(rej), 6)

    def test_bad_annotation_rejects_only_that_service(self):
        fw, rej = pf.desired([svc("bad", [(80, "tcp")], "eighty"),
                              svc("good", [(443, "tcp")], "443/tcp", ip="172.16.1.12")], cfg())
        self.assertEqual([f.service for f in fw], ["good"])
        self.assertEqual([r.service for r in rej], ["bad"])


class RenderTests(unittest.TestCase):
    def test_one_transaction_that_replaces_the_table(self):
        fw, _ = pf.desired([svc("mtls", [(443, "tcp")], "443/tcp", ip="172.16.1.12")], cfg())
        text = pf.render(fw, cfg())
        lines = text.splitlines()
        self.assertEqual(lines[:2], ["table ip k8s_port_forward", "delete table ip k8s_port_forward"])
        self.assertIn("elements = { tcp . 443 : 172.16.1.12 . 443 }", text)
        self.assertIn('iifname "wan0" fib daddr type local dnat ip addr . port to meta l4proto . th dport map @forwards', text)
        self.assertIn("priority dstnat - 10", text)

    def test_empty_map_has_no_elements_line(self):
        self.assertNotIn("elements", pf.render([], cfg()))


class MetricsTests(unittest.TestCase):
    def test_metrics_text(self):
        fw, rej = pf.desired([svc("web", [(443, "tcp")], "443/tcp,80/tcp", ip="172.16.1.12", ns="n")], cfg())
        text = pf.metrics(fw, rej, True, 1700000000, {("tcp", 443): (7, 420)})
        self.assertIn('router_port_forward_info{proto="tcp",port="443",namespace="n",service="web",'
                      'backend="172.16.1.12:443",traffic_policy="Local"} 1', text)
        self.assertIn('router_port_forward_packets_total{proto="tcp",port="443"} 7', text)
        self.assertIn('request="80/tcp",reason="the Service has no 80/tcp"} 1', text)
        self.assertIn("router_port_forward_api_up 1", text)

    def test_label_values_are_escaped(self):
        self.assertEqual(pf._label('a"b\\c\nd'), 'a\\"b\\\\c d')


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.cfg = cfg(state_file=os.path.join(self.dir, "state.json"),
                       metrics_file=os.path.join(self.dir, "m.prom"))
        self.runner = pf.Runner(self.cfg)
        self.loaded = []
        self.runner.apply = lambda forwards: self.loaded.append(list(forwards))
        self.runner.counters = lambda: {}
        self.runner.table_present = lambda: True

    def test_api_failure_keeps_the_table(self):
        self.runner.list_services = lambda: [svc("web", [(443, "tcp")], "443/tcp", ip="172.16.1.12")]
        self.runner.step()
        self.assertEqual(len(self.loaded), 1)

        def boom():
            raise OSError("connection refused")
        self.runner.list_services = boom
        self.runner.step()
        self.assertEqual(len(self.loaded), 1)   # nothing reloaded
        self.assertEqual(len(self.runner.applied), 1)
        with open(self.cfg["metrics_file"]) as fh:
            self.assertIn("router_port_forward_api_up 0", fh.read())

    def test_no_reload_when_nothing_changed(self):
        self.runner.list_services = lambda: [svc("web", [(443, "tcp")], "443/tcp", ip="172.16.1.12")]
        self.runner.step()
        self.runner.step()
        self.assertEqual(len(self.loaded), 1)

    def test_state_survives_a_restart(self):
        self.runner.list_services = lambda: [svc("web", [(443, "tcp")], "443/tcp", ip="172.16.1.12")]
        self.runner.step()
        second = pf.Runner(self.cfg)
        loaded = []
        second.apply = lambda forwards: loaded.append(list(forwards))
        second.start()
        self.assertEqual(loaded, [self.runner.applied])
        with open(self.cfg["state_file"]) as fh:
            self.assertEqual(json.load(fh)["forwards"][0]["backend_ip"], "172.16.1.12")

    def test_flushed_table_is_loaded_again_even_without_the_api(self):
        self.runner.list_services = lambda: [svc("web", [(443, "tcp")], "443/tcp", ip="172.16.1.12")]
        self.runner.step()

        def boom():
            raise OSError("connection refused")
        self.runner.list_services = boom
        self.runner.table_present = lambda: False
        self.runner.step()
        self.assertEqual(len(self.loaded), 2)
        self.assertEqual(self.loaded[1], self.loaded[0])

    def test_refused_table_is_retried_and_logged_once(self):
        calls = []

        def refuse(forwards):
            calls.append(1)
            raise subprocess.CalledProcessError(1, "nft", stderr="Error: syntax")
        self.runner.apply = refuse
        self.runner.list_services = lambda: [svc("web", [(443, "tcp")], "443/tcp", ip="172.16.1.12")]
        with mock.patch.object(pf.log, "error") as err:
            self.runner.step()
            self.runner.step()
        self.assertEqual(len(calls), 2)       # tried again
        self.assertEqual(err.call_count, 1)   # said so once
        self.assertIsNone(self.runner.applied)


if __name__ == "__main__":
    unittest.main()

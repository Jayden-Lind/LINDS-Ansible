"""Unit tests for nd-allnodes: the netlink parser and the Asker (no I/O).

    python3 -m unittest discover -s roles/router/tests
"""
import importlib.machinery
import sys
sys.dont_write_bytecode = True
import importlib.util
import os
import socket
import struct
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_path = os.path.join(HERE, "..", "files", "usr", "local", "sbin", "nd-allnodes")   # no .py suffix: load explicitly
_loader = importlib.machinery.SourceFileLoader("nd_allnodes", _path)
nd = importlib.util.module_from_spec(importlib.util.spec_from_loader("nd_allnodes", _loader))
sys.modules["nd_allnodes"] = nd
_loader.exec_module(nd)

MAC_A = socket.inet_pton(socket.AF_INET6, "2001:db8::a")
MAC_B = socket.inet_pton(socket.AF_INET6, "2001:db8::b")


def nlmsg(typ, ifindex, dst, state=0, family=socket.AF_INET6, extra=b""):
    """One rtnetlink neighbour message as the kernel lays it out."""
    attrs = struct.pack("=HH", 4 + len(dst), nd.NDA_DST) + dst
    attrs += b"\0" * (-len(attrs) % 4) + extra
    body = struct.pack("=BBHiHBB", family, 0, 0, ifindex, state, 0, 0) + attrs
    return struct.pack("=IHHII", 16 + len(body), typ, 0, 0, 0) + body


class Parser(unittest.TestCase):
    def test_request_for_our_interface(self):
        self.assertEqual(list(nd.neigh_messages(nlmsg(nd.RTM_GETNEIGH, 2, MAC_A), 2)), [(nd.RTM_GETNEIGH, 0, MAC_A)])

    def test_other_interface_and_ipv4_are_ignored(self):
        self.assertEqual(list(nd.neigh_messages(nlmsg(nd.RTM_GETNEIGH, 3, MAC_A), 2)), [])
        v4 = nlmsg(nd.RTM_GETNEIGH, 2, socket.inet_aton("10.0.50.7"), family=socket.AF_INET)
        self.assertEqual(list(nd.neigh_messages(v4, 2)), [])

    def test_several_messages_in_one_datagram(self):
        lladdr = struct.pack("=HH", 10, 2) + bytes(6) + b"\0\0"          # NDA_LLADDR after the address
        buf = nlmsg(nd.RTM_NEWNEIGH, 2, MAC_A, state=0x02, extra=lladdr) + nlmsg(nd.RTM_GETNEIGH, 2, MAC_B)
        self.assertEqual(list(nd.neigh_messages(buf, 2)), [(nd.RTM_NEWNEIGH, 0x02, MAC_A), (nd.RTM_GETNEIGH, 0, MAC_B)])

    def test_truncated_or_garbage_input_yields_nothing(self):
        whole = nlmsg(nd.RTM_GETNEIGH, 2, MAC_A)
        self.assertEqual(list(nd.neigh_messages(whole[:-3], 2)), [])
        self.assertEqual(list(nd.neigh_messages(b"\x05\0\0\0" + bytes(20), 2)), [])
        self.assertEqual(list(nd.neigh_messages(b"", 2)), [])

    def test_other_message_types_are_skipped(self):
        buf = nlmsg(29, 2, MAC_A) + nlmsg(nd.RTM_GETNEIGH, 2, MAC_B)       # RTM_DELNEIGH first
        self.assertEqual(list(nd.neigh_messages(buf, 2)), [(nd.RTM_GETNEIGH, 0, MAC_B)])


class Solicitation(unittest.TestCase):
    def test_layout(self):
        pkt = nd.solicitation(MAC_A, bytes.fromhex("bc2411011101"))
        self.assertEqual(len(pkt), 32)
        self.assertEqual(pkt[0], 135)
        self.assertEqual(pkt[8:24], MAC_A)
        self.assertEqual(pkt[24:], bytes.fromhex("0101bc2411011101"))


class Asking(unittest.TestCase):
    def test_first_request_is_sent_and_retried(self):
        a = nd.Asker(retries=(0.4, 1.0))
        self.assertTrue(a.request(MAC_A, 100.0))
        self.assertEqual(a.next_due(), 100.4)
        self.assertEqual(a.due(100.3), [])
        self.assertEqual(a.due(100.4), [MAC_A])
        self.assertEqual(a.due(101.0), [MAC_A])
        self.assertIsNone(a.next_due())
        self.assertEqual(a.due(105.0), [])

    def test_retries_stop_once_the_kernel_has_the_entry(self):
        a = nd.Asker(retries=(0.4, 1.0))
        a.request(MAC_A, 100.0)
        a.valid(MAC_A)
        self.assertEqual(a.due(102.0), [])
        self.assertEqual(a.stats["answered_early"], 1)
        a.valid(MAC_A)                                   # a later update for the same address is not counted
        self.assertEqual(a.stats["answered_early"], 1)

    def test_same_address_is_not_asked_twice_within_the_gap(self):
        a = nd.Asker(retries=(), min_gap=2.0)
        self.assertTrue(a.request(MAC_A, 100.0))
        self.assertFalse(a.request(MAC_A, 101.0))
        self.assertTrue(a.request(MAC_B, 101.0))
        self.assertTrue(a.request(MAC_A, 102.0))
        self.assertEqual(a.stats["asked"], 3)

    def test_multicast_targets_are_never_asked_for(self):
        a = nd.Asker()
        self.assertFalse(a.request(socket.inet_pton(socket.AF_INET6, "ff02::1:ff00:1"), 100.0))
        self.assertEqual(a.stats["asked"], 0)

    def test_overall_rate_is_capped(self):
        a = nd.Asker(retries=(), per_second=3)
        targets = [socket.inet_pton(socket.AF_INET6, f"2001:db8::{i:x}") for i in range(1, 7)]
        self.assertEqual([a.request(t, 100.0) for t in targets], [True, True, True, False, False, False])
        self.assertEqual(a.stats["rate_limited"], 3)
        self.assertTrue(a.request(socket.inet_pton(socket.AF_INET6, "2001:db8::99"), 101.0))

    def test_a_valid_report_for_one_address_leaves_the_others_queued(self):
        a = nd.Asker(retries=(0.5,))
        a.request(MAC_A, 100.0)
        a.request(MAC_B, 100.0)
        a.valid(MAC_A)
        self.assertEqual(a.due(100.5), [MAC_B])


if __name__ == "__main__":
    unittest.main()

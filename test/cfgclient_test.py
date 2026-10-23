#!/usr/bin/python3
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

# Simple tests to validate functionality of SWIG generated python API
# Run on vRouter.
# Some paths may need custom tweaking
#
# NOTE: Python unittest framework runs tests in *lexicographical* order.

import os
import unittest
from vyatta import configd

NTP_SERVER = ["system", "ntp", "server", "3.ca.pool.ntp.org"]
NTP_RESTART = ("[system ntp]\nStopping NTP server: ntpd.\n"
               "Starting NTP server: ntpd.\n\n")
SPEED = ["system", "console", "device", "ttyS0", "speed"]


def cmp_map(m1, m2):
    if len(m1) != len(m2):
        return False
    for key in m1:
        if key in m2 and m1[key] != m2[key]:
            return False
    return True


class ConfigdTestCase(unittest.TestCase):
    """A configd client, and a session id for tests that open one"""
    client = None
    sessid = str(os.getpid())

    @classmethod
    def setUpClass(cls):
        cls.client = configd.Client()


class SessionTestCase(ConfigdTestCase):
    """Each test runs in its own session"""

    def setUp(self):
        self.client.session_setup(self.sessid)

    def tearDown(self):
        self.client.session_teardown()


class TestSessionSetup(ConfigdTestCase):
    def tearDown(self):
        self.client.session_teardown()

    def test_session_setup_invalid(self):
        with self.assertRaises(configd.Exception) as cm:
            self.client.session_setup("")
        self.assertEqual(cm.exception.what(),
                         "must specify a session identifier")

    def test_session_setup_name(self):
        self.client.session_setup(self.sessid)
        result = self.client.session_exists()
        self.assertEqual(result, True, "Unable to create named session")


class TestSessionMethods(SessionTestCase):
    def test_session_saved(self):
        result = self.client.session_saved()
        self.assertEqual(result, False, "Incorrectly marked saved")
        self.client.session_mark_saved()
        result = self.client.session_saved()
        self.assertEqual(result, True, "Incorrectly marked unsaved")
        self.client.session_mark_unsaved()
        result = self.client.session_saved()
        self.assertEqual(result, False,
                         "Incorrectly marked saved after SessionUnsaved")

    def test_session_lock(self):
        result = self.client.session_locked()
        self.assertEqual(result, False, "Incorrectly locked")
        self.client.session_lock()
        result = self.client.session_locked()
        self.assertEqual(result, True, "Incorrectly unlocked")
        self.client.session_unlock()
        result = self.client.session_locked()
        self.assertEqual(result, False, "Incorrectly locked after unlock")

    def test_session_changed(self):
        path = NTP_SERVER
        result = self.client.session_changed()
        self.assertEqual(result, False, f"Unable to validate path {path}")
        if self.client.node_exists(self.client.AUTO, path):
            self.client.delete(path)
        else:
            self.client.set(path)
        result = self.client.session_changed()
        self.assertEqual(result, True, f"Unable to validate path {path}")


class TestTransactionMethods(SessionTestCase):
    def test_transaction_validate_path(self):
        path = ["interfaces", "dataplane", "dp0s3"]
        invalid_path = ["interfaces", "dataplane", "3"]
        result = self.client.validate_path(path)
        self.assertEqual(result, "", f"Invalid path: {result}")
        with self.assertRaises(configd.Exception) as cm:
            self.client.validate_path(invalid_path)
        self.assertEqual(
            cm.exception.what(),
            "Configuration path: interfaces dataplane [3] is not valid\n\n"
            "Must be one of the following:\n"
            "  <dpFpNpS>\n  <dpFemN>\n  <dpFsN>\n\n"
            "Value validation failed\n")

    def test_transaction_set(self):
        invalid_path = ["system", "ntp", "3.ca.pool.ntp.org"]
        path = NTP_SERVER
        with self.assertRaises(configd.Exception) as cm:
            self.client.set(invalid_path)
        self.assertEqual(
            cm.exception.what(),
            "Configuration path: system [ntp] is not valid\n\n"
            "Path is invalid\n\nSet failed\n")
        result = self.client.set(path)
        self.assertEqual(result, "", f"Unable to set path {path}")

    def test_transaction_validate(self):
        self.client.set(NTP_SERVER)
        result = self.client.validate()
        self.assertEqual(result, "", "Unable to validate transaction")

    def test_transaction_discard(self):
        self.client.set(NTP_SERVER)
        result = self.client.discard()
        self.assertEqual(result, "", "Unable to discard changes")
        result = self.client.session_changed()
        self.assertEqual(result, False, "Session incorrectly marked changed")

    def test_transaction_delete(self):
        path = NTP_SERVER
        self.client.set(path)
        result = self.client.delete(path)
        self.assertEqual(result, "", f"Unable to delete path {path}")
        result = self.client.node_exists(self.client.AUTO, path)
        self.assertEqual(result, False, "Node incorrectly exists")

    def test_transaction_commit(self):
        path = NTP_SERVER
        # Make sure there is a change to commit
        if self.client.node_exists(self.client.AUTO, path):
            self.client.delete(path)
        else:
            self.client.set(path)
        result = self.client.commit("")
        self.assertEqual(result, NTP_RESTART, "Unable to commit")
        # Clean up if we added a node
        if self.client.node_exists(self.client.AUTO, path):
            self.client.delete(path)
            self.client.commit("")

    def test_transaction_save_load(self):
        path = NTP_SERVER
        if self.client.node_exists(self.client.AUTO, path):
            self.client.delete(path)
            self.client.commit("")
        self.client.set(path)
        self.client.commit("")
        self.client.save()
        self.client.delete(path)

        result = self.client.load("/config/config.boot")
        self.assertEqual(result, True, "Unable to load")
        result = self.client.delete(path)
        self.assertEqual(result, "",
                         f"Unable to modify path {path}; load failed")
        self.client.commit("")
        self.client.save()


class TestTemplateMethods(ConfigdTestCase):
    def test_template_get(self):
        path = ["system", "ntp", "server"]
        exp_result = {'help': 'Network Time Protocol (NTP) server',
                      'key': 'tagnode', 'tag': '1', 'type': 'txt'}
        result = self.client.template_get(path)
        self.assertEqual(cmp_map(result, exp_result), True,
                         "Incorrect help returned")

    def test_template_get_children(self):
        path = ["system"]
        exp_result = ['acm', 'alg', 'config-management', 'config-sync',
                      'console', 'domain-name', 'domain-search', 'fips',
                      'host-name', 'ip', 'ipv6', 'login', 'name-server',
                      'ntp', 'options', 'package', 'power-profile',
                      'session', 'static-host-mapping', 'syslog',
                      'tacplus-options', 'time-zone']
        result = sorted(self.client.template_get_children(path))
        self.assertEqual(result, exp_result, "Incorrect children returned")

    def test_template_get_allowed(self):
        exp_result = ['115200', '1200', '19200', '2400', '38400', '4800',
                      '57600', '9600']
        result = sorted(self.client.template_get_allowed(SPEED))
        self.assertEqual(result, exp_result, "Incorrect allowed returned")

    def test_template_validate_path(self):
        path = SPEED + ["1"]
        result = self.client.template_validate_path(path)
        self.assertEqual(result, True, f"Invalid path: {path}")
        path = ["foo", "bar", "baz"]
        result = self.client.template_validate_path(path)
        self.assertEqual(result, False, f"Unexpected valid path: {path}")

    def test_template_validate_value(self):
        path = SPEED + ["115200"]
        result = self.client.template_validate_values(path)
        self.assertEqual(result, True, f"Incorrectly invalid path: {path}")
        path = SPEED + ["1"]
        result = self.client.template_validate_values(path)
        self.assertEqual(result, False, f"Incorrectly valid path: {path}")

    def test_get_help(self):
        path = ["system", "console", "device"]
        exp_result = {'ttyS0': 'Serial console device name'}
        result = self.client.get_help(path, False)
        self.assertEqual(cmp_map(result, exp_result), True,
                         "Incorrect help returned")

        exp_result = {'<pattern>': 'Serial console device name',
                      'ttyS0': 'Serial console device name'}
        result = self.client.get_help(path, True)
        self.assertEqual(cmp_map(result, exp_result), True,
                         "Incorrect help returned")


class TestNodeMethods(SessionTestCase):
    def test_node_exists(self):
        path = SPEED + ["115200"]
        result = self.client.node_exists(self.client.AUTO, path)
        self.assertEqual(result, False, "Incorrect path existence")
        result = self.client.node_exists(self.client.AUTO, SPEED)
        self.assertEqual(result, True, "Incorrect path existence")

    def test_node_is_default(self):
        result = self.client.node_is_default(self.client.AUTO, SPEED)
        self.assertEqual(result, True, "Incorrectly set as default")

    def test_node_get(self):
        path = ["system", "console", "device", "ttyS0"]
        exp_result = ('speed',)
        result = self.client.node_get(self.client.RUNNING, path)
        self.assertEqual(result, exp_result, "Incorrect node result")

    @unittest.skip("node_get_status test not implemented yet")
    def test_node_get_status(self):
        self.client.node_get_status(self.client.AUTO, SPEED)

    def test_node_get_type(self):
        cases = [
            (["system", "name-server"], self.client.MULTI),
            (["system", "console"], self.client.CONTAINER),
            (["system", "console", "device"], self.client.TAG),
            (["system", "console", "device", "ttyS0"], self.client.CONTAINER),
            (SPEED, self.client.LEAF),
        ]
        for path, node_type in cases:
            result = self.client.node_get_type(path)
            self.assertEqual(result, node_type,
                             f"Incorrect node type for path {path}")


if __name__ == '__main__':
    unittest.main()

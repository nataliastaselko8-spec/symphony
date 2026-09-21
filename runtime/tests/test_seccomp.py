import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from symphony_runtime.seccomp import restrict, matches, SOCKET_FAMILIES
from symphony_runtime.common import Rejected


class SeccompTest(unittest.TestCase):
    def setUp(self):
        self.profile = {'defaultAction': 'SCMP_ACT_ERRNO', 'archMap': [
            {'architecture': 'SCMP_ARCH_X86_64', 'subArchitectures': ['SCMP_ARCH_X86', 'SCMP_ARCH_X32']}],
            'syscalls': [{'names': ['read', 'socketpair', 'socketcall'], 'action': 'SCMP_ACT_ALLOW', 'args': []},
                         {'names': ['socket'], 'action': 'SCMP_ACT_ALLOW', 'args': [
                             {'index': 0, 'value': 16, 'op': 'SCMP_CMP_NE'}]},
                         {'names': ['socket'], 'action': 'SCMP_ACT_ALLOW', 'args': [
                             {'index': 2, 'value': 9, 'op': 'SCMP_CMP_NE'}], 'excludes': {'caps': ['CAP_AUDIT_WRITE']}}]}

    def test_retains_default_and_unrelated_rules_and_removes_compatibility_abi(self):
        before = copy.deepcopy(self.profile)
        result = restrict(self.profile)
        self.assertEqual(self.profile, before)
        self.assertEqual(result['defaultAction'], 'SCMP_ACT_ERRNO')
        self.assertEqual(result['architectures'], ['SCMP_ARCH_X86_64'])
        self.assertNotIn('archMap', result)
        self.assertEqual(result['syscalls'][0]['names'], ['read'])

    def test_socket_families_are_an_intersection_of_original_permissions(self):
        rules = restrict(self.profile)['syscalls']
        for rule in rules:
            if not set(rule['names']) & {'socket', 'socketpair', 'socketcall'}:
                continue
            self.assertNotIn('socketcall', rule['names'])
            self.assertEqual(sum(arg['index'] == 0 for arg in rule['args']), 1)
            for family in range(64):
                accepts = all(matches(arg, family) for arg in rule['args'] if arg['index'] == 0)
                if accepts:
                    self.assertIn(family, SOCKET_FAMILIES)
                    self.assertNotEqual(family, 40)
            if rule.get('excludes'):
                self.assertIn({'index': 2, 'value': 9, 'op': 'SCMP_CMP_NE'}, rule['args'])

    def test_rejects_allow_all_or_unknown_semantics(self):
        self.profile['defaultAction'] = 'SCMP_ACT_ALLOW'
        with self.assertRaises(Rejected): restrict(self.profile)
        self.profile['defaultAction'] = 'SCMP_ACT_ERRNO'
        self.profile['syscalls'][1]['args'][0]['op'] = 'unknown'
        with self.assertRaises(Rejected): restrict(self.profile)

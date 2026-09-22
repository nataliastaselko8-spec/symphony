"""Exact service scope validation across native Linux and WSL distro subtrees."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from symphony_runtime import cgroups
from symphony_runtime.common import Rejected
from symphony_runtime.network import Firewall
from symphony_runtime import host


class CgroupsTest(unittest.TestCase):
    def test_native_and_dynamic_wsl_paths_keep_full_scope(self):
        for prefix in ('', '/wsl-user/distro-287/systemd', '/wsl-user/distro-9001/systemd'):
            group = prefix + '/system.slice/symphony-fixture.service'
            self.assertEqual(cgroups.service_group(group, 'symphony-fixture.service'), group)
            self.assertIn(group[1:], Firewall(group[1:], ['1.1.1.1']).jump())

    def test_ancestors_traversal_and_other_units_are_rejected(self):
        for value in ('/', '/system.slice', '/wsl-user/distro-287/systemd',
                      '/system.slice/ssh.service', '/system.slice/symphony-a.service/payload',
                      '/system.slice/../system.slice/symphony-a.service',
                      '//system.slice/symphony-a.service', '/system.slice//symphony-a.service',
                      '/system.slice/./symphony-a.service', '/system.slice/symphony-a.service/',
                      'system.slice/symphony-a.service'):
            with self.subTest(value=value), self.assertRaises(Rejected):
                cgroups.service_group(value)
        with self.assertRaisesRegex(Rejected, 'unit_mismatch'):
            cgroups.service_group('/system.slice/symphony-other.service', 'symphony-fixture.service')

    def test_resources_require_all_three_controllers(self):
        group = '/wsl-user/distro-287/systemd/system.slice/symphony-fixture.service'
        for controllers in ('', 'memory pids', 'cpu pids', 'cpu memory'):
            with patch.object(Path, 'read_text', return_value=controllers), self.assertRaisesRegex(Rejected, 'controllers_missing'):
                cgroups.resources(group)
        with patch.object(Path, 'read_text', return_value='cpu memory pids'), patch.object(Path, 'stat') as stat:
            stat.return_value.st_ino = 42
            self.assertEqual(cgroups.resources(group), 42)

    def test_retained_payload_accepts_only_same_service_across_wsl_restart(self):
        current = '/wsl-user/distro-9001/systemd/system.slice/symphony-fixture.service'
        previous = '/wsl-user/distro-287/systemd/system.slice/symphony-fixture.service/payload/libpod-' + 'a' * 64
        self.assertEqual(cgroups.retained_payload(previous, current), previous)
        for value in (previous.replace('fixture.service', 'other.service'),
                      previous.replace('/payload/', '/payload/../payload/'),
                      previous.replace('/payload/', '//payload/'), previous + '/child',
                      previous.replace('libpod-', 'arbitrary-')):
            with self.subTest(value=value), self.assertRaises(Rejected):
                cgroups.retained_payload(value, current)

    def test_hybrid_or_ambiguous_membership_is_rejected(self):
        for raw in ('2:cpu:/fixture', '0::/fixture\n2:cpu:/fixture', ''):
            with patch.object(Path, 'read_text', return_value=raw), self.assertRaises(Rejected):
                cgroups.current_group()

    def test_refresh_refuses_changed_scope_inode_and_missing_resources(self):
        session = object.__new__(host.HostSession)
        session.group = 'wsl-user/distro-287/systemd/system.slice/symphony-fixture.service'
        session.unit = 'symphony-fixture.service'
        session.addresses = ['127.0.0.1']
        session.cgroup_inode = 42
        with patch.object(host, 'host_addresses', return_value=session.addresses), patch.object(host, 'run') as run:
            run.return_value = '/system.slice/symphony-fixture.service'
            with self.assertRaisesRegex(Rejected, 'service_cgroup_changed'):
                session.refresh()
            run.return_value = '/' + session.group
            with patch.object(host, 'resources', return_value=43), self.assertRaisesRegex(Rejected, 'replaced'):
                session.refresh()
            with patch.object(host, 'resources', side_effect=Rejected('worker_resource_controllers_missing')):
                with self.assertRaisesRegex(Rejected, 'controllers_missing'):
                    session.refresh()


if __name__ == '__main__':
    unittest.main()

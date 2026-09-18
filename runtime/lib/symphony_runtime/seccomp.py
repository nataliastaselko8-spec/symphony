"""Narrow the root-owned Podman default profile; never replace it with allow-all."""
import copy
import os
from pathlib import Path

from .common import canonical, digest, no_links, read_json, require

SOCKET_FAMILIES = (1, 2, 10, 16)  # Unix, IPv4, IPv6, netlink. No host AF_VSOCK.


def matches(argument, value):
    expected = argument['value']
    operations = {'SCMP_CMP_EQ': lambda: value == expected, 'SCMP_CMP_NE': lambda: value != expected,
                  'SCMP_CMP_LT': lambda: value < expected, 'SCMP_CMP_LE': lambda: value <= expected,
                  'SCMP_CMP_GT': lambda: value > expected, 'SCMP_CMP_GE': lambda: value >= expected,
                  'SCMP_CMP_MASKED_EQ': lambda: value & expected == argument.get('valueTwo', 0)}
    require(argument.get('op') in operations, 'unsupported_socket_filter')
    return operations[argument['op']]()


def restrict(profile):
    require(profile.get('defaultAction') == 'SCMP_ACT_ERRNO', 'deny_by_default_seccomp_required')
    result = copy.deepcopy(profile)
    # This runtime supports x86_64. Reject compatibility ABIs rather than allow
    # the i386 socketcall multiplexer to bypass argument filtering.
    result.pop('archMap', None)
    result['architectures'] = ['SCMP_ARCH_X86_64']
    rules = []
    found = set()
    for original in result['syscalls']:
        names = set(original['names']) & {'socket', 'socketpair', 'socketcall'}
        if not names:
            rules.append(original)
            continue
        require(original['action'] in ('SCMP_ACT_ALLOW', 'SCMP_ACT_ERRNO', 'SCMP_ACT_KILL',
                                       'SCMP_ACT_KILL_PROCESS', 'SCMP_ACT_TRAP'), 'unsupported_socket_action')
        if original['action'] != 'SCMP_ACT_ALLOW':
            rules.append(original)
            continue
        rest = {**original, 'names': [name for name in original['names'] if name not in names]}
        if rest['names']:
            rules.append(rest)
        for name in sorted(names - {'socketcall'}):
            found.add(name)
            arguments = original.get('args') or []
            for family in SOCKET_FAMILIES:
                if all(matches(arg, family) for arg in arguments if arg['index'] == 0):
                    rules.append({**original, 'names': [name], 'args':
                        [arg for arg in arguments if arg['index'] != 0] +
                        [{'index': 0, 'value': family, 'valueTwo': 0, 'op': 'SCMP_CMP_EQ'}]})
    require(found == {'socket', 'socketpair'}, 'socket_seccomp_rules_required')
    result['syscalls'] = rules
    return result


def trusted_file(file):
    file = no_links(file)
    for path in (file, *file.parents):
        info = path.stat()
        require(info.st_uid == 0 and info.st_mode & 0o022 == 0, 'root_owned_seccomp_required')
    require(file.is_file() and file.stat().st_size <= 1024 * 1024, 'seccomp_file_required')
    return file


def install(destination):
    require(os.uname().machine == 'x86_64', 'seccomp_x86_64_required')
    source = trusted_file(Path('/usr/share/containers/seccomp.json'))
    raw = canonical(restrict(read_json(source)))
    with Path(destination).open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    Path(destination).chmod(0o644)
    return digest(raw)


def verify(file, expected):
    require(digest(trusted_file(file).read_bytes()) == expected, 'seccomp_policy_changed')

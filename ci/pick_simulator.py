#!/usr/bin/env python3
"""Points TelegramCallsUI's ios_test_runner at a simulator that exists on this CI machine.

Upstream pins a device/OS pair from the Telegram team's own Macs; a hosted runner may ship a
different iOS runtime. Prints the chosen pair and writes it to $GITHUB_ENV for later steps.
"""
import json
import os
import re
import subprocess

devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '-j', 'devices', 'available']))['devices']
candidates = []
for runtime, items in devices.items():
    match = re.search(r'iOS-(\d+)-(\d+)', runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for item in items:
        if item['name'].startswith('iPhone') and 'Pro' in item['name']:
            candidates.append((version, item['name'], item['udid']))
if not candidates:
    for runtime, items in devices.items():
        match = re.search(r'iOS-(\d+)-(\d+)', runtime)
        if match:
            for item in items:
                if item['name'].startswith('iPhone'):
                    candidates.append(((int(match.group(1)), int(match.group(2))), item['name'], item['udid']))
candidates.sort()
version, name, udid = candidates[-1]
os_version = '{}.{}'.format(*version)
print('Simulator: {} (iOS {}) {}'.format(name, os_version, udid))

path = 'submodules/TelegramCallsUI/BUILD'
source = open(path).read()
source = re.sub(r'device_type = "[^"]+"', 'device_type = "{}"'.format(name), source, count=1)
source = re.sub(r'os_version = "[^"]+"', 'os_version = "{}"'.format(os_version), source, count=1)
open(path, 'w').write(source)

env_path = os.environ.get('GITHUB_ENV')
if env_path:
    with open(env_path, 'a') as f:
        f.write('SIM_NAME={}\nSIM_OS={}\nSIM_UDID={}\n'.format(name, os_version, udid))

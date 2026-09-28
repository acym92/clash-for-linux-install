#!/usr/bin/env python3
"""Exercise an isolated Mihomo installation; never stop the real installation.

Run on Linux: python3 tests/runtime-recovery-integration.py \
    --kernel /path/to/mihomo --yq /path/to/yq
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--kernel', type=Path, required=True)
    parser.add_argument('--yq', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    install = Path(tempfile.mkdtemp(prefix='clash-runtime-integration-')).resolve()
    resources = install / 'resources'
    resources.mkdir()
    release_stream = threading.Event()
    slow_started = threading.Event()
    release_download = threading.Event()
    slow_body = b''
    stream_body = b'x' * 4096

    class Handler(BaseHTTPRequestHandler):
        def do_CONNECT(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(stream_body[:2048])
            self.wfile.flush()
            release_stream.wait(20)
            try:
                self.wfile.write(stream_body[2048:])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            if urllib.parse.urlsplit(self.path).path == '/slow-subscription':
                self.send_response(200)
                self.send_header('Content-Length', str(len(slow_body)))
                self.end_headers()
                slow_started.set()
                release_download.wait(20)
                try:
                    self.wfile.write(slow_body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_args):
            pass

    upstream = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    upstream.daemon_threads = True
    threading.Thread(target=upstream.serve_forever, daemon=True).start()

    def port():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            return sock.getsockname()[1]

    mixed, api_port, sub_port = port(), port(), port()
    env = dict(os.environ, CLASHCTL_HOME=str(install))

    def write_json(path, data):
        path.write_text(json.dumps(data) + '\n', encoding='utf-8')

    def yaml_data(path):
        return json.loads(subprocess.check_output([str(args.yq), '-o=json', '.', str(path)]))

    def wait_for(predicate, description, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if predicate():
                    return
            except (OSError, ValueError, urllib.error.URLError):
                pass
            time.sleep(0.1)
        raise AssertionError(description)

    def ctl(*words, check=True):
        result = subprocess.run(
            ['bash', '-c', '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; clashctl "$@"', 'testctl', *words],
            env=env, capture_output=True, text=True, timeout=50)
        if check and result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result

    def api(path, method='GET', data=None):
        req = urllib.request.Request(
            f'http://127.0.0.1:{api_port}{path}', method=method,
            headers={'Authorization': 'Bearer test-secret', 'Content-Type': 'application/json'},
            data=None if data is None else json.dumps(data).encode())
        with urllib.request.urlopen(req, timeout=5) as response:
            body = response.read()
            return json.loads(body) if body else None

    def pid(name):
        return int((resources / name).read_text().strip())

    def subscription_ready():
        with urllib.request.urlopen(f'http://127.0.0.1:{sub_port}/sub/test-token', timeout=1) as response:
            return response.status == 200

    def owned_process(process_id):
        try:
            environ = Path(f'/proc/{process_id}/environ').read_bytes()
            return f'CLASHCTL_HOME={install}'.encode() in environ.split(b'\0')
        except OSError:
            return False

    def stop_owned(process_id):
        assert owned_process(process_id), f'Would stop a process outside {install}'
        os.kill(process_id, signal.SIGKILL)

    boot = None
    try:
        shutil.copytree(root / 'scripts', install / 'scripts')
        (install / 'bin').mkdir()
        (install / 'bin' / 'yq').symlink_to(args.yq.resolve())
        (install / 'bin' / 'mihomo').symlink_to(args.kernel.resolve())
        (install / '.env').write_text(
            'CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\nCLASHCTL_SERVICE_READY_TIMEOUT=3\n'
            'CLASHCTL_SUPERVISOR_INTERVAL=1\nCLASHCTL_SUB_UA=test\nCLASHCTL_SUB_RETRY=0\n',
            encoding='utf-8')
        profile = {
            'mixed-port': mixed, 'allow-lan': False, 'bind-address': '127.0.0.1',
            'external-controller': f'127.0.0.1:{api_port}', 'secret': 'test-secret',
            'listeners': [], 'profile': {'store-selected': True},
            'proxies': [{'name': n, 'type': 'http', 'server': '127.0.0.1',
                         'port': upstream.server_port} for n in ['A', 'B']],
            'proxy-groups': [{'name': 'PROXY', 'type': 'select', 'proxies': ['A', 'B']}],
            'rules': ['MATCH,PROXY']}
        cached = resources / 'cached.yaml'
        source = install / 'new-subscription.yaml'
        write_json(cached, profile)
        write_json(source, profile)
        validation = subprocess.run([str(args.kernel), '-d', str(resources), '-f', str(source), '-t'],
                                    capture_output=True, text=True, timeout=15)
        assert validation.returncode == 0, validation.stdout + validation.stderr
        write_json(resources / 'profiles.yaml', {'use': 'Test', 'profiles': [
            {'name': 'Test', 'url': source.as_uri(), 'path': str(cached), 'updated': ''}]})
        write_json(resources / 'mixin.yaml', {})
        write_json(resources / 'config.yaml', profile)
        write_json(resources / 'runtime.yaml', dict(profile, proxies=[
            dict(n, name='[Test] ' + n['name']) for n in profile['proxies']],
            **{'proxy-groups': [
                {'name': 'PROXY', 'type': 'select', 'proxies': ['HA-AUTO']},
                {'name': 'HA-AUTO', 'type': 'select', 'proxies': ['[Test] A', '[Test] B']}]},
        ))
        ha = yaml_data(root / 'resources' / 'ha.yaml')
        ha.update(enabled=True, mode='pin', interval=60,
                  **{'check-url': f'http://127.0.0.1:{upstream.server_port}/204',
                     'confirm-url': f'http://127.0.0.1:{upstream.server_port}/204'})
        ha['subscription-update']['enabled'] = False
        ha['lan'].update(enabled=True, server='127.0.0.1', port=mixed,
                         **{'subscription-port': sub_port, 'subscription-token': 'test-token',
                            'allowed-cidr': '127.0.0.1/32'})
        write_json(resources / 'ha.yaml', ha)
        # Stale PID files must not kill this Python process or suppress startup.
        for name in ['ha.pid', 'ha-sub.pid', 'supervisor.pid']:
            (resources / name).write_text(str(os.getpid()))
        with (install / 'boot.log').open('w') as log:
            boot = subprocess.Popen(['bash', str(install / 'scripts/init/container.sh')],
                                    env=env, stdout=log, stderr=log)
        wait_for(lambda: api('/version') and (resources / 'supervisor.heartbeat').exists(),
                 'Container entrypoint did not start and supervise the kernel')
        wait_for(lambda: pid('ha.pid') != os.getpid() and pid('ha-sub.pid') != os.getpid(),
                 'Stale PIDs blocked auxiliary startup')
        wait_for(subscription_ready, 'Subscription process has not started listening')
        print('PASS entrypoint startup, stale PID recovery, subscription HTTP 200', flush=True)

        api('/proxies/HA-AUTO', 'PUT', {'name': '[Test] B'})
        kernel_pid = pid('mihomo.pid')
        connection = socket.create_connection(('127.0.0.1', mixed), timeout=20)
        connection.sendall(b'CONNECT fixture.invalid:443 HTTP/1.1\r\nHost: fixture.invalid:443\r\n\r\n')
        response = connection.makefile('rb')
        status = response.readline()
        assert b' 200 ' in status, status
        while response.readline() != b'\r\n':
            pass
        first = response.read(2048)
        wait_for(lambda: api('/connections')['connections'], 'Streaming request was not tracked')
        before_ids = {c['id'] for c in api('/connections')['connections']}
        assert before_ids
        profile['proxies'].append({'name': 'C', 'type': 'http', 'server': '127.0.0.1',
                                   'port': upstream.server_port})
        profile['proxy-groups'][0]['proxies'].append('C')
        write_json(source, profile)
        ha['subscription-update']['enabled'] = True
        write_json(resources / 'ha.yaml', ha)
        ctl('ha', 'update')
        assert pid('mihomo.pid') == kernel_pid
        state = yaml_data(resources / 'ha-sub-update-state.yaml')
        assert state['pending'] is False, (resources / 'ha.log').read_text()
        group = api('/proxies/HA-AUTO')
        assert group['now'] == '[Test] B' and '[Test] C' in group['all'], group
        after_ids = {c['id'] for c in api('/connections')['connections']}
        assert before_ids <= after_ids, 'Hot reload closed an active connection'
        release_stream.set()
        assert first + response.read() == stream_body
        connection.close()
        print('PASS new subscription applied, selected node/PID/stream preserved', flush=True)

        # Changes to ingress must be rejected with disk rollback, not restarted.
        ha['subscription-update']['enabled'] = False
        write_json(resources / 'ha.yaml', ha)
        saved_base = (resources / 'config.yaml').read_bytes()
        saved_runtime = (resources / 'runtime.yaml').read_bytes()
        changed = dict(profile, **{'mixed-port': port()})
        write_json(cached, changed)
        result = subprocess.run(['bash', '-c',
            '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; _ha_build_and_reload'],
            env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode != 0
        assert (resources / 'config.yaml').read_bytes() == saved_base
        assert (resources / 'runtime.yaml').read_bytes() == saved_runtime
        assert pid('mihomo.pid') == kernel_pid
        write_json(cached, profile)
        print('PASS incompatible ingress rejected with configuration rollback', flush=True)

        # Hold a real subscription response open while HA continues checking.
        newest = json.loads(json.dumps(profile))
        newest['proxies'].append({'name': 'D', 'type': 'http', 'server': '127.0.0.1',
                                 'port': upstream.server_port})
        newest['proxy-groups'][0]['proxies'].append('D')
        slow_body = (json.dumps(newest) + '\n').encode()
        write_json(resources / 'profiles.yaml', {'use': 'Test', 'profiles': [
            {'name': 'Test', 'url': f'http://127.0.0.1:{upstream.server_port}/slow-subscription',
             'path': str(cached), 'updated': ''}]})
        state['next-download'] = 0
        write_json(resources / 'ha-sub-update-state.yaml', state)
        ha['subscription-update']['enabled'] = True
        ha['interval'] = 1
        write_json(resources / 'ha.yaml', ha)
        result = subprocess.run(['bash', '-c',
            '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; _ha_stop_daemon; _ha_install_daemon'],
            env=env, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        assert slow_started.wait(10), 'Background subscription download did not start'
        checked_at = int(yaml_data(resources / 'ha-state.yaml')['checked-at'])
        wait_for(lambda: int(yaml_data(resources / 'ha-state.yaml')['checked-at']) > checked_at,
                 'Slow subscription download blocked HA checks', timeout=8)
        release_download.set()
        wait_for(lambda: yaml_data(resources / 'ha-sub-update-state.yaml')['next-download'] > time.time(),
                 'Background download did not complete and schedule its next run')
        assert '[Test] D' in api('/proxies/HA-AUTO')['all']
        print('PASS slow background download does not block HA checks and applies new nodes', flush=True)
        ha['subscription-update']['enabled'] = False
        write_json(resources / 'ha.yaml', ha)

        old_ha, old_sub = pid('ha.pid'), pid('ha-sub.pid')
        stop_owned(old_ha)
        stop_owned(old_sub)
        wait_for(lambda: pid('ha.pid') != old_ha and pid('ha-sub.pid') != old_sub,
                 'Supervisor did not recover killed auxiliary services')
        wait_for(subscription_ready, 'Restarted subscription process has not started listening')
        print('PASS killed HA/subscription processes automatically recovered', flush=True)
        stop_owned(kernel_pid)
        wait_for(lambda: pid('mihomo.pid') != kernel_pid and api('/version'),
                 'Supervisor did not recover the isolated kernel')
        print('PASS isolated kernel crash automatically recovered', flush=True)

        ctl('off', '--service-only')
        time.sleep(2)
        assert not (resources / 'supervisor.enabled').exists()
        assert not (resources / 'ha.pid').exists()
        assert not (resources / 'ha-sub.pid').exists()
        try:
            api('/version')
        except urllib.error.URLError:
            pass
        else:
            raise AssertionError('Explicit off was undone by the supervisor')
        print('PASS explicit off stops services without automatic resurrection', flush=True)
    except Exception:
        for name in ['boot.log', 'resources/supervisor.log', 'resources/ha.log', 'resources/mihomo.log', 'resources/last-failed.yaml']:
            path = install / name
            if path.exists():
                print(f'--- {name} ---\n{path.read_text()[-6000:]}', flush=True)
        raise
    finally:
        release_stream.set()
        release_download.set()
        (resources / 'supervisor.enabled').unlink(missing_ok=True)
        for item in Path('/proc').iterdir():
            if item.name.isdigit() and owned_process(int(item.name)):
                try:
                    os.kill(int(item.name), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        if boot is not None:
            boot.wait(timeout=5)
        upstream.shutdown()
        assert install.parent == Path(tempfile.gettempdir()).resolve()
        assert install.name.startswith('clash-runtime-integration-')
        shutil.rmtree(install)


if __name__ == '__main__':
    main()

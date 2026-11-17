#!/usr/bin/env python3
"""Real NW3 TCP/UDP payload round trips on loopback; no root or external target."""
import argparse
import contextlib
import hashlib
import os
from pathlib import Path
import secrets
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = 12


def receive(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError('Unexpected EOF')
        data.extend(chunk)
    return bytes(data)


def address(sock, atyp):
    if atyp == 1:
        host = socket.inet_ntop(socket.AF_INET, receive(sock, 4))
    elif atyp == 4:
        host = socket.inet_ntop(socket.AF_INET6, receive(sock, 16))
    else:
        raise RuntimeError(f'Unexpected SOCKS address type {atyp}')
    return host, struct.unpack('!H', receive(sock, 2))[0]


def request(sock, command, port):
    sock.sendall(b'\x05\x01\x00')
    if receive(sock, 2) != b'\x05\x00':
        raise RuntimeError('SOCKS authentication failed')
    sock.sendall(bytes([5, command, 0, 1]) + socket.inet_aton('127.0.0.1') + struct.pack('!H', port))
    reply = receive(sock, 4)
    if reply[:3] != b'\x05\x00\x00':
        raise RuntimeError(f'SOCKS request failed: {reply.hex()}')
    return address(sock, reply[3])


class TCPEcho(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(TIMEOUT)
        try:
            while data := self.request.recv(65536):
                self.request.sendall(data)
        except (TimeoutError, ConnectionError):
            pass


class UDPEcho(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)


class TCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


@contextlib.contextmanager
def echo_servers():
    with TCPServer(('127.0.0.1', 0), TCPEcho) as tcp, socketserver.UDPServer(('127.0.0.1', 0), UDPEcho) as udp:
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (tcp, udp)]
        for thread in threads:
            thread.start()
        try:
            yield tcp.server_address[1], udp.server_address[1]
        finally:
            tcp.shutdown()
            udp.shutdown()
            for thread in threads:
                thread.join()


def free_port():
    # Ensure the chosen port is free for both carriers; startup failures remain fatal.
    with socket.socket() as tcp, socket.socket(type=socket.SOCK_DGRAM) as udp:
        tcp.bind(('127.0.0.1', 0))
        port = tcp.getsockname()[1]
        udp.bind(('127.0.0.1', port))
        return port


def wait_listener(port, processes):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        if any(p.poll() is not None for p in processes):
            raise RuntimeError('Core exited during startup')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.2):
                return
        except OSError:
            time.sleep(.05)
    raise RuntimeError('Listener startup timed out')


def tcp_roundtrip(socks_port, target_port):
    with socket.create_connection(('127.0.0.1', socks_port), timeout=TIMEOUT) as sock:
        request(sock, 1, target_port)
        for size in (1, 4096, 65536):
            payload = secrets.token_bytes(size)
            sock.sendall(payload)
            if receive(sock, size) != payload:
                raise RuntimeError('TCP payload mismatch')
        sock.shutdown(socket.SHUT_WR)
        if sock.recv(1) != b'':
            raise RuntimeError('Expected TCP EOF after half-close')


def udp_roundtrip(socks_port, target_port):
    with socket.create_connection(('127.0.0.1', socks_port), timeout=TIMEOUT) as control, socket.socket(type=socket.SOCK_DGRAM) as udp:
        udp.bind(('127.0.0.1', 0))
        udp.settimeout(TIMEOUT)
        host, port = request(control, 3, udp.getsockname()[1])
        if host == '0.0.0.0':
            host = '127.0.0.1'
        if host != '127.0.0.1' or not port:
            raise RuntimeError('SOCKS UDP relay must be on loopback')
        header = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', target_port)
        # 4096 bytes also exercises QUIC UDP fragmentation/reassembly.
        for size in (1, 512, 1200, 4096):
            payload = secrets.token_bytes(size)
            udp.sendto(header + payload, (host, port))
            packet, sender = udp.recvfrom(65535)
            if sender != (host, port) or packet != header + payload:
                raise RuntimeError('UDP source, header or payload mismatch')


def run_case(binary, directory, pin, carrier, egress, policy, targets):
    portal_port, socks_port = free_port(), free_port()
    while socks_port == portal_port:
        socks_port = free_port()
    key = secrets.token_hex(16)
    label = f'{carrier} -> {egress or "direct"}, Prelude={policy}'
    env = {k: v for k, v in os.environ.items() if not k.startswith('NOW_')}
    env.update(NOW_MORPH_TCP_PRELUDE=policy, NOW_MORPH_UDP_PRELUDE=policy,
               NOW_HANDSHAKE_TIMEOUT='3s', NOW_FLOW_SETUP_TIMEOUT='8s', TMPDIR=str(directory))
    # A TCP-only topology verifies TLS Egress does not require a UDP listener.
    endpoint = f'/tcp:{portal_port}'
    if carrier == 'udp' or egress == 'udp':
        endpoint += f'/udp:{portal_port}'
    portal = f'portal://{key}@127.0.0.1{endpoint}?tls=2&crt={directory}/cert.pem&key={directory}/key.pem&morph=1'
    if egress:
        portal += '&out=egress'
    processes = []
    with tempfile.TemporaryFile() as logs:
        def start(url):
            processes.append(subprocess.Popen([str(binary), url], env=env, stdout=logs, stderr=logs))
        try:
            start(portal)
            wait_listener(portal_port, processes)
            if egress:
                start(f'egress://{key}@127.0.0.1/{egress}:{portal_port}?pin={pin}&morph=1')
            start(f'vector://{key}@127.0.0.1/{carrier}:{portal_port}?pin={pin}&morph=1&in=127.0.0.1:{socks_port}')
            wait_listener(socks_port, processes)
            # Repeated fresh flows exercise TLS standby replenishment and QUIC reuse.
            for _ in range(3):
                tcp_roundtrip(socks_port, targets[0])
                udp_roundtrip(socks_port, targets[1])
            if any(p.poll() is not None for p in processes):
                raise RuntimeError('Core exited during traffic checks')
            print(f'PASS TCP + UDP payloads: {label}', flush=True)
        except Exception:
            logs.seek(0)
            print(logs.read().decode(errors='replace').replace(key, '<redacted>'))
            raise
        finally:
            for proc in reversed(processes):
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'upstream/v3.3.0/nowhere')
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f'Executable core required: {binary}')
    with tempfile.TemporaryDirectory(prefix='nw3-') as tmp, echo_servers() as targets:
        directory = Path(tmp)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-keyout', str(directory / 'key.pem'), '-out', str(directory / 'cert.pem')], check=True, capture_output=True)
        pin = hashlib.sha256(subprocess.check_output(['openssl', 'x509', '-in', str(directory / 'cert.pem'), '-outform', 'DER'])).hexdigest()
        for policy in ('fade', 'full8', 'low7'):
            for carrier in ('tcp', 'udp'):
                for egress in (None, 'tcp', 'udp'):
                    run_case(binary, directory, pin, carrier, egress, policy, targets)
    print('18 native scenarios passed (108 TCP/UDP sessions); no production or systemd changes')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Runtime overrides: validate before mutation, persist, preview and restore."""
import importlib.util
from pathlib import Path
import shlex
import unittest

spec = importlib.util.spec_from_file_location('fixes', Path(__file__).with_name('test_fixes.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
KEYS = ('EGRESS_TLS_POOL_MAX', 'PORTAL_TLS_IDLE_MAX', 'HANDSHAKE_TIMEOUT', 'FLOW_SETUP_TIMEOUT')


class RuntimeSettings(unittest.TestCase):
    def setUp(self):
        m.Fixes.setUp(self)
        self.url = 'vector://' + 'a' * 32 + '@127.0.0.1/tcp:2083?in=127.0.0.1:1083'
        (self.d / 'etc/url.conf').write_text(self.url + '\n')
        (self.d / 'opt/current/RELEASE-INFO').write_text('tag: v3.3.0\n')

    tearDown = m.Fixes.tearDown
    runsh = m.Fixes.runsh

    def success(self, body):
        r = self.runsh(3, body)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def test_default_omits_environment(self):
        self.success('write_unit')
        unit = (self.d / 'unit.service').read_text()
        for key in KEYS:
            self.assertNotIn('NOW_' + key + '=', unit)

    def test_boundaries_and_rejection_before_unit_write(self):
        for key in KEYS:
            valid = ('1', '1023') if 'MAX' in key else ('1ms', '86400000ms', '86400s')
            invalid = ('0', '-1', '01', '1024', '1.5', 'x\nEnvironment=BAD=1') if 'MAX' in key else ('0s', '-1s', '1.5s', '1m', '86401s', '86400001ms', '1s\nEnvironment=BAD=1')
            for value in valid:
                with self.subTest(key=key, value=value):
                    self.success(f'{key}={shlex.quote(value)}; validate_runtime_settings')
            for value in invalid:
                with self.subTest(key=key, value=value):
                    r = self.runsh(3, f'{key}={shlex.quote(value)}; write_unit')
                    self.assertNotEqual(r.returncode, 0)
                    self.assertFalse((self.d / 'unit.service').exists())

    def test_persistence_and_cli_precedence(self):
        self.success('EGRESS_TLS_POOL_MAX=16; PORTAL_TLS_IDLE_MAX=32; HANDSHAKE_TIMEOUT=750ms; FLOW_SETUP_TIMEOUT=12s; write_meta')
        self.success('main validate --url "$(read_url)" --handshake-timeout 2s; write_meta; load_meta; write_unit')
        unit = (self.d / 'unit.service').read_text()
        for line in ('EGRESS_TLS_POOL_MAX=16', 'PORTAL_TLS_IDLE_MAX=32', 'HANDSHAKE_TIMEOUT=2s', 'FLOW_SETUP_TIMEOUT=12s'):
            self.assertIn('Environment=NOW_' + line, unit)

    def test_clear_all_with_default(self):
        self.success('EGRESS_TLS_POOL_MAX=16; PORTAL_TLS_IDLE_MAX=32; HANDSHAKE_TIMEOUT=2s; FLOW_SETUP_TIMEOUT=12s; write_meta')
        flags = ' '.join('--' + k.lower().replace('_', '-') + ' default' for k in KEYS)
        self.success(f'main validate --url "$(read_url)" {flags}; write_meta; load_meta; write_unit')
        unit = (self.d / 'unit.service').read_text()
        for key in KEYS:
            self.assertNotIn('NOW_' + key + '=', unit)

    def test_old_metadata_resets_overrides(self):
        (self.d / 'etc/manager.conf').write_text('SCRIPT_CHANNEL=v3\n')
        self.success('EGRESS_TLS_POOL_MAX=16; HANDSHAKE_TIMEOUT=2s; load_meta; write_unit')
        unit = (self.d / 'unit.service').read_text()
        self.assertNotIn('NOW_EGRESS_TLS_POOL_MAX=', unit)
        self.assertNotIn('NOW_HANDSHAKE_TIMEOUT=', unit)

    def test_invalid_saved_values_fail_before_mutation(self):
        (self.d / 'etc/manager.conf').write_text('HANDSHAKE_TIMEOUT=garbage\n')
        r = self.runsh(3, 'main configure -y')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.d / 'unit.service').exists())

    def test_pool_downgrade_gate(self):
        for key in KEYS[:2]:
            r = self.runsh(3, f'VERSION=v3.2.0; {key}=16; write_unit')
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse((self.d / 'unit.service').exists())

    def test_preview_shows_overrides_without_writing(self):
        r = self.success('main preview --handshake-timeout 250ms --egress-tls-pool-max 16')
        self.assertIn('"handshake_timeout": "250ms"', r.stdout)
        self.assertIn('"egress_tls_pool_max": "16"', r.stdout)
        self.assertNotIn('a' * 32, r.stdout)
        self.assertFalse((self.d / 'unit.service').exists())

    def backup(self, metadata):
        (self.d / 'etc/manager.conf').write_text('SCRIPT_CHANNEL=v3\n' + metadata)
        self.success('backup_action "$SB/backup.tar.gz"')

    def restore(self, dry=False):
        return self.runsh(3, 'ensure_user() { :; }; wait_service() { return 0; }; ASSUME_YES=1; BACKUP_PATH="$SB/backup.tar.gz"; ' + ('DRY_RUN=1; ' if dry else '') + 'restore_action')

    def test_restore_persists_and_legacy_restore_clears(self):
        self.backup('HANDSHAKE_TIMEOUT=5s\nEGRESS_TLS_POOL_MAX=16\n')
        r = self.restore()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('NOW_HANDSHAKE_TIMEOUT=5s', (self.d / 'unit.service').read_text())
        (self.d / 'backup.tar.gz').unlink()
        self.backup('')
        (self.d / 'etc/manager.conf').write_text('SCRIPT_CHANNEL=v3\nHANDSHAKE_TIMEOUT=10s\n')
        r = self.restore()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('NOW_HANDSHAKE_TIMEOUT=', (self.d / 'unit.service').read_text())

    def test_invalid_backup_rejected_even_on_dry_run(self):
        self.backup('HANDSHAKE_TIMEOUT=bad\n')
        before = (self.d / 'etc/manager.conf').read_bytes()
        r = self.restore(dry=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.d / 'etc/manager.conf').read_bytes(), before)
        self.assertFalse((self.d / 'unit.service').exists())

    def test_restore_pool_override_rejected_on_old_core(self):
        self.backup('EGRESS_TLS_POOL_MAX=16\n')
        (self.d / 'opt/current/RELEASE-INFO').write_text('tag: v3.2.0\n')
        r = self.restore(dry=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.d / 'unit.service').exists())

    def test_failed_activation_restores_settings(self):
        self.success('HANDSHAKE_TIMEOUT=5s; write_meta; write_unit')
        before_meta = (self.d / 'etc/manager.conf').read_bytes()
        before_unit = (self.d / 'unit.service').read_bytes()
        r = self.runsh(3, 'begin_transaction; HANDSHAKE_TIMEOUT=10s; write_meta; wait_service() { return 1; }; activate')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.d / 'etc/manager.conf').read_bytes(), before_meta)
        self.assertEqual((self.d / 'unit.service').read_bytes(), before_unit)


if __name__ == '__main__':
    unittest.main(verbosity=2)

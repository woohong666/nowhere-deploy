#!/usr/bin/env python3
"""Focused regression for the six review findings; no network or real services."""
import unittest, pathlib, importlib.util, subprocess, os, hashlib, tarfile, ctypes
spec=importlib.util.spec_from_file_location('features',pathlib.Path(__file__).with_name('test_features.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Review(unittest.TestCase):
 setUp=m.Features.setUp
 tearDown=m.Features.tearDown
 runsh=m.Features.runsh
 cert=m.Features.cert
 config=m.Features.config
 backup=m.Features.backup
 snapshot=m.Features.snapshot
 restore=m.Features.restore
 prepare_renew=m.Features.prepare_renew
 def patch(self,v,old,new):
  p=self.d/f'v{v}.sh';s=p.read_text();self.assertIn(old,s);p.write_text(s.replace(old,new))
 def test_backup_no_hardlink_atomic_fallback(self):
  if not hasattr(ctypes.CDLL(None,use_errno=True),'renameat2'):
   self.skipTest('renameat2 is Linux-only; the fallback cannot run on this platform')
  for v in (2,3):
   with self.subTest(v=v):
    self.config(v)
    self.patch(v,'os.link(tmp,out)',"(_ for _ in ()).throw(OSError(errno.EOPNOTSUPP,'test'))")
    p=self.backup(v)
    with tarfile.open(p) as t:self.assertTrue(any(x.name.endswith('manager.conf') for x in t))
    self.assertEqual(p.stat().st_mode&0o777,0o600);p.unlink()
 def test_backup_fallback_race_never_overwrites(self):
  for v in (2,3):
   with self.subTest(v=v):
    self.config(v)
    self.patch(v,'os.link(tmp,out)',"out.write_bytes(b'COMPETING FILE');raise OSError(errno.EPERM,'test')")
    r=self.runsh(v,'backup_action "$SB/backup.tar.gz"');self.assertNotEqual(r.returncode,0)
    p=self.d/'backup.tar.gz';self.assertEqual(p.read_bytes(),b'COMPETING FILE');p.unlink()
 def test_backup_unsupported_both_methods_fails_closed(self):
  self.config();self.patch(3,'os.link(tmp,out)',"(_ for _ in ()).throw(OSError(errno.EOPNOTSUPP,'test'))")
  self.patch(3,"rename=getattr(ctypes.CDLL(None,use_errno=True),'renameat2',None)",'rename=None')
  r=self.runsh(3,'backup_action "$SB/backup.tar.gz"');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'backup.tar.gz').exists());self.assertFalse(list(self.d.glob('.nowhere-backup-*')))
 def test_backup_permission_failure_does_not_fallback(self):
  self.config();self.patch(3,'os.link(tmp,out)',"(_ for _ in ()).throw(OSError(errno.EACCES,'test'))")
  r=self.runsh(3,'backup_action "$SB/backup.tar.gz"');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'backup.tar.gz').exists())
 def test_metadata_comments_spaces_restore_consistently(self):
  for v in (2,3):
   with self.subTest(v=v):
    self.config(v);p=self.d/'etc/manager.conf';p.write_text(f'  # updated=one\n# updated=two\n SCRIPT_CHANNEL = v{v} \n MEMORY_PROFILE = balanced \n MORPH_PRELUDE = full8 \n')
    backup=self.backup(v);r=self.restore(v);self.assertEqual(r.returncode,0,r.stderr)
    self.assertIn('SCRIPT_CHANNEL=v'+str(v),p.read_text());self.assertIn('MEMORY_PROFILE=balanced',p.read_text());backup.unlink()
 def test_metadata_duplicate_effective_key_rejected(self):
  self.config();p=self.d/'etc/manager.conf';p.write_text(p.read_text()+' SCRIPT_CHANNEL = v3\n');self.backup();r=self.restore();self.assertNotEqual(r.returncode,0)
 def test_metadata_spaced_invalid_setting_rejected(self):
  self.config();p=self.d/'etc/manager.conf';p.write_text('SCRIPT_CHANNEL=v3\n MEMORY_PROFILE = INVALID \n');self.backup();r=self.restore(dry=True);self.assertNotEqual(r.returncode,0)
 def test_pipe_help_works_without_unbound_variable(self):
  r=subprocess.run(['bash','-s','--','help'],input=(self.d/'v3.sh').read_text(),env=self.env,text=True,capture_output=True,timeout=5)
  self.assertEqual(r.returncode,0,r.stderr);self.assertIn('[ACTION]',r.stdout)
 def test_pipe_timer_refused_before_mutation(self):
  r=subprocess.run(['bash','-s','--','cert-timer'],input=(self.d/'v3.sh').read_text(),env=self.env,text=True,capture_output=True,timeout=5)
  self.assertNotEqual(r.returncode,0);self.assertNotIn('unbound variable',r.stderr);self.assertTrue('pipe' in r.stderr or '管道' in r.stderr);self.assertFalse((self.d/'opt/manager').exists())
 def test_timer_missing_source_guard_precedes_setup(self):
  r=self.runsh(3,'MANAGER_FILE=""; mutating_setup() { touch "$SB/SETUP"; }; cert_timer_action')
  self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'SETUP').exists())
 def test_acme_archive_prefix_follows_version(self):
  import re
  f=self.d/'src';(f/'dnsapi').mkdir(parents=True);(f/'acme.sh').write_text('#!/bin/sh\nexit 0\n');(f/'dnsapi/dns_cf.sh').write_text('dns_cf_add() { :; }\n')
  with tarfile.open(self.d/'fixture.tar.gz','w:gz') as t:t.add(f,arcname='acme.sh-9.9.9')
  self.patch(3,'ACME_VERSION="3.1.6"','ACME_VERSION="9.9.9"')
  p=self.d/'v3.sh';p.write_text(re.sub(r'ACME_ARCHIVE_SHA256="[0-9a-f]+"','ACME_ARCHIVE_SHA256="'+hashlib.sha256((self.d/'fixture.tar.gz').read_bytes()).hexdigest()+'"',p.read_text()))
  r=self.runsh(3,'curl() { local dest; while (($#)); do if [[ "$1" == -o ]]; then dest="$2"; shift 2; else shift; fi; done; cp "$SB/fixture.tar.gz" "$dest"; }; ensure_acme')
  self.assertEqual(r.returncode,0,r.stderr);self.assertTrue((self.d/'etc/acme/dnsapi/dns_cf.sh').is_file())
 def test_custom_cert_does_not_query_timer(self):
  self.prepare_renew();p=self.d/'etc/url.conf';p.write_text(p.read_text().replace('/tls/le.example.test/','/tls/custom/'));(self.d/'etc/tls/le.example.test').rename(self.d/'etc/tls/custom')
  r=self.runsh(3,'systemctl() { touch "$SB/QUERIED"; return 0; }; cert_status_action');self.assertEqual(r.returncode,0,r.stderr);self.assertFalse((self.d/'QUERIED').exists());self.assertTrue('Custom certificate' in r.stdout or '自备证书' in r.stdout)
 def test_expired_status_keeps_timer_and_last_result(self):
  self.prepare_renew()
  r=self.runsh(3,'openssl() { if [[ " $* " == *" -checkend 0 "* ]]; then return 1; fi; command openssl "$@"; }; systemctl() { echo TIMER_STATUS; }; cert_status_action')
  self.assertNotEqual(r.returncode,0);self.assertIn('TIMER_STATUS',r.stdout);self.assertIn('Last renewal:',r.stdout)
 def test_invalid_date_no_traceback_and_keeps_status(self):
  self.prepare_renew()
  r=self.runsh(3,'openssl() { if [[ " $* " == *" -enddate "* ]]; then echo notAfter=INVALID; return 0; fi; command openssl "$@"; }; cert_status_action')
  self.assertNotEqual(r.returncode,0);self.assertNotIn('Traceback',r.stderr);self.assertIn('Last renewal:',r.stdout)
 def test_broken_managed_cert_keeps_timer_status(self):
  self.prepare_renew();(self.d/'etc/tls/le.example.test/fullchain.pem').write_text('BROKEN')
  r=self.runsh(3,'systemctl() { echo TIMER_STATUS; }; cert_status_action');self.assertNotEqual(r.returncode,0);self.assertIn('TIMER_STATUS',r.stdout);self.assertNotIn('Traceback',r.stderr)
 def test_timer_status_error_keeps_renewal_result(self):
  self.prepare_renew();r=self.runsh(3,'systemctl() { return 1; }; cert_status_action');self.assertNotEqual(r.returncode,0);self.assertIn('Last renewal:',r.stdout)
if __name__=='__main__':unittest.main(verbosity=2)

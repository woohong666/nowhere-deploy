#!/usr/bin/env python3
"""Offline feature and rollback tests. Services, accounts, DNS and CA are mocked."""
import unittest, pathlib, sys, os, json, tarfile, io, subprocess, hashlib, importlib.util
spec=importlib.util.spec_from_file_location('fixes',pathlib.Path(__file__).with_name('test_fixes.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class Features(module.Fixes):
 def config(self,v=3,portal=False):
  key='a'*(64 if v==2 else 32)
  url=('portal://'+key+'@*:2083?tls=1') if portal else ('vector://'+key+'@example.test:2083?'+('socks' if v==2 else 'in')+'=127.0.0.1:1083')
  (self.d/'etc/url.conf').write_text(url+'\n');(self.d/'etc/manager.conf').write_text(f'SCRIPT_CHANNEL=v{v}\nCORE_VERSION=v{v}.0.0\nMEMORY_PROFILE=balanced\nMORPH_PRELUDE=full8\n')
  (self.d/'opt/current/RELEASE-INFO').write_text(f'tag: v{v}.0.0\n');return url+'\n'
 def backup(self,v=3):
  r=self.runsh(v,'backup_action "$SB/backup.tar.gz"');self.assertEqual(r.returncode,0,r.stderr);return self.d/'backup.tar.gz'
 def snapshot(self):
  return {p.relative_to(self.d/'etc').as_posix():p.read_bytes() for p in (self.d/'etc').rglob('*') if p.is_file()}
 def restore(self,v=3,fail=False,dry=False):
  body='ensure_user() { :; }; wait_service() { return 0; }; ASSUME_YES=1; BACKUP_PATH="$SB/backup.tar.gz"\n'
  if fail:body+='systemctl() { [[ "$1" != restart ]]; }\n'
  if dry:body+='DRY_RUN=1\n'
  return self.runsh(v,body+'restore_action')
 def test_backup_restore_both_channels(self):
  for v in (2,3):
   with self.subTest(v=v):
    self.config(v);old=(self.d/'etc/url.conf').read_text();p=self.d/'backup.tar.gz'
    if p.exists():p.unlink()
    self.backup(v);(self.d/'etc/url.conf').write_text('CURRENT DIFFERENT\n')
    r=self.restore(v);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual((self.d/'etc/url.conf').read_text(),old)
    self.assertTrue(list(self.d.glob('backup.tar.gz.before-restore-*')));self.assertEqual(p.stat().st_mode&0o777,0o600)
 def test_restore_dry_run_no_config_change(self):
  self.config();self.backup();before=self.snapshot();r=self.restore(dry=True)
  self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(self.snapshot(),before);self.assertFalse(list(self.d.glob('*before-restore*')))
 def test_restore_restart_failure_rolls_back(self):
  self.config();self.backup();(self.d/'etc/url.conf').write_text('ORIGINAL-CURRENT\n');before=self.snapshot();r=self.restore(fail=True)
  self.assertNotEqual(r.returncode,0);self.assertEqual(self.snapshot(),before)
 def test_restore_cross_channel_rejected(self):
  self.config(2);self.backup(2);before=self.snapshot();r=self.restore(3)
  self.assertNotEqual(r.returncode,0);self.assertEqual(self.snapshot(),before)
 def test_restore_manifest_tamper_rejected(self):
  self.config();p=self.backup();members=[]
  with tarfile.open(p,'r:gz') as t:
   for m in t:
    data=t.extractfile(m).read() if m.isfile() else None
    if m.name.endswith('/url.conf'):data=b'bad\n';m.size=len(data)
    members.append((m,data))
  p.unlink()
  with tarfile.open(p,'w:gz') as t:
   for m,data in members:t.addfile(m,io.BytesIO(data) if data is not None else None)
  before=self.snapshot();r=self.restore();self.assertNotEqual(r.returncode,0);self.assertEqual(self.snapshot(),before)
 def test_restore_traversal_symlink_hardlink_rejected(self):
  self.config();before=self.snapshot()
  for mode in ('traversal','symlink','hardlink','duplicate'):
   with self.subTest(mode=mode):
    with tarfile.open(self.d/'backup.tar.gz','w:gz') as t:
     m=tarfile.TarInfo('../escape' if mode=='traversal' else 'etc/unsafe')
     if mode in ('symlink','hardlink'):m.type=tarfile.SYMTYPE if mode=='symlink' else tarfile.LNKTYPE;m.linkname='/etc/passwd'
     t.addfile(m)
     if mode=='duplicate':t.addfile(m)
    r=self.restore();self.assertNotEqual(r.returncode,0);self.assertEqual(self.snapshot(),before);self.assertFalse((self.d.parent/'escape').exists())
 def test_backup_dangling_link_and_incomplete_no_overwrite(self):
  self.config();(self.d/'backup.tar.gz').symlink_to(self.d/'absent')
  r=self.runsh(3,'backup_action "$SB/backup.tar.gz"');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'absent').exists())
  (self.d/'backup.tar.gz').unlink();(self.d/'etc/link').symlink_to('/etc/passwd')
  r=self.runsh(3,'backup_action "$SB/backup.tar.gz"');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'backup.tar.gz').exists())
 def test_backup_legacy_channel_restore(self):
  self.config();old=(self.d/'etc/url.conf').read_text()
  with tarfile.open(self.d/'backup.tar.gz','w:gz') as t:t.add(self.d/'etc',arcname='nowhere-v3')
  r=self.restore();self.assertEqual(r.returncode,0,r.stderr);self.assertEqual((self.d/'etc/url.conf').read_text(),old)
 def test_diagnostics_no_credentials(self):
  self.config();secret='sensitive-password-123';(self.d/'etc/url.conf').write_text('vector://'+'a'*32+'@example.test:2083?in=user:'+secret+'@127.0.0.1:1083&pin='+'b'*64)
  r=self.runsh(3,'diagnostics_action');self.assertEqual(r.returncode,0,r.stderr);d=json.loads(r.stdout);self.assertEqual(d['role'],'vector');self.assertNotIn(secret,r.stdout);self.assertNotIn('a'*32,r.stdout)
 def test_preview_no_writes_no_restart_and_secrets_hidden(self):
  self.config();before=self.snapshot();r=self.runsh(3,'''systemctl() { echo CALLED; return 99; }
main configure --dry-run --endpoint new.test:2084 --key bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --in 'user:verysecret@127.0.0.1:1084'
''');self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(self.snapshot(),before);self.assertIn('new.test',r.stdout);self.assertNotIn('verysecret',r.stdout);self.assertNotIn('b'*32,r.stdout);self.assertNotIn('CALLED',r.stdout);self.assertFalse((self.d/'lock').exists())
 def test_preview_rejects_invalid_and_role_switch(self):
  self.config();before=self.snapshot()
  for args in ('--endpoint bad','--role portal --endpoint "*:2083"'):
   r=self.runsh(3,'main configure --dry-run '+args);self.assertNotEqual(r.returncode,0);self.assertEqual(self.snapshot(),before)
 def prepare_renew(self):
  self.cert();self.config(portal=True);d=self.d/'etc/tls/le.example.test';d.mkdir();(d/'fullchain.pem').write_bytes((self.d/'cert.pem').read_bytes());(d/'key.pem').write_bytes((self.d/'key.pem').read_bytes())
  (self.d/'etc/url.conf').write_text('portal://'+'a'*32+'@*:2083?tls=2&crt='+str(d/'fullchain.pem')+'&key='+str(d/'key.pem')+'\n')
  home=self.d/'etc/acme';domain=home/'example.test_ecc';domain.mkdir(parents=True)
  (domain/'fullchain.cer').write_bytes((self.d/'cert.pem').read_bytes());(domain/'example.test.key').write_bytes((self.d/'key.pem').read_bytes());(domain/'example.test.conf').write_text("Le_ReloadCmd='unsafe-old-command'\nLe_RealFullChainPath='/unsafe'\nLe_Domain='example.test'\n")
  mock=home/'acme.sh';mock.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >>"$SB/acme-args"
if [[ " $* " == *' --renew '* ]]; then
 if [[ "${RENEW_CODE:-0}" != 0 ]]; then exit "$RENEW_CODE"; fi
 if [[ "${BAD_CERT:-0}" == 1 ]]; then printf BAD > "$SB/etc/acme/example.test_ecc/fullchain.cer"; fi
 exit 0
fi
if [[ " $* " == *' --install-cert '* ]]; then
 while (($#)); do case "$1" in --fullchain-file) cp "$SB/etc/acme/example.test_ecc/fullchain.cer" "$2"; shift 2;; --key-file) cp "$SB/etc/acme/example.test_ecc/example.test.key" "$2"; shift 2;; *) shift;; esac; done
fi
''');mock.chmod(0o700)
  return '''ensure_acme() { :; }
wait_service() { return 0; }
systemctl() { printf '%s\\n' "$*" >> "$SB/systemctl-calls"; return 0; }
'''
 def test_renew_success_and_hooks_disabled(self):
  body=self.prepare_renew();r=self.runsh(3,body+'cert_renew_action');self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual(json.loads((self.d/'etc/renewal-status.json').read_text())['status'],'renewed');self.assertIn('--renew --server letsencrypt', (self.d/'acme-args').read_text());self.assertNotIn('unsafe-old-command',(self.d/'etc/acme/example.test_ecc/example.test.conf').read_text())
 def test_renew_not_due_no_restart(self):
  body=self.prepare_renew();self.env['RENEW_CODE']='2';r=self.runsh(3,body+'cert_renew_action');self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('restart', (self.d/'systemctl-calls').read_text());self.assertEqual(json.loads((self.d/'etc/renewal-status.json').read_text())['status'],'not_due')
 def test_renew_error_restores_acme_state_and_cert(self):
  body=self.prepare_renew();before=self.snapshot();self.env['RENEW_CODE']='17';r=self.runsh(3,body+'cert_renew_action');self.assertNotEqual(r.returncode,0);after=self.snapshot();result=json.loads(after.pop('renewal-status.json'));self.assertEqual(after,before);self.assertEqual(result['status'],'failed')
 def test_renew_invalid_certificate_rollback(self):
  body=self.prepare_renew();before=self.snapshot();self.env['BAD_CERT']='1';r=self.runsh(3,body+'cert_renew_action');self.assertNotEqual(r.returncode,0);after=self.snapshot();after.pop('renewal-status.json');self.assertEqual(after,before)
 def test_renew_restart_failure_rollback(self):
  body=self.prepare_renew();before=self.snapshot();r=self.runsh(3,body+'systemctl() { [[ "$1" != restart ]]; }\ncert_renew_action');self.assertNotEqual(r.returncode,0);after=self.snapshot();after.pop('renewal-status.json');self.assertEqual(after,before)
 def test_renew_stopped_service_stays_stopped(self):
  body=self.prepare_renew();r=self.runsh(3,body+'systemctl() { echo "$*" >> "$SB/systemctl-calls"; [[ "$1" != is-active ]]; }\ncert_renew_action');self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('restart', (self.d/'systemctl-calls').read_text())
 def test_renew_busy_logged_skip(self):
  body=self.prepare_renew();before=self.snapshot();r=self.runsh(3,body+'flock() { return 1; }\ncert_renew_action');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('跳过',r.stdout);self.assertEqual(self.snapshot(),before);self.assertFalse((self.d/'acme-args').exists())
 def test_timer_failed_enable_rolls_back(self):
  body=self.prepare_renew();unit=self.d/'unit-cert-renew.timer';unit.write_text('OLD TIMER\n')
  r=self.runsh(3,body+'systemctl() { [[ "$1" != enable ]]; }\ncert_timer_action');self.assertNotEqual(r.returncode,0);self.assertEqual(unit.read_text(),'OLD TIMER\n');self.assertFalse((self.d/'opt/manager').exists())
 def test_timer_stable_runner_no_acme_cron(self):
  body=self.prepare_renew();r=self.runsh(3,body+'cert_timer_action');self.assertEqual(r.returncode,0,r.stderr);text=(self.d/'unit-cert-renew.service').read_text();self.assertIn('cert-renew',text);self.assertNotIn('--cron',text);self.assertTrue((self.d/'opt/manager/nowhere-v3.sh').is_file())
 def test_certificate_status_no_token(self):
  body=self.prepare_renew();r=self.runsh(3,body+'cert_status_action');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('notAfter',r.stdout);self.assertNotIn('a'*32,r.stdout)
 def test_acme_checksum_refuses_bad_download(self):
  r=self.runsh(3,'''curl() { local target; while (($#)); do if [[ "$1" == -o ]]; then target="$2"; shift 2; else shift; fi; done; printf corrupted > "$target"; }
ensure_acme
''');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'etc/acme/acme.sh').exists())
 def test_official_acme_archive_install_and_reuse(self):
  fixture=pathlib.Path(__file__).with_name('fixtures')/'acme-3.1.6.tar.gz'
  self.env['ACME_FIXTURE']=str(fixture.resolve())
  r=self.runsh(3,'''curl() { local target; while (($#)); do if [[ "$1" == -o ]]; then target="$2"; shift 2; else shift; fi; done; cp "$ACME_FIXTURE" "$target"; }
ensure_acme
curl() { return 99; }
ensure_acme
"$ACME_HOME/acme.sh" --version
''');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('3.1.6',r.stdout);self.assertTrue((self.d/'etc/acme/dnsapi/dns_cf.sh').is_file())
 def test_v2_trusted_wrong_hostname_refused(self):
  self.cert()
  subprocess.run(['openssl','req','-new','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1','-nodes','-subj','/CN=example.test','-keyout',str(self.d/'leaf.key'),'-out',str(self.d/'leaf.csr')],capture_output=True,check=True)
  (self.d/'ext').write_text('subjectAltName=DNS:example.test\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
  subprocess.run(['openssl','x509','-req','-in',str(self.d/'leaf.csr'),'-CA',str(self.d/'cert.pem'),'-CAkey',str(self.d/'key.pem'),'-CAcreateserial','-days','1','-extfile',str(self.d/'ext'),'-out',str(self.d/'leaf.pem')],capture_output=True,check=True)
  self.env['SSL_CERT_FILE']=str(self.d/'cert.pem')
  r=self.runsh(2,'''PUBLIC_HOST=wrong.test
if build_native_vector_link_from_portal "portal://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@*:2082?tls=2&crt=$SB/leaf.pem&key=$SB/leaf.key"; then exit 99; fi
if certificate_needs_pin "$SB/leaf.pem" example.test; then exit 98; else [[ "$?" == 1 ]]; fi
''');self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('vector://',r.stdout)
 def test_expired_or_wrong_key_not_deployed(self):
  body=self.prepare_renew();before=self.snapshot()
  (self.d/'etc/acme/example.test_ecc/example.test.key').write_text('not a key')
  original=(self.d/'etc/tls/le.example.test/fullchain.pem').read_bytes()
  r=self.runsh(3,body+'cert_renew_action');self.assertNotEqual(r.returncode,0);self.assertEqual((self.d/'etc/tls/le.example.test/fullchain.pem').read_bytes(),original)
 def test_certificate_status_warns_legacy_timer(self):
  body=self.prepare_renew();(self.d/'unit-cert-renew.service').write_text('ExecStart=/acme.sh --cron\n')
  r=self.runsh(3,body+'cert_status_action');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('cert-timer',r.stderr);self.assertIn('DaysRemaining',r.stdout)
if __name__=='__main__':
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Features));sys.exit(not result.wasSuccessful())

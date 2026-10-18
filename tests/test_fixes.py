#!/usr/bin/env python3
"""Offline regression: no real services, ACME requests, package installs or secrets."""
import os, pathlib, subprocess, tempfile, unittest, sys, tarfile, hashlib
ROOT=pathlib.Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 else pathlib.Path(__file__).resolve().parents[1]
class Fixes(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.d=pathlib.Path(self.tmp.name)
  for x in ('etc/tls','opt/releases/current','bin'): (self.d/x).mkdir(parents=True)
  self.env=dict(os.environ,PATH=str(self.d/'bin')+':'+os.environ['PATH'],SB=str(self.d))
  for c in ('systemctl','journalctl','runuser','chown','useradd','groupadd'):
   p=self.d/'bin'/c;p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o755)
  for v in (2,3):
   s=(ROOT/f'nowhere-v{v}.sh').read_text()
   replacements={f'/etc/nowhere-v{v}':str(self.d/'etc'),f'/opt/nowhere-v{v}':str(self.d/'opt'),f'/usr/local/bin/nowhere-v{v}':str(self.d/'bin/core'),f'/usr/local/libexec/nowhere-v{v}-launch':str(self.d/'bin/launch'),f'/etc/systemd/system/nowhere-v{v}.service':str(self.d/'unit.service'),f'/run/nowhere-v{v}-build.lock.d':str(self.d/'lock.d'),'/usr/local/bin/nh':str(self.d/'bin/nh'),'/root/.acme.sh':str(self.d/'legacy-acme')}
   for a,b in replacements.items():s=s.replace(a,b)
   import grp
   s=s.replace(f'RUN_GROUP="nowhere-v{v}"', 'RUN_GROUP="'+grp.getgrgid(os.getgid()).gr_name+'"')
   (self.d/f'v{v}.sh').write_text(s)
  (self.d/'opt/current').symlink_to(self.d/'opt/releases/current',target_is_directory=True)
  p=self.d/'opt/current/nowhere';p.write_text('#!/bin/sh\necho nowhere-v2.2.1\n');p.chmod(0o755)
  (self.d/'bin/core').symlink_to(p)
  (self.d/'etc/url.conf').write_text('vector://'+'a'*64+'@example.test:2082?socks=127.0.0.1:1082\n')
 def tearDown(self):self.tmp.cleanup()
 def runsh(self,v,body):
  pre=f'source "{self.d}/v{v}.sh"\nrequire_root() {{ :; }}\nrequire_systemd() {{ :; }}\ninstall_runtime_deps() {{ :; }}\n'
  return subprocess.run(['bash','-c',pre+body],env=self.env,text=True,capture_output=True)
 def cert(self):
  subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1','-nodes','-days','2','-subj','/CN=example.test','-addext','subjectAltName=DNS:example.test','-keyout',str(self.d/'key.pem'),'-out',str(self.d/'cert.pem')],check=True,capture_output=True)
 def test_v2_trusted_certificate_errexit(self):
  r=self.runsh(2,'''PUBLIC_HOST=example.test
certificate_needs_pin() { return 1; }
build_native_vector_link_from_portal "portal://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@*:2082?tls=2&crt=/unused&key=/unused"
echo reached
''');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('reached',r.stdout)
 def test_v2_missing_certificate_no_link(self):
  r=self.runsh(2,'''PUBLIC_HOST=example.test
if build_native_vector_link_from_portal "portal://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@*:2082?tls=2&crt=/missing&key=/missing"; then exit 99; fi
''');self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('vector://',r.stdout)
 def test_v2_vector_32_key_on_220(self):
  r=self.runsh(2,'ROLE=vector; VERSION=v2.2.0; key_acceptable aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');self.assertEqual(r.returncode,0,r.stderr)
 def test_v2_doctor_restart_failure_rollback(self):
  old=(self.d/'etc/url.conf').read_text()
  r=self.runsh(2,'''DOCTOR_FIX=1
id() { return 0; }
ensure_user() { :; }
write_launcher() { :; }
write_unit() { printf corrupted > "$URL_FILE"; }
port_listening_tcp() { return 0; }
wait_service() { return 1; }
systemctl() { [[ "${1:-}" != restart ]]; }
doctor_action
''');self.assertNotEqual(r.returncode,0);self.assertEqual((self.d/'etc/url.conf').read_text(),old)
 def test_v2_doctor_checks_repaired_state(self):
  (self.d/'bin/core').unlink()
  r=self.runsh(2,'''DOCTOR_FIX=1
id() { return 0; }
ensure_user() { :; }
write_launcher() { :; }
write_unit() { :; }
port_listening_tcp() { return 0; }
wait_service() { return 0; }
doctor_action
''');self.assertEqual(r.returncode,0,r.stderr);self.assertTrue((self.d/'bin/core').is_symlink())
 def test_v3_dns_plugin_installed(self):
  f=self.d/'src';(f/'dnsapi').mkdir(parents=True);(f/'acme.sh').write_text('#!/bin/sh\nexit 0\n');(f/'dnsapi/dns_cf.sh').write_text('dns_cf_add() { :; }\n')
  with tarfile.open(self.d/'fixture.tar.gz','w:gz') as t:t.add(f,arcname='acme.sh-3.1.6')
  p=self.d/'v3.sh';text=p.read_text();import re
  text=re.sub(r'ACME_ARCHIVE_SHA256="[0-9a-f]+"','ACME_ARCHIVE_SHA256="'+hashlib.sha256((self.d/'fixture.tar.gz').read_bytes()).hexdigest()+'"',text);p.write_text(text)
  r=self.runsh(3,'''curl() { local dest; while (($#)); do if [[ "$1" == -o ]]; then dest="$2"; shift 2; else shift; fi; done; cp "$SB/fixture.tar.gz" "$dest"; }
ensure_acme
test -r "$ACME_HOME/dnsapi/dns_cf.sh"
''');self.assertEqual(r.returncode,0,r.stderr)
 def test_v3_acme_state_isolated(self):
  r=self.runsh(3,'[[ "$ACME_HOME" == "$CONFIG_DIR"/* ]]');self.assertEqual(r.returncode,0)
 def test_v3_renewal_path_preserved(self):
  self.cert()
  r=self.runsh(3,'''mkdir -p "$TLS_DIR/le.example.test"
cp "$SB/cert.pem" "$TLS_DIR/le.example.test/fullchain.pem"
cp "$SB/key.pem" "$TLS_DIR/le.example.test/key.pem"
stage_pem "$TLS_DIR/le.example.test/fullchain.pem" "$TLS_DIR/le.example.test/key.pem"
[[ "$CERT" == "$TLS_DIR/le.example.test/fullchain.pem" && "$TLS_KEY" == "$TLS_DIR/le.example.test/key.pem" ]]
''');self.assertEqual(r.returncode,0,r.stderr)
 def test_v3_renew_timer_uses_management_lock(self):
  r=self.runsh(3,'write_cert_timer\ngrep -q "cert-renew" "${UNIT_FILE%.service}-cert-renew.service"');self.assertEqual(r.returncode,0,r.stderr)
 def test_v3_shortcut_does_not_follow_symlink(self):
  p=self.d/'victim';p.write_text('# nowhere-v3-shortcut\nKEEP\n');(self.d/'bin/nh').symlink_to(p)
  r=self.runsh(3,'install_shortcut');self.assertEqual(r.returncode,0);self.assertEqual(p.read_text(),'# nowhere-v3-shortcut\nKEEP\n')
 def test_v3_ca_link_and_hostname(self):
  self.cert();self.env['SSL_CERT_FILE']=str(self.d/'cert.pem')
  r=self.runsh(3,'''certificate_trusted_for_host "$SB/cert.pem" example.test
if certificate_trusted_for_host "$SB/cert.pem" wrong.test; then exit 99; fi
v3_url links 'portal://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@*:2083?tls=2&crt=/a&key=/b' example.test ''
''');self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('pin=',r.stdout);self.assertIn('vector://',r.stdout)
 def acme_mock(self):
  self.cert();(self.d/'etc/url.conf').write_text('portal://'+'a'*32+'@*:2083?tls=2&crt='+str(self.d/'cert.pem')+'&key='+str(self.d/'key.pem')+'\n')
  (self.d/'acme-mock').write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >>"$SB/acme-args"
if [[ " $* " == *' --install-cert '* ]]; then
 while (($#)); do case "$1" in --fullchain-file) cp "$SB/cert.pem" "$2"; shift 2;; --key-file) cp "$SB/key.pem" "$2"; shift 2;; *) shift;; esac; done
fi
exit 0
''');(self.d/'acme-mock').chmod(0o755)
  return '''CERT_DOMAIN=example.test; CERT_HTTP=1
ensure_acme() { mkdir -p "$ACME_HOME/example.test_ecc"; cp "$SB/acme-mock" "$ACME_HOME/acme.sh"; cp "$SB/cert.pem" "$ACME_HOME/example.test_ecc/fullchain.cer"; cp "$SB/key.pem" "$ACME_HOME/example.test_ecc/example.test.key"; }
wait_service() { return 0; }
'''
 def test_v3_explicit_letsencrypt(self):
  r=self.runsh(3,self.acme_mock()+'cert_action');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('--issue --server letsencrypt', (self.d/'acme-args').read_text())
 def test_v3_cert_failure_restores_previous_pem(self):
  pre=self.acme_mock();d=self.d/'etc/tls/le.example.test';d.mkdir();(d/'fullchain.pem').write_text('OLD CERT');(d/'key.pem').write_text('OLD KEY')
  r=self.runsh(3,pre+'systemctl() { [[ "${1:-}" != restart ]]; }\ncert_action')
  self.assertNotEqual(r.returncode,0);self.assertEqual((d/'fullchain.pem').read_text(),'OLD CERT');self.assertEqual((d/'key.pem').read_text(),'OLD KEY')
if __name__=='__main__':unittest.main(verbosity=2)

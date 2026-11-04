#!/usr/bin/env python3
import unittest,pathlib,importlib.util,json,os,shutil
spec=importlib.util.spec_from_file_location('fixes',pathlib.Path(__file__).with_name('test_fixes.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Core330(unittest.TestCase):
 def setUp(self):
  m.Fixes.setUp(self);self.key='a'*32
  (self.d/'etc/url.conf').write_text(f'portal://{self.key}@127.0.0.1/tcp:2083?out=egress')
 tearDown=m.Fixes.tearDown
 runsh=m.Fixes.runsh
 def test_tcp_egress_supported_both_roles(self):
  for role in ['portal','egress']:
   url=f'{role}://{self.key}@127.0.0.1/tcp:2083'+('?out=egress' if role=='portal' else '')
   r=self.runsh(3,f'v3_url validate-core "{url}" v3.3.0');self.assertEqual(r.returncode,0,r.stderr)
   r=self.runsh(3,f'v3_url validate-core "{url}" v3.2.0');self.assertNotEqual(r.returncode,0)
 def test_udp_egress_old_core_kept(self):
  r=self.runsh(3,f'v3_url validate-core "egress://{self.key}@127.0.0.1:2083" v3.0.0');self.assertEqual(r.returncode,0,r.stderr)
 def test_source_binding_restriction_kept(self):
  r=self.runsh(3,f'v3_url validate "portal://{self.key}@127.0.0.1/tcp:2083?out=egress&dial=auto"');self.assertNotEqual(r.returncode,0)
 def test_links_match_running_core(self):
  for version,tcp in [('v3.3.0',True),('v3.1.0',False),('unknown',False)]:
   r=self.runsh(3,f'v3_url links "portal://{self.key}@*:2083?out=egress" example.test "'+('b'*64)+f'" {version}')
   self.assertEqual(r.returncode,0,r.stderr);lines=[x for x in r.stdout.splitlines() if x.startswith('Egress:')]
   self.assertEqual(any('/tcp:' in x for x in lines),tcp);self.assertTrue(any('/udp:' in x for x in lines))
 def test_udp_default_does_not_override_core(self):
  r=self.runsh(3,'write_unit');self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('NOW_MORPH_UDP_PRELUDE=',(self.d/'unit.service').read_text())
 def test_udp_explicit_mode_persisted(self):
  r=self.runsh(3,'MORPH_UDP_PRELUDE=low7; write_meta; MORPH_UDP_PRELUDE=""; load_meta; write_unit')
  self.assertEqual(r.returncode,0,r.stderr);self.assertIn('NOW_MORPH_UDP_PRELUDE=low7',(self.d/'unit.service').read_text())
 def test_old_core_udp_override_rejected(self):
  (self.d/'etc/url.conf').write_text(f'portal://{self.key}@127.0.0.1:2083')
  r=self.runsh(3,'VERSION=v3.1.0; MORPH_UDP_PRELUDE=low7; write_unit');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'unit.service').exists())
 def test_old_core_tls_egress_preview_rejected(self):
  (self.d/'opt/current/RELEASE-INFO').write_text('tag: v3.1.0\n')
  r=self.runsh(3,'URL_INPUT="$(read_url)"; preview_action');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'unit.service').exists())
 def test_prerelease_selection_preserved(self):
  (self.d/'releases.json').write_text(json.dumps([{'tag_name':'v3.4.0-beta.1','prerelease':True},{'tag_name':'v3.3.0','prerelease':False}]))
  for channel,expected in [('latest-v3','v3.3.0'),('latest-v3-prerelease','v3.4.0-beta.1')]:
   r=self.runsh(3,'curl_github() { cp "$SB/releases.json" "$2"; }; VERSION='+channel+'; resolve_version; [[ "$VERSION" == '+expected+' ]]');self.assertEqual(r.returncode,0,r.stderr)
 def test_explicit_prerelease_flag_preserved(self):
  r=self.runsh(3,'ALLOW_PRERELEASE=1; validate_version_arg v3.4.0-beta.1');self.assertEqual(r.returncode,0,r.stderr)
 def test_upgrade_warning_redacts_key(self):
  r=self.runsh(3,'warn_core_upgrade "$(read_url)"');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('3.1.0',r.stderr);self.assertNotIn(self.key,r.stderr)
 def test_fingerprint_budget_covers_new_handshake_default(self):
  r=self.runsh(3,"""timeout() { [[ \"$1\" == 60 ]] || return 99; printf '%064d' 0; }; remote_fingerprint 'nowhere://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@127.0.0.1:2083?morph=1'""")
  self.assertEqual(r.returncode,0,r.stderr)
 def test_prerelease_core_is_not_stable_for_tls_egress(self):
  for url in [f'egress://{self.key}@127.0.0.1/tcp:2083',f'portal://{self.key}@*/tcp:2083?out=egress']:
   r=self.runsh(3,f'v3_url validate-core "{url}" v3.3.0-rc.1');self.assertNotEqual(r.returncode,0,url)
   r=self.runsh(3,f'v3_url validate-core "{url}" v3.3.0');self.assertEqual(r.returncode,0,r.stderr)
   r=self.runsh(3,f'v3_url validate-core "{url}" v3.4.0-rc.1');self.assertEqual(r.returncode,0,r.stderr)
 def test_links_fail_closed_for_prerelease_or_missing_core(self):
  url=f'portal://{self.key}@*/tcp:2083/udp:2083?out=egress';pin='b'*64
  for core in ['v3.3.0-rc.1','']:
   r=self.runsh(3,f'v3_url links "{url}" example.test {pin} {core}'.rstrip())
   self.assertEqual(r.returncode,0,r.stderr);lines=[x for x in r.stdout.splitlines() if x.startswith('Egress:')]
   self.assertFalse(any('/tcp:' in x for x in lines),core or 'omitted');self.assertTrue(any('/udp:' in x for x in lines))
  r=self.runsh(3,f'v3_url links "{url}" example.test {pin} v3.4.0-rc.1');self.assertEqual(r.returncode,0,r.stderr)
  self.assertTrue(any('/tcp:' in x for x in r.stdout.splitlines() if x.startswith('Egress:')))
 def test_udp_option_error_names_its_flag(self):
  r=self.runsh(3,f'main validate --url "portal://{self.key}@127.0.0.1:2083" --morph-udp-prelude bogus');self.assertNotEqual(r.returncode,0)
  self.assertIn('morph-udp-prelude',r.stderr+r.stdout)
 def release(self,ver,name,mtime):
  d=self.d/'opt/releases'/name;d.mkdir(parents=True,exist_ok=True)
  (d/'RELEASE-INFO').write_text(f'tag: {ver}\n')
  n=d/'nowhere';n.write_text(f'#!/bin/sh\necho nowhere-{ver} linux/x86_64\n');n.chmod(0o755)
  os.utime(d,(mtime,mtime));return d
 def test_rollback_refuses_tls_egress_on_old_core(self):
  old=self.release('v3.1.0','v3.1.0-release-aaaaaaaaaaaa',1000);new=self.release('v3.3.0','v3.3.0-release-bbbbbbbbbbbb',2000)
  cur=self.d/'opt/current'
  if cur.is_symlink() or cur.is_file():cur.unlink()
  elif cur.exists():shutil.rmtree(cur)
  cur.symlink_to(new,target_is_directory=True)
  (self.d/'etc/url.conf').write_text(f'portal://{self.key}@*/tcp:2083?out=egress')
  r=self.runsh(3,'rollback_action');self.assertNotEqual(r.returncode,0,r.stderr)
  self.assertEqual(os.path.realpath(cur),os.path.realpath(new));self.assertTrue(old.is_dir())
 def test_install_refuses_tls_egress_before_asset_selection(self):
  (self.d/'etc/url.conf').write_text(f'portal://{self.key}@*/tcp:2083?out=egress')
  (self.d/'release.json').write_text(json.dumps({'tag_name':'v3.1.0','prerelease':False,'draft':False}))
  r=self.runsh(3,'curl_github() { cp "$SB/release.json" "$2"; }; target_triple() { touch "$SB/ASSET_SELECTION"; }; VERSION=v3.1.0; install_release')
  self.assertNotEqual(r.returncode,0,r.stderr);self.assertFalse((self.d/'ASSET_SELECTION').exists())
 def test_build_tcp_egress_roundtrip(self):
  r=self.runsh(3,f'u=$(v3_url build egress {self.key} relay.example/tcp:2000 1 direct "" "" "" "" ""); v3_url validate "$u" >/dev/null && printf "%s" "$u"')
  self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout.strip(),f'egress://{self.key}@relay.example/tcp:2000?morph=1')
 def test_rollback_switches_to_previous_release_under_symlinked_root(self):
  import shutil as sh
  real=self.d/'opt/realreleases';real.mkdir(parents=True)
  sh.rmtree(self.d/'opt/releases');(self.d/'opt/releases').symlink_to(real,target_is_directory=True)
  old=self.release('v3.1.0','v3.1.0-release-aaaaaaaaaaaa',1000);new=self.release('v3.3.0','v3.3.0-release-bbbbbbbbbbbb',2000)
  cur=self.d/'opt/current'
  if cur.is_symlink() or cur.is_file():cur.unlink()
  elif cur.exists():shutil.rmtree(cur)
  cur.symlink_to(os.path.realpath(new),target_is_directory=True)
  (self.d/'etc/url.conf').write_text(f'portal://{self.key}@*:2083\n')
  r=self.runsh(3,'rollback_action');self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual(os.path.realpath(cur),os.path.realpath(old))
 def test_cleanup_keeps_active_release_under_symlinked_root(self):
  import shutil as sh
  real=self.d/'opt/realreleases';real.mkdir(parents=True)
  sh.rmtree(self.d/'opt/releases');(self.d/'opt/releases').symlink_to(real,target_is_directory=True)
  active=self.release('v3.1.0','v3.1.0-release-aaaaaaaaaaaa',1000)
  for i,(ver,mt) in enumerate([('v3.2.0',2000),('v3.2.1',3000),('v3.3.0',4000),('v3.3.1',5000)]):self.release(ver,f'{ver}-release-{i:012d}',mt)
  cur=self.d/'opt/current'
  if cur.is_symlink() or cur.is_file():cur.unlink()
  elif cur.exists():shutil.rmtree(cur)
  cur.symlink_to(os.path.realpath(active),target_is_directory=True)
  r=self.runsh(3,'KEEP_RELEASES=3; cleanup_old_releases');self.assertEqual(r.returncode,0,r.stderr)
  self.assertTrue(os.path.isdir(os.path.realpath(cur)),'active release was pruned')
if __name__=='__main__':unittest.main(verbosity=2)

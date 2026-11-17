import unittest,pathlib,importlib.util
spec=importlib.util.spec_from_file_location('fixes',pathlib.Path(__file__).with_name('test_fixes.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Fix152(unittest.TestCase):
 setUp=m.Fixes.setUp
 tearDown=m.Fixes.tearDown
 runsh=m.Fixes.runsh
 def test_duplicates(self):
  for query in ['morph=1&morph=0','morph=1&%6dorph=0','out=direct&out=egress','tls=0&tls=1']:
   r=self.runsh(3,'v3_url validate "portal://'+'a'*32+'@*:2083?'+query+'"');self.assertNotEqual(r.returncode,0);self.assertIn('重复',r.stderr)
 def test_meta_atomic_failure(self):
  f=self.d/'etc/manager.conf';f.write_text('original\n')
  r=self.runsh(3,'publish_file() { return 1; }; write_meta');self.assertNotEqual(r.returncode,0);self.assertEqual(f.read_text(),'original\n')
 def test_meta_success(self):
  r=self.runsh(3,'write_meta');self.assertEqual(r.returncode,0,r.stderr)
  f=self.d/'etc/manager.conf';self.assertRegex(f.read_text(),r'SCRIPT_VERSION=\d+\.\d+\.\d+');self.assertEqual(f.stat().st_mode&0o777,0o640)
 def update(self,fail=False,runner=True):
  d=self.d/'opt/manager';d.mkdir();f=d/'nowhere-v3.sh'
  if runner:f.write_text('old-runner')
  src=self.d/'v3.sh';(self.d/'remote').write_text(src.read_text().replace(next(line for line in src.read_text().splitlines() if line.startswith('readonly SCRIPT_VERSION=')), 'readonly SCRIPT_VERSION="99.0.0"'))
  self.env['NOWHERE_V3_SELF_URL']='https://example.test/script'
  body='''ASSUME_YES=1
curl() { local out; while (($#)); do if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi; done; cp "$SB/remote" "$out"; }
install_shortcut() { :; }
'''
  if fail:body+='''eval "$(declare -f publish_file | sed '1s/publish_file/real_publish_file/')"
publish_file() { [[ "$2" != "$INSTALL_ROOT/manager/nowhere-v3.sh" ]] || return 1; real_publish_file "$@"; }
'''
  r=self.runsh(3,body+'self_update')
  return r,f,src
 def test_update_sync(self):
  r,f,src=self.update();self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(f.read_bytes(),src.read_bytes());self.assertEqual(f.stat().st_mode&0o777,0o700)
 def test_update_sync_failure_visible(self):
  r,f,src=self.update(True);self.assertNotEqual(r.returncode,0);self.assertEqual(f.read_text(),'old-runner');self.assertTrue(list(self.d.glob('v3.sh.bak.*')));self.assertIn('cert-timer',r.stderr)
 def test_update_no_timer_created(self):
  r,f,src=self.update(runner=False);self.assertEqual(r.returncode,0,r.stderr);self.assertFalse(f.exists())
 def test_prerelease_guard_retained(self):
  r=self.runsh(3,'v3_url validate-core "egress://'+'a'*32+'@example.test/tcp:443" v3.3.0-rc.1');self.assertNotEqual(r.returncode,0)
if __name__=='__main__':unittest.main(verbosity=2)

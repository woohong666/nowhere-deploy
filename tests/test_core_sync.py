#!/usr/bin/env python3
import unittest,pathlib,importlib.util,json
spec=importlib.util.spec_from_file_location('fixes',pathlib.Path(__file__).with_name('test_fixes.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class CoreSync(unittest.TestCase):
 setUp=m.Fixes.setUp
 tearDown=m.Fixes.tearDown
 runsh=m.Fixes.runsh
 def test_stable_default_and_preserved_policy(self):
  r=self.runsh(3,'[[ "$DEFAULT_CORE_VERSION" == v3.1.0 && "$MORPH_PRELUDE" == full8 ]]');self.assertEqual(r.returncode,0)
 def test_prelude_modes(self):
  r=self.runsh(3,'validate_morph_prelude fade; validate_morph_prelude full8; validate_morph_prelude low7');self.assertEqual(r.returncode,0)
  r=self.runsh(3,'validate_morph_prelude INVALID');self.assertNotEqual(r.returncode,0)
 def test_fade_unit_current_core(self):
  r=self.runsh(3,'MORPH_PRELUDE=fade; VERSION=v3.1.0; write_unit');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('NOW_MORPH_TCP_PRELUDE=fade',(self.d/'unit.service').read_text())
 def test_fade_old_core_rejected_without_unit_write(self):
  r=self.runsh(3,'MORPH_PRELUDE=fade; VERSION=v3.0.0; write_unit');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'unit.service').exists())
 def test_full8_old_core_kept(self):
  r=self.runsh(3,'MORPH_PRELUDE=full8; VERSION=v3.0.0; write_unit');self.assertEqual(r.returncode,0,r.stderr)
 def test_existing_meta_policy_kept(self):
  (self.d/'etc/manager.conf').write_text('MORPH_PRELUDE=low7\n');r=self.runsh(3,'load_meta; [[ "$MORPH_PRELUDE" == low7 ]]');self.assertEqual(r.returncode,0)
 def test_latest_excludes_actual_prerelease(self):
  (self.d/'releases.json').write_text(json.dumps([{'tag_name':'v3.2.0','prerelease':True},{'tag_name':'v3.1.0','prerelease':False},{'tag_name':'v2.2.1','prerelease':False}]))
  r=self.runsh(3,'curl_github() { cp "$SB/releases.json" "$2"; }; VERSION=latest-v3; resolve_version; [[ "$VERSION" == v3.1.0 ]]');self.assertEqual(r.returncode,0,r.stderr)
 def test_explicit_prerelease_rejected_before_download(self):
  (self.d/'release.json').write_text(json.dumps({'tag_name':'v3.2.0','prerelease':True,'draft':False}))
  r=self.runsh(3,'curl_github() { cp "$SB/release.json" "$2"; }; target_triple() { touch "$SB/ASSET_SELECTION"; }; VERSION=v3.2.0; install_release');self.assertNotEqual(r.returncode,0);self.assertFalse((self.d/'ASSET_SELECTION').exists())
if __name__=='__main__':unittest.main(verbosity=2)

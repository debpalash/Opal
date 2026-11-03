#!/usr/bin/env python3
"""Exercise the actual detached helper on owned fixtures; never touches /Applications."""
import os, pathlib, subprocess, tempfile, time, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
HELPER=ROOT/'src/services/updater_install_macos.sh'
class Install(unittest.TestCase):
 def bundle(self,path,body):
  exe=path/'Contents/MacOS/Opal';exe.parent.mkdir(parents=True);exe.write_text('#!/bin/sh\n'+body+'\n');exe.chmod(0o700)
 def run_case(self,works):
  with tempfile.TemporaryDirectory(prefix='opal-update-fixture-') as raw:
   root=pathlib.Path(raw);target=root/'Opal with spaces.app';stage=root/'.opal-update.owned';stage.mkdir()
   self.bundle(target,'exit 0')
   (target/'Contents/old-marker').write_text('original')
   self.bundle(stage/'Opal.app', 'printf ready > "$OPAL_UPDATE_ACK"; exit 0' if works else 'exit 1')
   (stage/'Opal.app/Contents/new-marker').write_text('new')
   parent=subprocess.Popen(['sleep','20'])
   child=subprocess.Popen(['/bin/sh',str(HELPER),str(parent.pid),str(target),str(stage),'2'],env={**os.environ,'OPAL_UPDATE_TEST':'1'},stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
   try:
    time.sleep(.2);self.assertTrue((target/'Contents/old-marker').exists(),'must wait for user-approved parent shutdown')
    parent.terminate();parent.wait(timeout=2)
    _,error=child.communicate(timeout=8)
    if works:
     self.assertEqual(child.returncode,0,error);self.assertTrue((target/'Contents/new-marker').exists());self.assertFalse(stage.exists())
    else:
     self.assertNotEqual(child.returncode,0);self.assertTrue((target/'Contents/old-marker').exists());self.assertTrue((stage/'failed.app/Contents/new-marker').exists())
   finally:
    if parent.poll() is None:parent.kill();parent.wait()
    if child.poll() is None:child.kill();child.wait()
 def test_wait_swap_reopen_ack_and_cleanup(self):self.run_case(True)
 def test_failed_launch_restores_previous_app(self):self.run_case(False)
@unittest.skipUnless(__import__('sys').platform == 'darwin', 'macOS bundle staging')
class Staging(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  import ctypes
  cls.temporary=tempfile.TemporaryDirectory(prefix='opal-native-update-')
  cls.root=pathlib.Path(cls.temporary.name)
  lib=cls.root/'updater.dylib'
  subprocess.run(['clang','-dynamiclib','-fobjc-arc','-framework','Foundation',str(ROOT/'src/macos/updater.m'),'-o',str(lib)],check=True,capture_output=True)
  cls.api=ctypes.CDLL(str(lib))
  cls.api.opal_update_prepare.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t]
  cls.api.opal_update_prepare.restype=ctypes.c_size_t
  cls.api.opal_update_discard.argtypes=[ctypes.c_char_p]
 @classmethod
 def tearDownClass(cls):cls.temporary.cleanup()
 def test_signed_bundle_is_staged_without_replacing_installed_app(self):
  import ctypes, plistlib, shutil
  with tempfile.TemporaryDirectory(dir=self.root) as raw:
   root=pathlib.Path(raw);target=root/'Installed with spaces.app';new=root/'new/Opal.app'
   for app,version in ((target,'0.9.2'),(new,'0.9.3')):
    exe=app/'Contents/MacOS/Opal';exe.parent.mkdir(parents=True);shutil.copy('/usr/bin/true',exe)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.debpalash.opal','CFBundleExecutable':'Opal','CFBundleShortVersionString':version,'CFBundlePackageType':'APPL'}))
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
   archive=root/'update.zip'
   subprocess.run(['ditto','-c','-k','--keepParent',str(new),str(archive)],check=True)
   out=ctypes.create_string_buffer(2048)
   self.assertEqual(self.api.opal_update_prepare(os.fsencode(archive),os.fsencode(target),b'9.9.9',out,len(out)),0,'wrong release must not stage')
   self.assertGreater(self.api.opal_update_prepare(os.fsencode(archive),os.fsencode(target),b'0.9.3',out,len(out)),0)
   stage=pathlib.Path(os.fsdecode(out.value));self.assertTrue((stage/'Opal.app/Contents/MacOS/Opal').exists())
   self.assertEqual(plistlib.loads((target/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'],'0.9.2')
   self.api.opal_update_discard(os.fsencode(stage));self.assertFalse(stage.exists())
 def test_archive_path_traversal_rejected(self):
  import ctypes, plistlib, zipfile
  with tempfile.TemporaryDirectory(dir=self.root) as raw:
   root=pathlib.Path(raw);target=root/'Opal.app';exe=target/'Contents/MacOS/Opal';exe.parent.mkdir(parents=True);exe.write_text('#!/bin/sh\nexit 0\n');exe.chmod(0o700)
   (target/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.debpalash.opal'}))
   archive=root/'bad.zip'
   with zipfile.ZipFile(archive,'w') as z:z.writestr('Opal.app/../../escape','no')
   out=ctypes.create_string_buffer(2048)
   self.assertEqual(self.api.opal_update_prepare(os.fsencode(archive),os.fsencode(target),b'0.9.3',out,len(out)),0)
   self.assertFalse((root/'escape').exists())

if __name__=='__main__':unittest.main()


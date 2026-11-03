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
 def test_health_ack_preserves_child_environment_snapshot(self):
  # Zig captures the libc environment table at startup. Removing an entry
  # later invalidates its saved length while background children are spawning.
  probe = """
import ctypes, os, pathlib
libc=ctypes.CDLL(None)
libc._NSGetEnviron.restype=ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p))
saved=libc._NSGetEnviron().contents
count=0
while saved[count] is not None: count+=1
api=ctypes.CDLL(os.environ['OPAL_ACK_TEST_LIB'])
api.opal_update_ack()
assert pathlib.Path(os.environ['OPAL_ACK_TEST_PATH']).exists(), 'healthy frame was not acknowledged'
assert all(saved[i] is not None for i in range(count)), 'ACK invalidated the cached child environment table'
"""
  with tempfile.TemporaryDirectory(dir=self.root) as raw:
   stage=pathlib.Path(raw)/'.opal-update.environment';stage.mkdir()
   env={**os.environ,'OPAL_ACK_TEST_LIB':str(self.root/'updater.dylib'),'OPAL_ACK_TEST_PATH':str(stage/'ready'),'OPAL_UPDATE_ACK':str(stage/'ready')}
   result=subprocess.run([__import__('sys').executable,'-c',probe],env=env,capture_output=True,text=True,timeout=10)
   self.assertEqual(result.returncode,0,(result.stderr or result.stdout)[-1200:])
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

@unittest.skipUnless(__import__('sys').platform == 'darwin' and os.environ.get('OPAL_TEST_UPDATE_APP'), 'set OPAL_TEST_UPDATE_APP to a built macOS app')
class RealApp(unittest.TestCase):
 def test_actual_app_reopens_and_survives_healthy_ack(self):
  import re, shutil, signal, plistlib
  source=pathlib.Path(os.environ['OPAL_TEST_UPDATE_APP']).resolve()
  self.assertTrue((source/'Contents/MacOS/Opal').is_file())
  root=pathlib.Path(tempfile.mkdtemp(prefix='opal-real-restart-'))
  target=root/'Opal.app';stage=root/'.opal-update.real-launch';stage.mkdir()
  old=target/'Contents/MacOS/Opal';old.parent.mkdir(parents=True);old.write_text('#!/bin/sh\nexit 0\n');old.chmod(0o700)
  subprocess.run(['ditto',str(source),str(stage/'Opal.app')],check=True)
  parent=subprocess.Popen(['sleep','30']);new_pid=None;success=False
  env={**os.environ,'OPAL_UPDATE_TEST':'1','XDG_CONFIG_HOME':str(root/'config'),'XDG_CACHE_HOME':str(root/'cache'),'XDG_DATA_HOME':str(root/'data')}
  helper=subprocess.Popen(['/bin/sh','-x',str(HELPER),str(parent.pid),str(target),str(stage),'20'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  try:
   time.sleep(.2);parent.terminate();parent.wait(timeout=2)
   _,trace=helper.communicate(timeout=30)
   match=re.search(rb'new_pid=(\d+)',trace);self.assertIsNotNone(match,trace[-1500:]);new_pid=int(match[1])
   self.assertEqual(helper.returncode,0,trace[-1500:]);self.assertFalse(stage.exists(),'no healthy GUI acknowledgement')
   self.assertEqual(plistlib.loads((target/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'],plistlib.loads((source/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'])
   # The environment race used to crash AFTER acknowledging the GUI.
   time.sleep(6);os.kill(new_pid,0)
   process=subprocess.run(['ps','-p',str(new_pid),'-o','comm='],capture_output=True,text=True,check=True)
   self.assertIn('Opal',process.stdout)
   success=True
  finally:
   if parent.poll() is None:parent.kill();parent.wait()
   if helper.poll() is None:helper.kill();helper.wait()
   # Only fixture-owned processes, including sidecars from this temporary app.
   children=subprocess.run(['pgrep','-f',re.escape(str(root))],capture_output=True,text=True)
   for value in children.stdout.split():
    try:os.kill(int(value),signal.SIGTERM)
    except ProcessLookupError:pass
   time.sleep(.5)
   if success:shutil.rmtree(root)
   else:print('Retained failed restart fixture:',root)

if __name__=='__main__':unittest.main()


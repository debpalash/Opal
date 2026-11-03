"""Release visual gate: actual files, tags, paths and note output."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_media', ROOT/'scripts/release-media.py')
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)
class Visuals(unittest.TestCase):
    def test_current_release_files_and_tag_pinned_notes(self):
        import re
        version = re.search(r'\.version = "([^"]+)"', (ROOT/'build.zig.zon').read_text())[1]
        data = media.load('v'+version)
        text = media.markdown(data)
        self.assertIn(f'/Opal/v{version}/assets/releases/v{version}/', text)
        self.assertNotIn('/main/', text)
    def test_cancelled_candidate_does_not_hide_features_from_next_release(self):
        import shutil, subprocess
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);(root/'scripts').mkdir()
            for name in ('release-notes.sh','release-media.py'):shutil.copy(ROOT/'scripts'/name,root/'scripts'/name)
            def git(*args):return subprocess.run(['git',*args],cwd=root,capture_output=True,text=True,check=True)
            git('init');git('config','user.name','Release fixture');git('config','user.email','fixture@example.invalid')
            def commit(text,tag):
                (root/'fixture').write_text(text);git('add','.');git('commit','-m',text);git('tag',tag)
            commit('Published baseline','v1.0.0')
            commit('Feature from cancelled candidate','v1.0.1')
            (root/'CHANGELOG.md').write_text('## v1.0.2 — today\nFeatures plus restart fix.\n## v1.0.1 — today (unpublished)\nCandidate cancelled.\n')
            commit('Fix restart','v1.0.2')
            result=subprocess.run(['sh','scripts/release-notes.sh','v1.0.2'],cwd=root,capture_output=True,text=True,check=True)
            self.assertIn('compare/v1.0.0...v1.0.2',result.stdout)
            self.assertIn('Feature from cancelled candidate',result.stdout)
    def test_missing_stale_traversal_and_invalid_images_block_release(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);folder=root/'docs/releases/v1.2.3';folder.mkdir(parents=True)
            manifest=folder/'media.json'
            with self.assertRaises(FileNotFoundError):media.load('v1.2.3',root)
            data={'tag':'v1.2.2','items':[{'path':'assets/releases/v1.2.3/a.png','alt':'Feature','caption':'Demo'}]}
            manifest.write_text(json.dumps(data))
            with self.assertRaises(ValueError):media.load('v1.2.3',root)
            data['tag']='v1.2.3';data['items'][0]['path']='../../outside.png';manifest.write_text(json.dumps(data))
            with self.assertRaises(ValueError):media.load('v1.2.3',root)
            data['items'][0]['path']='assets/releases/v1.2.3/a.png';manifest.write_text(json.dumps(data))
            asset=root/data['items'][0]['path'];asset.parent.mkdir(parents=True);asset.write_bytes(b'not a PNG')
            with self.assertRaises(ValueError):media.load('v1.2.3',root)
            asset.write_bytes(b'\x89PNG\r\n\x1a\n'+b'\0'*8+struct.pack('>II',100,100))
            with self.assertRaises(ValueError):media.load('v1.2.3',root)
if __name__=='__main__':unittest.main()

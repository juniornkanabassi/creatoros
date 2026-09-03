import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('notion-backup.py'))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class BackupChecks(unittest.TestCase):
    def test_matching_preserves_title_dashes(self):
        self.assertTrue(backup.title_matches('185 - Long - Goal FanZone Shoot – Fan Jury Reaction',
                                            'Goal FanZone Shoot – Fan Jury Reaction', ''))

    def test_unicode_and_punctuation(self):
        self.assertTrue(backup.title_matches('168 — Short — Doué’s video', "Doué's video", ''))

    def test_campaign(self):
        self.assertTrue(backup.title_matches('001 — Short — DAZN48 — Canada', 'Canada', 'DAZN48'))
        self.assertFalse(backup.title_matches('001 — Short — Other — Canada', 'Canada', 'DAZN48'))

    def test_different_title_rejected(self):
        self.assertFalse(backup.title_matches('003 - Podcast - UCL Semi-Final Analysis',
                                             '2023/24 UCL Quarter-Finals', ''))

    def test_paths(self):
        for name in ['../escape', '/escape', 'safe/../../escape', 'safe\\escape']:
            self.assertFalse(backup.safe_relative(name))
        self.assertTrue(backup.safe_relative('Shorts/Notes with spaces.md'))

    def test_parentheses_in_export_links(self):
        self.assertEqual(backup.links('[Script](Preview%20(feat%20Guest)/Script.md)'),
                         ['Preview%20(feat%20Guest)/Script.md'])
        parent = 'Podcasts/Preview abc.md'
        files = {parent: b'[Script](Preview%20(feat%20Guest)/Script.md)',
                 'Podcasts/Preview (feat Guest)/Script.md': b'Actual script'}
        payload, missing = backup.linked_files(files, parent)
        self.assertEqual(len(payload), 2)
        self.assertFalse(missing)
        self.assertEqual(backup.links('[Script](Preview%20(feat%20Guest/Script.md)'),
                         ['Preview%20(feat%20Guest/Script.md'])

    def test_zip_traversal_rejected(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            z.writestr('../escape', 'no')
        with zipfile.ZipFile(data) as z:
            with self.assertRaises(ValueError):
                backup.archive_files(z)

    def test_link_closure_and_attachments(self):
        parent = 'Shorts/Test abc.md'
        files = {parent: b'# Test\n[Notes](Test/Notes.md)',
                 'Shorts/Test/Notes.md': b'# Notes\n![pic](image.png)\n[remote](https://example.com)',
                 'Shorts/Test/image.png': b'example bytes',
                 'Shorts/Unrelated.md': b'not part of this project'}
        payload, missing = backup.linked_files(files, parent)
        self.assertEqual(set(payload), set(files) - {'Shorts/Unrelated.md'})
        self.assertEqual(payload['Shorts/Test/image.png'], b'example bytes')
        self.assertEqual(missing, [])

    def test_csv_row_order_is_not_a_difference(self):
        files = {'View.csv': b'Name,Status\nA,Writing\nB,Idea\n',
                 'View_all.csv': b'Status,Name\nIdea,B\nWriting,A\n'}
        self.assertEqual(len(backup.rows_from(files, 'test')), 2)
        files['View_all.csv'] = b'Name,Status\nA,Published\n'
        with self.assertRaises(ValueError):
            backup.rows_from(files, 'test')

    def test_exclusive_and_idempotent(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as d:
            p = Path(d) / 'notes.md'
            self.assertTrue(backup.exclusive(p, b'original'))
            self.assertFalse(backup.exclusive(p, b'original'))
            with self.assertRaises(ValueError):
                backup.exclusive(p, b'changed')
            self.assertEqual(p.read_bytes(), b'original')

    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as d:
            target = Path(d) / 'actual'
            target.mkdir()
            link = Path(d) / 'link'
            link.symlink_to(target, target_is_directory=True)
            with self.assertRaises(ValueError):
                backup.exclusive(link / 'notes.md', b'no')
            self.assertFalse((target / 'notes.md').exists())


if __name__ == '__main__':
    unittest.main()

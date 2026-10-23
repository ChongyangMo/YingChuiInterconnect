import argparse
import base64
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from build_update import build_release, release_details
from release_history import ReleaseHistory, build_lock, inspect_package


def package(root, display='1.0', build='4', bad_digest=False, channel='beta'):
    output = root / ('build-' + build) / 'package'
    output.mkdir(parents=True, exist_ok=True)
    archive = b'unit-test-archive'
    signature = base64.b64encode(bytes(64)).decode()
    metadata = {'bundle_id': 'com.yingchui.interconnect.mac', 'app_version': display, 'app_build': build,
                'channel': channel, 'filename': 'app.zip', 'ed_signature': signature,
                'sha256': 'f' * 64 if bad_digest else hashlib.sha256(archive).hexdigest(), 'size_bytes': len(archive)}
    result = output / ('Yingchui-Mac-' + build + '.ycu')
    with zipfile.ZipFile(result, 'x') as archive_file:
        archive_file.writestr('metadata.json', json.dumps(metadata))
        archive_file.writestr('metadata.sig', signature)
        archive_file.writestr('app.zip', archive)
    return result


class ReleaseHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)

    def history(self):
        return ReleaseHistory(self.root, '1.0', '1')

    def test_next_version_uses_real_artifact_and_project_baseline(self):
        package(self.root)
        self.assertEqual(self.history().propose(), ('1.0.1', '5'))
        self.assertEqual(ReleaseHistory(self.root, '2.3', '10').propose(), ('2.3.1', '11'))

    def test_empty_history_requires_valid_real_project_values(self):
        self.assertEqual(self.history().propose(), ('1.0.1', '2'))
        for display, build in [(None, '1'), ('', '1'), ('beta', '1'), ('1.0', '')]:
            with self.assertRaises(ValueError):
                ReleaseHistory(self.root, display, build)

    def test_display_patch_increments_after_success_and_reopening(self):
        package(self.root)
        history = self.history()
        new = package(self.root, '1.0.1', '5')
        history.record_success(new, '1.0.1', '5', 'beta')
        self.assertEqual(self.history().propose(), ('1.0.2', '6'))
        self.assertEqual(len(json.loads(history.state_path.read_text())['releases']), 2)

    def test_unified_release_preserves_signed_legacy_history(self):
        old = package(self.root, '1.0.1', '4', channel='beta')
        before = old.read_bytes()
        history = self.history()
        new = package(self.root, '1.0.2', '5', channel='unified')
        history.record_success(new, '1.0.2', '5', 'unified')
        self.assertEqual(old.read_bytes(), before)
        self.assertEqual(self.history().propose(), ('1.0.3', '6'))
        self.assertEqual([r['channel'] for r in json.loads(history.state_path.read_text())['releases']], ['beta', 'unified'])

    def test_failed_and_occupied_directories_reserve_build_only(self):
        package(self.root)
        (self.root / 'build-8').mkdir()
        (self.root / 'failed-build-9-compile').mkdir()
        self.assertEqual(self.history().propose(), ('1.0.1', '10'))

    def test_explicit_overrides_must_increase_both_values(self):
        package(self.root)
        self.assertEqual(self.history().propose('2', '20'), ('2.0.0', '20'))
        for display, build in [('1.0', None), (None, '4'), ('01.1', None), ('1.0.1.2', None), (None, '5a')]:
            with self.assertRaises(ValueError):
                self.history().propose(display, build)

    def test_damaged_history_and_duplicate_json_fields_fail(self):
        for value in ['破损', '{"schema":1,"schema":1,"releases":[]}', '{"schema":2,"releases":[]}', '{"schema":true,"releases":[]}']:
            (self.root / 'release-history.json').write_text(value)
            with self.assertRaises(ValueError):
                self.history()

    def test_repeated_success_record_is_rejected(self):
        record = inspect_package(package(self.root))
        (self.root / 'release-history.json').write_text(json.dumps({'schema': 1, 'releases': [record, record]}))
        with self.assertRaisesRegex(ValueError, '重复构建'):
            self.history()

    def test_corrupt_package_and_invalid_directory_fail(self):
        bad = package(self.root, bad_digest=True)
        with self.assertRaises(ValueError):
            self.history()
        bad.unlink()
        (self.root / 'build-broken').mkdir()
        with self.assertRaises(ValueError):
            self.history()

    def test_committed_record_and_changed_package_conflict(self):
        history = self.history()
        new = package(self.root, '1.0.1', '2')
        history.record_success(new, '1.0.1', '2', 'beta')
        new.unlink()
        package(self.root, '1.0.2', '2')
        with self.assertRaises(ValueError):
            self.history()

    def test_archived_package_keeps_committed_version_history(self):
        history = self.history()
        new = package(self.root, '1.0.1', '2')
        history.record_success(new, '1.0.1', '2', 'beta')
        new.unlink()
        self.assertEqual(self.history().propose(), ('1.0.2', '3'))

    def test_mismatched_generated_metadata_does_not_write_success(self):
        history = self.history()
        new = package(self.root, '1.0.1', '2')
        with self.assertRaises(ValueError):
            history.record_success(new, '1.0.2', '2', 'beta')
        self.assertFalse(history.state_path.exists())

    def test_failed_compile_does_not_advance_success_record(self):
        package(self.root)
        history = self.history()
        def fail(*args):
            raise RuntimeError('测试编译失败')
        with self.assertRaises(RuntimeError):
            build_release(self.root, self.root, {'channel': 'beta'}, history, '1.0.1', '5', '说明', fail)
        self.assertFalse(history.state_path.exists())
        self.assertEqual(self.history().propose(), ('1.0.1', '6'))
        self.assertEqual(json.loads((self.root / 'build-5/attempt.json').read_text())['status'], 'failed')

    def test_failed_commit_preserves_previous_record_and_reserves_build(self):
        package(self.root)
        history = self.history()
        new = package(self.root, '1.0.1', '5')
        history.record_success(new, '1.0.1', '5', 'beta')
        original = history.state_path.read_bytes()
        def compile_test(root, script, config, display, build, notes, output):
            return package(root, display, build, channel='unified')
        with mock.patch('release_history.os.replace', side_effect=OSError('测试原子提交失败')):
            with self.assertRaises(OSError):
                build_release(self.root, self.root, {'channel': 'beta'}, history, '1.0.2', '6', '说明', compile_test)
        self.assertEqual(history.state_path.read_bytes(), original)
        self.assertEqual(self.history().propose(), ('1.0.2', '7'))

    def test_crash_with_complete_package_but_uncommitted_record_fails_clearly(self):
        package(self.root, '1.0.1', '5')
        (self.root / 'build-5/attempt.json').write_text(json.dumps({'version': '1.0.1', 'build': '5', 'status': 'running'}))
        with self.assertRaisesRegex(ValueError, '尚未提交'):
            self.history()

    def test_successful_pipeline_commits_exact_package_values(self):
        history = self.history()
        def compile_test(root, script, config, display, build, notes, output):
            return package(root, display, build, channel='unified')
        result = build_release(self.root, self.root, {'channel': 'beta'}, history, '1.0.1', '2', '说明', compile_test)
        self.assertEqual(inspect_package(result)['version'], '1.0.1')
        self.assertEqual(inspect_package(result)['channel'], 'unified')
        self.assertEqual(self.history().propose(), ('1.0.2', '3'))

    def test_double_click_prompts_for_version_with_default_and_notes_only(self):
        package(self.root)
        prompts, displayed, answers = [], [], iter(['', '修复问题'])
        def ask(prompt):
            prompts.append(prompt)
            return next(answers)
        result = release_details(self.history(), argparse.Namespace(version=None, build=None, notes=None), ask, displayed.append)
        self.assertEqual(result, ('1.0.1', '5', '修复问题'))
        self.assertEqual(prompts, ['发布版本号 [1.0.1]：', '更新说明：'])
        self.assertEqual(displayed, ['构建号：5（自动）'])

    def test_noninteractive_notes_uses_both_automatic_values(self):
        package(self.root)
        def forbidden(prompt):
            self.fail('命令行完整说明不应触发交互')
        self.assertEqual(release_details(self.history(), argparse.Namespace(version=None, build=None, notes='更新'), forbidden, lambda _: None),
                         ('1.0.1', '5', '更新'))
        with self.assertRaises(ValueError):
            release_details(self.history(), argparse.Namespace(version=None, build=None, notes=' '), forbidden, lambda _: None)

    def test_parallel_process_cannot_acquire_same_build_lock(self):
        code = "import pathlib,sys; sys.path.insert(0,sys.argv[1]); from release_history import build_lock;\nwith build_lock(pathlib.Path(sys.argv[2])): print('意外取得锁')"
        with build_lock(self.root):
            result = subprocess.run([sys.executable, '-c', code, str(pathlib.Path(__file__).resolve().parents[1]), str(self.root)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('另一个打包任务正在运行', result.stderr)
        with build_lock(self.root):
            pass


if __name__ == '__main__':
    unittest.main()

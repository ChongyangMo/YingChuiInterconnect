import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import ExitStack
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import build_update
from test_release_history import package


class AutoUploadEntryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.script = self.root / 'scripts/mac-updates'
        self.script.mkdir(parents=True)
        (self.script / 'build-config.json').write_text(json.dumps({
            'channel': 'beta', 'architecture': 'arm64', 'signing_identity': 'test-identity',
            'upload': {'base_url': 'https://deploy.chongyang.asia', 'timeout_seconds': 180}
        }))
        self.package = package(self.root / 'artifacts/mac-updates', '1.0.1', '2')

    def run_main(self, args, pending=None, fail_upload=False):
        events = []
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(build_update, '__file__', str(self.script / 'build_update.py')))
            stack.enter_context(mock.patch.object(sys, 'argv', ['build_update.py'] + args))
            stack.enter_context(mock.patch.object(build_update, 'pending_package', return_value=pending))
            signing = stack.enter_context(mock.patch.object(build_update.subprocess, 'check_output', return_value='test-identity'))
            stack.enter_context(mock.patch.object(build_update, 'project_versions', return_value=('1.0', '1')))
            stack.enter_context(mock.patch.object(build_update, 'release_details', return_value=('1.0.2', '3', '说明')))
            def built(*unused):
                events.append('build')
                return self.package
            build = stack.enter_context(mock.patch.object(build_update, 'build_release', side_effect=built))
            def uploaded(value, client):
                self.assertEqual(value, self.package)
                events.append('upload')
                if fail_upload:
                    raise RuntimeError('测试上传失败')
            upload = stack.enter_context(mock.patch.object(build_update, 'upload_package', side_effect=uploaded))
            stack.enter_context(mock.patch('builtins.print'))
            if fail_upload:
                with self.assertRaisesRegex(RuntimeError, '测试上传失败'):
                    build_update.main()
            else:
                build_update.main()
            return events, signing.call_count, build.call_count, upload.call_count

    def test_successful_build_immediately_uploads_the_generated_package(self):
        self.assertEqual(self.run_main(['--notes', '说明']), (['build', 'upload'], 1, 1, 1))

    def test_upload_failure_propagates_after_build(self):
        self.assertEqual(self.run_main(['--notes', '说明'], fail_upload=True), (['build', 'upload'], 1, 1, 1))

    def test_upload_only_does_not_read_signing_credentials_or_build(self):
        self.assertEqual(self.run_main(['--upload-only', str(self.package)]), (['upload'], 0, 0, 1))

    def test_reopening_entry_retries_pending_upload_first(self):
        self.assertEqual(self.run_main([], pending=self.package), (['upload'], 0, 0, 1))

    def test_explicit_new_notes_are_not_silently_discarded_by_retry(self):
        with self.assertRaisesRegex(ValueError, '未完成上传'):
            self.run_main(['--notes', '新的说明'], pending=self.package)

    def test_retry_entry_without_pending_package_is_explicit_error(self):
        with self.assertRaisesRegex(ValueError, '没有待重试'):
            self.run_main(['--retry-upload'])


if __name__ == '__main__':
    unittest.main()

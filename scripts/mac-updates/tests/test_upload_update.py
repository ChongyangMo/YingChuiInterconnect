import copy
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from test_release_history import package
from release_history import ReleaseHistory, digest_file
from upload_update import pending_package, upload_package


class MemoryClient:
    def __init__(self, metadata):
        self.release = {'release_id': metadata['sha256'], 'metadata': metadata, 'state': 'draft'}
        self.stored = None
        self.uploads = 0
        self.lose_response = False

    def find_release(self, release_id):
        return copy.deepcopy(self.stored)

    def upload(self, path):
        self.uploads += 1
        exists = self.stored is not None
        if not exists:
            self.stored = copy.deepcopy(self.release)
        if self.lose_response:
            raise TimeoutError('测试响应超时')
        with zipfile.ZipFile(path) as archive:
            metadata_hash = hashlib.sha256(archive.read('metadata.json')).hexdigest()
        return {'release_id': self.stored['release_id'], 'app_version': self.stored['metadata']['app_version'],
                'app_build': self.stored['metadata']['app_build'], 'state': self.stored['state'],
                'already_exists': exists, 'package_sha256': digest_file(path), 'metadata_sha256': metadata_hash}


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.package = package(self.root, '1.0.1', '2')
        with zipfile.ZipFile(self.package) as archive:
            self.metadata = json.loads(archive.read('metadata.json'))
        self.client = MemoryClient(self.metadata)

    def upload(self):
        return upload_package(self.package, self.client, lambda _: None)

    def receipt(self):
        return json.loads(self.package.with_suffix('.upload.json').read_text())

    def test_success_requires_independent_remote_confirmation(self):
        result = self.upload()
        self.assertEqual(result['status'], 'uploaded')
        self.assertEqual(result['release_state'], 'draft')
        self.assertEqual(self.client.uploads, 1)
        self.assertEqual(self.receipt()['release_id'], self.metadata['sha256'])

    def test_lost_response_retry_reuses_same_artifact_without_new_version(self):
        history = ReleaseHistory(self.root, '1.0', '1')
        before = history.propose()
        self.client.lose_response = True
        with self.assertRaises(TimeoutError):
            self.upload()
        self.assertEqual(self.receipt()['status'], 'failed')
        self.assertEqual(pending_package(self.root), self.package)
        self.client.lose_response = False
        self.assertEqual(self.upload()['status'], 'uploaded')
        self.assertEqual(self.client.uploads, 2)
        self.assertIsNone(pending_package(self.root))
        self.assertEqual(ReleaseHistory(self.root, '1.0', '1').propose(), before)

    def test_successful_local_receipt_does_not_hide_remote_withdrawal(self):
        self.upload()
        self.client.stored['state'] = 'withdrawn'
        with self.assertRaisesRegex(ValueError, '撤回'):
            self.upload()
        self.assertEqual(self.receipt()['status'], 'failed')

    def test_remote_metadata_mismatch_is_not_success(self):
        self.client.stored = copy.deepcopy(self.client.release)
        self.client.stored['metadata']['app_version'] = '9.0'
        with self.assertRaisesRegex(ValueError, '不一致'):
            self.upload()
        self.assertEqual(self.receipt()['status'], 'failed')

    def test_acknowledgement_without_stored_release_is_failure(self):
        with mock.patch.object(self.client, 'find_release', return_value=None):
            with self.assertRaisesRegex(ValueError, '不一致'):
                self.upload()
        self.assertEqual(self.receipt()['status'], 'failed')

    def test_changed_package_rejects_stale_receipt(self):
        self.upload()
        self.package.unlink()
        self.package = package(self.root, '1.0.2', '2')
        with self.assertRaisesRegex(ValueError, '本地上传记录'):
            self.upload()

    def test_network_failure_preserves_package_and_reports_failure(self):
        before = self.package.read_bytes()
        with mock.patch.object(self.client, 'upload', side_effect=ConnectionError('测试断网')):
            with self.assertRaises(ConnectionError):
                self.upload()
        self.assertEqual(self.package.read_bytes(), before)
        self.assertEqual(self.receipt()['status'], 'failed')

    def test_atomic_receipt_error_does_not_upload_anything(self):
        with mock.patch('upload_update.os.replace', side_effect=OSError('测试写盘失败')):
            with self.assertRaises(OSError):
                self.upload()
        self.assertEqual(self.client.uploads, 0)

    def test_checksum_mismatch_acknowledgement_is_rejected(self):
        response = self.client.upload(self.package)
        for key in ('package_sha256', 'metadata_sha256'):
            changed = dict(response, **{key: '0' * 64})
            with mock.patch.object(self.client, 'upload', return_value=changed):
                with self.assertRaisesRegex(ValueError, '摘要不一致'):
                    self.upload()

    def test_missing_pending_package_is_explicit_error(self):
        self.client.lose_response = True
        with self.assertRaises(TimeoutError):
            self.upload()
        self.package.unlink()
        with self.assertRaisesRegex(ValueError, '已丢失'):
            pending_package(self.root)

    def test_new_upload_must_not_publish(self):
        response = self.client.upload(self.package)
        response.update(already_exists=False, state='published')
        with mock.patch.object(self.client, 'upload', return_value=response):
            with self.assertRaisesRegex(ValueError, '待发布'):
                self.upload()


if __name__ == '__main__':
    unittest.main()

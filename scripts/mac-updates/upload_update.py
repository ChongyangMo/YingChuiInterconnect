"""上传已生成制品并核对服务端记录；上传失败不会修改构建历史。"""
import datetime
import hashlib
import json
import os
import pathlib
import tempfile
import zipfile

from release_history import digest_file, inspect_package, load_json


def pending_package(root):
    pending = []
    for receipt in root.glob('build-*/package/*.upload.json'):
        data = load_json(receipt.read_bytes())
        if not isinstance(data, dict) or data.get('schema') != 1 or data.get('status') not in ('uploading', 'failed', 'uploaded'):
            raise ValueError('上传记录损坏，请核对：' + str(receipt))
        if data['status'] != 'uploaded':
            package = receipt.with_name(receipt.name.removesuffix('.upload.json') + '.ycu')
            if not package.is_file():
                raise ValueError('待上传的更新包已丢失：' + str(package))
            pending.append(package)
    if len(pending) > 1:
        raise ValueError('存在多个未完成上传，请用“仅上传”参数指定更新包逐一重试')
    return pending[0] if pending else None


def save_receipt(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.upload-', delete=False) as temporary:
        name = pathlib.Path(temporary.name)
        temporary.write((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
        temporary.flush()
        os.fsync(temporary.fileno())
    try:
        os.replace(name, path)
    finally:
        if name.exists():
            name.unlink()


def checked_release(release, metadata):
    if (not isinstance(release, dict) or release.get('release_id') != metadata['sha256']
            or release.get('metadata') != metadata):
        raise ValueError('服务器上的版本信息与本地签名更新包不一致，已停止上传')
    if release.get('state') not in ('draft', 'published'):
        raise ValueError('服务器上的更新包已撤回或状态无效，不能重复上传')
    return release


def upload_package(package, client, show=print):
    package = pathlib.Path(package).resolve(strict=True)
    if not package.is_file() or package.suffix != '.ycu':
        raise ValueError('请选择有效的鹰锤更新包')
    record = inspect_package(package)
    with zipfile.ZipFile(package) as archive:
        metadata_bytes = archive.read('metadata.json')
        metadata = load_json(metadata_bytes)
    receipt_path = package.with_suffix('.upload.json')
    attempt = {'schema': 1, 'package_sha256': record['package_sha256'],
               'version': record['version'], 'build': record['build'], 'channel': record['channel'],
               'release_id': metadata['sha256'], 'metadata_sha256': hashlib.sha256(metadata_bytes).hexdigest(), 'status': 'uploading',
               'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    if receipt_path.exists():
        previous = load_json(receipt_path.read_bytes())
        if (not isinstance(previous, dict) or previous.get('schema') != 1
                or any(previous.get(key) != attempt[key] for key in
                       ('package_sha256', 'version', 'build', 'channel', 'release_id', 'metadata_sha256'))):
            raise ValueError('本地上传记录与更新包不一致，请先核对文件')
    save_receipt(receipt_path, attempt)
    try:
        # 专用入库接口按签名制品幂等重传，逐次核对两层原始字节摘要。
        show('正在上传到鹰锤电脑端，请稍候。')
        response = client.upload(package)
        expected = {'release_id': metadata['sha256'], 'app_version': record['version'],
                    'app_build': record['build'], 'package_sha256': record['package_sha256'],
                    'metadata_sha256': attempt['metadata_sha256']}
        if (not isinstance(response, dict) or any(response.get(key) != value for key, value in expected.items())
                or type(response.get('already_exists')) is not bool):
            raise ValueError('上传回执的版本或文件摘要不一致，请核对服务器记录')
        if response.get('state') not in ('draft', 'published'):
            raise ValueError('服务器上的更新包已撤回或状态无效，不能重复上传')
        if not response['already_exists'] and response['state'] != 'draft':
            raise ValueError('新上传版本未进入待发布状态，请检查服务器接口')
        confirmed = checked_release(client.find_release(metadata['sha256']), metadata)
        if digest_file(package) != record['package_sha256']:
            raise ValueError('上传期间本地更新包发生变化，请核对服务器版本')
        attempt.update(status='uploaded', release_state=confirmed['state'], already_exists=response['already_exists'])
        save_receipt(receipt_path, attempt)
    except BaseException:
        attempt['status'] = 'failed'
        save_receipt(receipt_path, attempt)
        show('上传未完成，更新包已保留，可重试上传这个文件。')
        raise
    show('上传完成：版本 ' + record['version'] + '，构建号 ' + record['build'])
    show('可在部署工具的鹰锤电脑端查看' + ('并选择发布。' if confirmed['state'] == 'draft' else '，该版本已发布。'))
    return attempt

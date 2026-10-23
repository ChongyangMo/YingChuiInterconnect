"""从真实项目与已成功制品计算版本，持久记录只在完整打包成功后提交。"""
import base64
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import re
import tempfile
import zipfile


NUMBER = re.compile(r'(0|[1-9][0-9]{0,17})(\.(0|[1-9][0-9]{0,17})){0,2}')


def parts(value):
    if not isinstance(value, str) or not NUMBER.fullmatch(value):
        raise ValueError('版本或构建号无效：' + str(value))
    result = tuple(int(part) for part in value.split('.'))
    return result + (0,) * (3 - len(result))


def version(value):
    return '.'.join(str(part) for part in parts(value))


def digest_file(path):
    with path.open('rb') as source:
        return digest_stream(source)[0]


def digest_stream(source):
    digest, size = hashlib.sha256(), 0
    for chunk in iter(lambda: source.read(1024 * 1024), b''):
        size += len(chunk)
        digest.update(chunk)
    return digest.hexdigest(), size


def load_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('历史记录包含重复字段：' + key)
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs)


def validate_record(record):
    if not isinstance(record, dict) or set(record) != {'version', 'build', 'channel', 'package_sha256'}:
        raise ValueError('成功版本记录字段无效')
    parts(record['version'])
    parts(record['build'])
    if record['channel'] not in ('unified', 'beta', 'stable') or not re.fullmatch(r'[a-f0-9]{64}', record['package_sha256']):
        raise ValueError('成功版本记录渠道或摘要无效')


def inspect_package(path):
    if path.stat().st_size > 257 * 1024 * 1024:
        raise ValueError('历史更新包超过大小上限：' + str(path))
    with zipfile.ZipFile(path) as package:
        entries = package.infolist()
        if len(entries) != 3 or len(set(package.namelist())) != 3:
            raise ValueError('历史更新包必须恰好包含三个文件：' + str(path))
        metadata_info = package.getinfo('metadata.json')
        signature_info = package.getinfo('metadata.sig')
        if metadata_info.file_size > 16 * 1024 or signature_info.file_size > 256:
            raise ValueError('历史更新包元数据或签名过大')
        metadata = load_json(package.read(metadata_info))
        parts(metadata['app_version'])
        parts(metadata['app_build'])
        filename = metadata['filename']
        if (not isinstance(filename, str) or pathlib.PurePosixPath(filename).name != filename
                or '\\' in filename or set(package.namelist()) != {'metadata.json', 'metadata.sig', filename}
                or metadata['bundle_id'] != 'com.yingchui.interconnect.mac'):
            raise ValueError('历史更新包名称或应用标识无效')
        if len(base64.b64decode(package.read(signature_info).strip(), validate=True)) != 64:
            raise ValueError('历史元数据签名无效')
        if len(base64.b64decode(metadata['ed_signature'], validate=True)) != 64:
            raise ValueError('历史归档签名无效')
        if package.getinfo(filename).file_size > 256 * 1024 * 1024:
            raise ValueError('历史应用归档超过大小上限')
        with package.open(filename) as source:
            digest, size = digest_stream(source)
        if digest != metadata['sha256'] or size != metadata['size_bytes'] or size == 0:
            raise ValueError('历史应用归档摘要或长度不符：' + str(path))
    result = {'version': metadata['app_version'], 'build': metadata['app_build'],
              'channel': metadata['channel'], 'package_sha256': digest_file(path)}
    validate_record(result)
    return result


@contextlib.contextmanager
def build_lock(output_root):
    output_root.mkdir(parents=True, exist_ok=True)
    with (output_root / '.build.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('另一个打包任务正在运行，请等它结束后再打开。') from error
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


class ReleaseHistory:
    def __init__(self, output_root, project_version, project_build):
        self.root = output_root
        self.state_path = output_root / 'release-history.json'
        self.records = {}
        self.maximum_version = parts(project_version)
        self.maximum_build = parts(project_build)
        if self.state_path.exists():
            saved = load_json(self.state_path.read_bytes())
            if not isinstance(saved, dict) or set(saved) != {'schema', 'releases'} or type(saved['schema']) is not int or saved['schema'] != 1 or not isinstance(saved['releases'], list):
                raise ValueError('成功版本历史格式无效')
            for record in saved['releases']:
                validate_record(record)
                if parts(record['build']) in self.records:
                    raise ValueError('成功版本历史含有重复构建：' + record['build'])
                self._add(record)
        if output_root.exists():
            for directory in sorted(output_root.iterdir()):
                if directory.name.startswith('failed-build-'):
                    found = re.fullmatch(r'failed-build-([0-9.]+)-.+', directory.name)
                    if found is None:
                        raise ValueError('失败构建目录名称无效：' + directory.name)
                    self.maximum_build = max(self.maximum_build, parts(found.group(1)))
                elif directory.name.startswith('build-'):
                    build = directory.name[len('build-'):]
                    self.maximum_build = max(self.maximum_build, parts(build))
                    if not directory.is_dir():
                        raise ValueError('构建路径不是目录：' + str(directory))
                    attempt = None
                    if (directory / 'attempt.json').exists():
                        attempt = load_json((directory / 'attempt.json').read_bytes())
                        if (set(attempt) != {'build', 'version', 'status'} or attempt['build'] != build
                                or attempt['status'] not in ('running', 'failed')):
                            raise ValueError('构建尝试记录无效：' + str(directory))
                        parts(attempt['version'])
                    package = directory / 'package' / ('Yingchui-Mac-' + build + '.ycu')
                    found = list((directory / 'package').glob('*.ycu'))
                    if found and found != [package]:
                        raise ValueError('构建目录中的更新包名称不匹配：' + str(directory))
                    if package.exists():
                        record = inspect_package(package)
                        if record['build'] != build:
                            raise ValueError('历史构建目录与更新包构建号不一致')
                        if attempt is None or parts(build) in self.records:
                            self._add(record)
                        elif attempt['status'] == 'running':
                            raise ValueError('上次制品尚未提交成功记录，请先核对该构建：' + build)
                    elif (directory / 'package/metadata.json').exists():
                        # 不完整制品不能推进显示版本，但损坏的已有元数据仍必须报错。
                        metadata = load_json((directory / 'package/metadata.json').read_bytes())
                        parts(metadata['app_version'])
                        if metadata['app_build'] != build:
                            raise ValueError('未完成制品的构建号不匹配')

    def _add(self, record):
        validate_record(record)
        key = parts(record['build'])
        if key in self.records and self.records[key] != record:
            raise ValueError('同一构建的成功历史发生冲突：' + record['build'])
        self.records[key] = record
        self.maximum_version = max(self.maximum_version, parts(record['version']))
        self.maximum_build = max(self.maximum_build, key)

    def propose(self, requested_version=None, requested_build=None):
        next_parts = self.maximum_version[:2] + (self.maximum_version[2] + 1,)
        next_version = '.'.join(str(part) for part in next_parts)
        chosen_version = version(requested_version) if requested_version is not None else version(next_version)
        chosen_build = requested_build if requested_build is not None else str(self.maximum_build[0] + 1)
        if parts(chosen_version) <= self.maximum_version:
            raise ValueError('发布版本必须高于真实项目和成功历史中的最高版本')
        if parts(chosen_build) <= self.maximum_build:
            raise ValueError('构建号必须高于成功历史和已占用目录中的最高构建')
        return chosen_version, chosen_build

    def record_success(self, package, expected_version, expected_build, channel):
        record = inspect_package(package)
        if (record['version'], record['build'], record['channel']) != (expected_version, expected_build, channel):
            raise ValueError('生成的更新包与本次发布版本、构建号或渠道不一致')
        if parts(record['build']) <= self.maximum_build or parts(record['version']) <= self.maximum_version:
            raise ValueError('成功制品没有推进本次发布版本')
        records = list(self.records.values()) + [record]
        data = (json.dumps({'schema': 1, 'releases': records}, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        self.root.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=self.root, prefix='.release-history-', delete=False) as temporary:
            path = pathlib.Path(temporary.name)
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        try:
            os.replace(path, self.state_path)
        finally:
            if path.exists():
                path.unlink()
        self._add(record)

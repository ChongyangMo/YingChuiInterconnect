"""在 Mac 发布机校验应用并生成单个 .ycu 更新包。私钥只由 Sparkle 钥匙串读取。"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import zipfile


def run(args):
    result = subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True, timeout=180)
    return result.stdout + result.stderr


def sign(tool, path):
    output = run([tool, "--account", "com.yingchui.interconnect.mac.updates", path])
    match = re.search(r'sparkle:edSignature="([A-Za-z0-9+/]+={0,2})"', output)
    if not match:
        raise RuntimeError('Sparkle 未返回 Ed25519 签名')
    return match.group(1)


def main():
    parser = argparse.ArgumentParser(description='生成鹰锤 Mac 签名更新制品')
    parser.add_argument('--app', required=True)
    parser.add_argument('--sign-update', required=True)
    parser.add_argument('--channel', choices=['unified', 'stable', 'beta'], default='unified', help=argparse.SUPPRESS)
    parser.add_argument('--notes', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        raise RuntimeError('发布制品必须在 Mac 发布机生成')
    app = pathlib.Path(args.app).resolve(strict=True)
    tool = pathlib.Path(args.sign_update).resolve(strict=True)
    if app.suffix != '.app' or not app.is_dir() or not tool.is_file():
        raise RuntimeError('应用或 Sparkle 签名工具无效')
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    if info.get('SUPublicEDKey') != 'Sr9FgKNcKqu40hbLXF2Rje/uCDjVn5ks81hsRX13PKY=':
        raise RuntimeError('应用 Sparkle 公钥与已确认发布公钥不一致')
    if info.get('CFBundleIdentifier') != 'com.yingchui.interconnect.mac':
        raise RuntimeError('应用标识不是鹰锤 Mac')
    with (app / 'Contents/Resources/MacManagementConfiguration.json').open(encoding='utf-8') as source:
        client_configuration = json.load(source)
    if client_configuration.get('automatic_updates') is not True:
        raise RuntimeError('请先接入 Mac 自动更新功能并开启 automatic_updates，再生成更新包')
    if client_configuration.get('channel') != 'unified':
        raise RuntimeError('实际应用未接入统一更新源')
    build = str(info['CFBundleVersion'])
    display_version = str(info['CFBundleShortVersionString'])
    if not display_version.strip() or len(display_version.encode('utf-8')) > 64:
        raise RuntimeError('应用显示版本无效或超过 64 字节')
    if not re.fullmatch(r'(0|[1-9][0-9]{0,17})(\.(0|[1-9][0-9]{0,17})){0,2}', build):
        raise RuntimeError('应用构建号必须是数字或数字点分版本')
    minimum = str(info['LSMinimumSystemVersion'])
    minimum_parts = minimum.split('.')
    if len(minimum_parts) not in (1, 2, 3) or not all(part.isdigit() for part in minimum_parts):
        raise RuntimeError('最低系统版本无效')
    minimum = '.'.join(minimum_parts + ['0'] * (3 - len(minimum_parts)))
    executable_name = info['CFBundleExecutable']
    if not isinstance(executable_name, str) or '/' in executable_name or '\\' in executable_name:
        raise RuntimeError('应用可执行文件名称无效')
    executable = app / 'Contents/MacOS' / executable_name
    architectures = run(['/usr/bin/lipo', '-archs', executable]).strip().split()
    if not architectures or not set(architectures).issubset({'arm64', 'x86_64'}):
        raise RuntimeError('应用架构无效')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', app])
    signature_details = run(['/usr/bin/codesign', '-dv', '--verbose=4', app])
    developer_id = 'Authority=Developer ID Application:' in signature_details
    notarized = False
    if developer_id:
        run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=4', app])
        run(['/usr/bin/xcrun', 'stapler', 'validate', app])
        notarized = True
    notes = pathlib.Path(args.notes).read_text(encoding='utf-8')
    if len(notes.encode('utf-8')) > 8192 or '\x00' in notes:
        raise RuntimeError('版本说明无效或超过 8192 字节')
    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    archive = output / ('Yingchui-Mac-' + build + '.zip')
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive])
    size = archive.stat().st_size
    if size <= 0 or size > 256 * 1024 * 1024:
        raise RuntimeError('应用制品必须介于 1 字节与 256 MiB')
    with archive.open('rb') as source:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            hasher.update(chunk)
        digest = hasher.hexdigest()
    metadata = {
        'bundle_id': info['CFBundleIdentifier'],
        'app_version': display_version,
        'app_build': build,
        'minimum_system_version': minimum,
        'architectures': architectures,
        'channel': 'unified',
        'release_notes': notes,
        'sha256': digest,
        'size_bytes': size,
        'filename': archive.name,
        'ed_signature': sign(tool, archive),
        'developer_id_verified': developer_id,
        'notarization_verified': notarized,
    }
    metadata_file = output / 'metadata.json'
    metadata_bytes = (json.dumps(metadata, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    if len(metadata_bytes) > 16 * 1024:
        raise RuntimeError('发布元数据超过 16 KiB')
    metadata_file.write_bytes(metadata_bytes)
    (output / 'metadata.sig').write_text(sign(tool, metadata_file) + '\n', encoding='ascii')
    bundle = output / ('Yingchui-Mac-' + build + '.ycu')
    with zipfile.ZipFile(bundle, 'x', compression=zipfile.ZIP_STORED) as package:
        for file in [archive, metadata_file, output / 'metadata.sig']:
            package.write(file, file.name)
    if bundle.stat().st_size > 257 * 1024 * 1024:
        raise RuntimeError('更新包超过 257 MiB')
    print('更新包已生成：' + str(bundle))
    print('更新包上传后需在管理页面发布；Developer ID：' + str(developer_id) + '；公证：' + str(notarized))


if __name__ == '__main__':
    main()

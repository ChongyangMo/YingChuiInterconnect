"""本机自动更新打包入口；版本自动计算，私钥只由钥匙串读取。"""
import argparse
import json
import pathlib
import plistlib
import subprocess
import sys

from release_history import ReleaseHistory, build_lock, parts
from upload_client import UploadClient
from upload_update import pending_package, upload_package


def run(arguments, log):
    with log.open('ab') as target:
        subprocess.run([str(value) for value in arguments], stdout=target, stderr=subprocess.STDOUT, check=True)


def project_versions(root):
    data = subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-',
                                    root / 'Mac/YingchuiMac.xcodeproj/project.pbxproj'])
    objects = json.loads(data)['objects']
    targets = [value for value in objects.values() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'YingchuiMac']
    if len(targets) != 1:
        raise ValueError('没有找到唯一的 Mac 应用构建目标')
    configurations = objects[targets[0]['buildConfigurationList']]['buildConfigurations']
    releases = [objects[key]['buildSettings'] for key in configurations if objects[key]['name'] == 'Release']
    if len(releases) != 1:
        raise ValueError('Mac 发布配置缺失或不唯一')
    display, build = releases[0]['MARKETING_VERSION'], releases[0]['CURRENT_PROJECT_VERSION']
    parts(display)
    parts(build)
    return display, build


def release_details(history, args, ask=input, show=print):
    suggested, build = history.propose(args.version, args.build)
    if args.version is None and args.notes is None:
        entered = ask('发布版本号 [' + suggested + ']：').strip()
        display, build = history.propose(entered or suggested, args.build)
    else:
        display = suggested
        show('发布版本号：' + display)
    show('构建号：' + build + ('（自动）' if args.build is None else ''))
    notes = args.notes if args.notes is not None else ask('更新说明：').strip()
    if not notes.strip() or '\x00' in notes or len(notes.encode('utf-8')) > 8192:
        raise ValueError('更新说明不能为空或超过 8192 字节')
    return display, build, notes


def compile_package(root, script, config, display, build, notes, output):
    log = output / 'build.log'
    notes_file = output / 'notes.txt'
    notes_file.write_text(notes, encoding='utf-8')
    derived = root / 'work/repair/mac-update-package-build'
    print('正在编译更新包，请稍候。', flush=True)
    print('构建日志：' + str(log), flush=True)
    run(['/usr/bin/xcodebuild', 'build', '-workspace', root / 'YingchuiInterconnect.xcworkspace',
         '-scheme', 'YingchuiMac', '-configuration', 'Release', '-destination', 'platform=macOS,arch=' + config['architecture'],
         '-derivedDataPath', derived, 'ONLY_ACTIVE_ARCH=YES',
         'CURRENT_PROJECT_VERSION=' + build, 'MARKETING_VERSION=' + display], log)
    app = output / 'staging/YingchuiMac.app'
    run(['/usr/bin/ditto', derived / 'Build/Products/Release/YingchuiMac.app', app], log)
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if (info['CFBundleShortVersionString'], info['CFBundleVersion']) != (display, build):
        raise ValueError('实际编译应用的版本或构建号与本次发布不一致')
    config_path = app / 'Contents/Resources/MacManagementConfiguration.json'
    client_config = json.loads(config_path.read_text(encoding='utf-8'))
    if client_config.get('automatic_updates') is not True or client_config.get('channel') != 'unified':
        raise ValueError('实际编译的应用尚未启用统一自动更新')
    entitlements = output / 'signing-entitlements.plist'
    with entitlements.open('wb') as destination, log.open('ab') as errors:
        subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)], stdout=destination, stderr=errors, check=True)
    plistlib.loads(entitlements.read_bytes())
    run(['/usr/bin/codesign', '--force', '--sign', config['signing_identity'], '--entitlements', entitlements, app], log)
    run(['/usr/bin/python3', script / 'yingchui_mac_release.py', '--app', app,
         '--sign-update', root / 'Mac/Vendor/SparkleTools/sign_update',
         '--notes', notes_file, '--output', output / 'package'], log)
    return output / 'package' / ('Yingchui-Mac-' + build + '.ycu')


def build_release(root, script, config, history, display, build, notes, compile_function=compile_package):
    output = history.root / ('build-' + build)
    output.mkdir(parents=True, exist_ok=False)
    attempt = {'version': display, 'build': build, 'status': 'running'}
    attempt_file = output / 'attempt.json'
    attempt_file.write_text(json.dumps(attempt), encoding='utf-8')
    try:
        package = compile_function(root, script, config, display, build, notes, output)
        history.record_success(package, display, build, 'unified')
    except BaseException:
        attempt['status'] = 'failed'
        attempt_file.write_text(json.dumps(attempt), encoding='utf-8')
        raise
    return package


def main():
    parser = argparse.ArgumentParser(description='生成鹰锤电脑端更新包并自动上传')
    parser.add_argument('--version', help='指定高于已有版本的发布版本号')
    parser.add_argument('--build', help='必要时指定高于历史的构建号')
    parser.add_argument('--notes', help='更新说明；填写此项后可全自动打包')
    uploads = parser.add_mutually_exclusive_group()
    uploads.add_argument('--upload-only', type=pathlib.Path, help='仅上传指定的已有更新包，不重新编译')
    uploads.add_argument('--retry-upload', action='store_true', help='重试上次未完成的上传')
    args = parser.parse_args()
    if (args.upload_only or args.retry_upload) and any(value is not None for value in (args.version, args.build, args.notes)):
        raise ValueError('重试上传时不能同时指定新版本或更新说明')
    if sys.platform != 'darwin':
        raise RuntimeError('更新包必须在 Mac 上生成')
    script = pathlib.Path(__file__).resolve().parent
    root = script.parent.parent
    config = json.loads((script / 'build-config.json').read_text(encoding='utf-8'))
    client = UploadClient(config.get('upload'))
    if config['architecture'] not in ('arm64', 'x86_64'):
        raise RuntimeError('打包架构配置无效')
    with build_lock(root / 'artifacts/mac-updates'):
        if args.upload_only or args.retry_upload:
            package = args.upload_only or pending_package(root / 'artifacts/mac-updates')
            if package is None:
                raise ValueError('没有待重试的上传，请使用生成更新包入口')
            upload_package(package, client)
            return
        pending = pending_package(root / 'artifacts/mac-updates')
        if pending is not None:
            if any(value is not None for value in (args.version, args.build, args.notes)):
                raise ValueError('存在未完成上传，请先使用重试入口完成上传，再创建新版本')
            print('上次更新包尚未上传完成，先重试上传原包。')
            upload_package(pending, client)
            return
        identities = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
        if config['signing_identity'] not in identities:
            raise RuntimeError('配置中的签名证书不可用，请检查本机钥匙串')
        project_version, project_build = project_versions(root)
        history = ReleaseHistory(root / 'artifacts/mac-updates', project_version, project_build)
        display, build, notes = release_details(history, args)
        package = build_release(root, script, config, history, display, build, notes)
        print('更新包已生成：' + str(package))
        print('发布版本：' + display + '；构建号：' + build)
        upload_package(package, client)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\n已取消操作。', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print('操作失败：' + str(error), file=sys.stderr)
        sys.exit(1)

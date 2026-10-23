import json
import pathlib
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import yingchui_mac_release


class AutomaticPackageTests(unittest.TestCase):
    def test_generator_rejects_disabled_or_old_client_before_signing(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            app = root / 'YingchuiMac.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'SUPublicEDKey': 'Sr9FgKNcKqu40hbLXF2Rje/uCDjVn5ks81hsRX13PKY=',
                'CFBundleIdentifier': 'com.yingchui.interconnect.mac'}))
            tool = root / 'sign_update'
            tool.write_text('fixture')
            args = ['packager', '--app', str(app), '--sign-update', str(tool),
                    '--notes', str(root / 'notes'), '--output', str(root / 'package')]
            for config in [{}, {'automatic_updates': False, 'channel': 'unified'},
                           {'automatic_updates': True, 'channel': 'beta'}]:
                (resources / 'MacManagementConfiguration.json').write_text(json.dumps(config))
                with mock.patch.object(sys, 'argv', args), mock.patch.object(yingchui_mac_release, 'run') as run:
                    with self.assertRaisesRegex(RuntimeError, '自动更新|统一更新源'):
                        yingchui_mac_release.main()
                    run.assert_not_called()
                self.assertFalse((root / 'package').exists())

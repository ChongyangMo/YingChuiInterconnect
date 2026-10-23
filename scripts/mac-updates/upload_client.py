"""固定上传目标，流式发送更新包；不接受重定向或未知的服务器回执。"""
import http.client
import pathlib
import socket
import ssl
import urllib.parse

from release_history import load_json


MAXIMUM_PACKAGE = 257 * 1024 * 1024
MAXIMUM_RESPONSE = 4 * 1024 * 1024
ORIGIN = 'https://deploy.chongyang.asia'
PREFIX = '/api/yingchui-mac/'


def response_json(raw):
    try:
        return load_json(raw)
    except (ValueError, UnicodeError) as error:
        raise RuntimeError('无法解析上传服务的响应，请检查服务是否正常') from error


class UploadClient:
    def __init__(self, config):
        if not isinstance(config, dict) or set(config) != {'base_url', 'timeout_seconds'}:
            raise ValueError('自动上传配置缺失或字段无效')
        if config['base_url'] != ORIGIN or type(config['timeout_seconds']) is not int or not 10 <= config['timeout_seconds'] <= 600:
            raise ValueError('自动上传地址或超时时间无效')
        self.timeout = config['timeout_seconds']
        self.host = urllib.parse.urlsplit(config['base_url']).hostname

    def _connection(self):
        # 直接访问已配置服务，不读取系统代理或环境变量。
        return http.client.HTTPSConnection(self.host, timeout=self.timeout, context=ssl.create_default_context())

    def request(self, action, package=None):
        if action not in ('ingest', 'releases') or (action == 'ingest') != (package is not None):
            raise ValueError('自动上传操作无效')
        connection = self._connection()
        try:
            if package is None:
                connection.request('GET', PREFIX + action, headers={'Accept': 'application/json'})
            else:
                size = package.stat().st_size
                if not 0 < size <= MAXIMUM_PACKAGE:
                    raise ValueError('更新包为空或超过上传大小上限')
                with package.open('rb') as body:
                    connection.request('POST', PREFIX + action, body=body, headers={
                        'Content-Type': 'application/octet-stream', 'Accept': 'application/json',
                        'Content-Length': str(size)
                    })
            response = connection.getresponse()
            raw = response.read(MAXIMUM_RESPONSE + 1)
            if len(raw) > MAXIMUM_RESPONSE:
                raise RuntimeError('上传服务的响应超过大小上限')
            if response.status != 200:
                code = ''
                if response.getheader('Content-Type', '').split(';')[0].strip() == 'application/json':
                    data = response_json(raw)
                    if isinstance(data, dict) and isinstance(data.get('error'), dict):
                        code = data['error'].get('code', '')
                if response.status == 404:
                    raise RuntimeError('自动上传接口尚未上线，请先更新部署工具和业务后端，再重试上传原包')
                if response.status in (401, 403):
                    raise RuntimeError('上传服务拒绝访问，请检查部署工具的服务器连接或访问权限')
                if response.status == 409:
                    raise RuntimeError('服务器已有冲突的版本或更新包，请核对后再上传')
                if response.status == 413:
                    raise RuntimeError('上传服务拒绝了文件大小，请检查服务器上传限制')
                if code == 'invalid_signature':
                    raise RuntimeError('服务器未通过更新包签名校验，请检查签名公钥和更新包')
                if 300 <= response.status < 400:
                    raise RuntimeError('上传服务发生地址跳转，已停止发送，请检查部署地址')
                raise RuntimeError('上传服务请求失败（状态码 ' + str(response.status) + '），更新包已保留')
            if response.getheader('Content-Type', '').split(';')[0].strip() != 'application/json':
                raise RuntimeError('上传服务返回的内容格式无效')
            return response_json(raw)
        except ssl.SSLError as error:
            raise RuntimeError('上传服务的安全连接验证失败，请检查系统时间和服务器证书') from error
        except (TimeoutError, socket.timeout) as error:
            raise RuntimeError('上传连接超时，可重试上传同一个更新包') from error
        except (OSError, http.client.HTTPException) as error:
            raise RuntimeError('上传连接中断，请检查网络后重试同一个更新包') from error
        finally:
            connection.close()

    def upload(self, package):
        return self.request('ingest', pathlib.Path(package))

    def find_release(self, release_id):
        data = self.request('releases')
        if not isinstance(data, dict) or not isinstance(data.get('releases'), list) or data.get('updates_available') is not True:
            raise ValueError('服务器版本列表无效或更新服务不可用')
        if any(not isinstance(value, dict) for value in data['releases']):
            raise ValueError('服务器版本记录格式无效')
        matches = [value for value in data['releases'] if value.get('release_id') == release_id]
        if len(matches) > 1:
            raise ValueError('服务器返回了重复的版本记录')
        return matches[0] if matches else None

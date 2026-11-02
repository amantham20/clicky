import http.client
import io
import json
import os
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch
from server import ClaudeRelay, approved_endpoint, validate_payload


class RelayTests(unittest.TestCase):
    def test_rejects_unsafe_endpoint_and_other_models(self):
        for endpoint in ('http://api.anthropic.com/v1/messages', 'https://key@host/messages', 'https://host/messages?key=secret'):
            with self.assertRaises(ValueError):
                approved_endpoint(endpoint)
        with self.assertRaises(ValueError):
            validate_payload({'model': 'gpt-4', 'messages': [{}]})

    def test_relay_streams_claude_and_keeps_credential_server_side(self):
        class Response:
            status = 200
            stream = io.BytesIO(b'data: {"type":"message_stop"}\n\n')
            def getheader(self, *_): return 'text/event-stream'
            def read1(self, size): return self.stream.read(size)
        requests = []
        class Upstream:
            def __init__(self, *args, **kwargs): pass
            def request(self, *args): requests.append(args)
            def getresponse(self): return Response()
            def close(self): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), ClaudeRelay)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.dict(os.environ, {'CLICKY_ANTHROPIC_API_KEY': 'test-only-key'}), patch('server.http.client.HTTPSConnection', Upstream):
                client = http.client.HTTPConnection('127.0.0.1', server.server_port)
                payload = json.dumps({'model': 'claude-sonnet-4-6', 'messages': [{'role': 'user', 'content': 'test'}], 'stream': True})
                client.request('POST', '/chat', payload, {'Host': '127.0.0.1:8787'})
                response = client.getresponse()
                self.assertEqual(response.status, 200)
                body = response.read()
                self.assertIn(b'message_stop', body)
                self.assertNotIn(b'test-only-key', body)
                self.assertEqual(requests[0][3]['x-api-key'], 'test-only-key')
                client.close()
                client = http.client.HTTPConnection('127.0.0.1', server.server_port)
                client.request('POST', '/chat', payload, {'Host': '127.0.0.1:8787', 'Origin': 'https://example.com'})
                self.assertEqual(client.getresponse().status, 403)
                client.close()
        finally:
            server.shutdown()
            server.server_close()

if __name__ == '__main__':
    unittest.main()

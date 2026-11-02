#!/usr/bin/env python3
"""Loopback-only Claude Messages relay. Credentials are supplied explicitly via environment."""
import http.client
import json
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY_BYTES = 24 * 1024 * 1024


def approved_endpoint(value):
    endpoint = urllib.parse.urlsplit(value)
    if (endpoint.scheme != 'https' or not endpoint.hostname or endpoint.username
            or endpoint.password or endpoint.query or endpoint.fragment):
        raise ValueError('CLICKY_ANTHROPIC_MESSAGES_URL must be an HTTPS Messages URL without credentials or query parameters')
    return endpoint


def validate_payload(payload):
    if not isinstance(payload, dict):
        raise ValueError('Expected a Messages object')
    if not str(payload.get('model', '')).startswith('claude-'):
        raise ValueError('Only Claude models are permitted')
    if not isinstance(payload.get('messages'), list) or not payload['messages']:
        raise ValueError('Messages are required')
    return payload


class ClaudeRelay(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass  # Never log conversation content, headers or upstream error bodies.

    def reply(self, status, message):
        body = json.dumps({'error': message}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_POST(self):
        # Reject web origins, cross-site fetches, DNS rebinding and unsupported routes.
        if (self.headers.get('Origin') or self.headers.get('Sec-Fetch-Site')
                or self.headers.get('Host') not in ('127.0.0.1:8787', 'localhost:8787')):
            self.reply(403, 'Only the local Clicky client is accepted')
            self.close_connection = True
            return
        if self.path != '/chat':
            self.reply(404, 'Only /chat is supported')
            self.close_connection = True
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= MAX_BODY_BYTES:
                raise ValueError('Invalid body length')
            payload = validate_payload(json.loads(self.rfile.read(length)))
        except (ValueError, UnicodeError):
            self.reply(400, 'Invalid Claude Messages request')
            self.close_connection = True
            return
        credential = os.environ.get('CLICKY_ANTHROPIC_API_KEY', '')
        if not credential:
            self.reply(503, 'Set CLICKY_ANTHROPIC_API_KEY to a company-approved API credential; workspace SSO and Claude Code subscriptions are not API keys')
            return
        endpoint = approved_endpoint(os.environ.get('CLICKY_ANTHROPIC_MESSAGES_URL', 'https://api.anthropic.com/v1/messages'))
        header = os.environ.get('CLICKY_AUTH_HEADER', 'x-api-key').lower()
        if header not in ('x-api-key', 'authorization'):
            self.reply(503, 'CLICKY_AUTH_HEADER must be x-api-key or authorization')
            return
        auth_value = ('Bearer ' if header == 'authorization' else '') + credential
        headers = {'Content-Type': 'application/json', 'anthropic-version': '2023-06-01', header: auth_value}
        connection = http.client.HTTPSConnection(endpoint.hostname, endpoint.port or 443, timeout=120)
        started_response = False
        try:
            # http.client never follows redirects, so API credentials stay on the configured host.
            connection.request('POST', endpoint.path or '/', json.dumps(payload).encode(), headers)
            response = connection.getresponse()
            if response.status != 200:
                self.reply(502, f'Claude endpoint returned HTTP {response.status}. Check endpoint, API credential and model access.')
                return
            self.send_response(200)
            self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            started_response = True
            while chunk := response.read1(8192):
                self.wfile.write(chunk)
                self.wfile.flush()
        except (OSError, http.client.HTTPException):
            if not started_response:
                self.reply(502, 'Unable to reach the configured Claude endpoint')
            self.close_connection = True
        finally:
            connection.close()


def main():
    approved_endpoint(os.environ.get('CLICKY_ANTHROPIC_MESSAGES_URL', 'https://api.anthropic.com/v1/messages'))
    server = ThreadingHTTPServer(('127.0.0.1', 8787), ClaudeRelay)
    print('Clicky Claude relay listening on http://127.0.0.1:8787 (Ctrl+C to stop)', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()

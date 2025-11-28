#!/usr/bin/env python3
"""
Health check script for PyPI server.
Verifies the PyPI server is responding with valid HTTP.
"""
import socket
import sys
import http.client

CONTAINER_PORT = 8080


def main():
    """Check if PyPI server is responding with valid HTTP."""
    try:
        # TCP connection check
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(('127.0.0.1', CONTAINER_PORT))
        sock.close()

        # HTTP health check
        conn = http.client.HTTPConnection('127.0.0.1', CONTAINER_PORT, timeout=5)
        conn.request('GET', '/')
        response = conn.getresponse()
        conn.close()

        if response.status in (200, 401):  # 401 is OK (auth required)
            print(f"Health check passed: PyPI server responding on port {CONTAINER_PORT}")
            sys.exit(0)
        else:
            print(f"Health check failed: HTTP {response.status}", file=sys.stderr)
            sys.exit(1)

    except Exception as e:
        print(f"Health check failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
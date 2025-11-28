#!/usr/bin/env python3
"""
Health check script for PyPI server.
Attempts to connect to the local PyPI server port to verify it's running.
"""
import socket
import sys

CONTAINER_PORT = 8080


def main():
    """Check if PyPI server is responding on the container port."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)  # 5 second timeout
        sock.connect(('127.0.0.1', CONTAINER_PORT))
        sock.close()
        print(f"Health check passed: PyPI server responding on port {CONTAINER_PORT}")
        sys.exit(0)
    except (socket.error, socket.timeout) as e:
        print(f"Health check failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
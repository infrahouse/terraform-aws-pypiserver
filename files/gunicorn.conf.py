"""Gunicorn configuration for PyPI server.

Worker count is configured via GUNICORN_WORKERS environment variable.
Defaults to 4 if not specified.

Configuration:
  - Workers: Read from GUNICORN_WORKERS env var
  - Worker class: gevent (async, handles multiple concurrent connections per worker)
  - Preload: enabled (load app before forking for memory efficiency)

To override, set extra_files in your terraform configuration to provide a custom
/data/gunicorn.conf.py file.
"""
import os

# pylint: disable=invalid-name

errorlog = "-"
preload_app = True
workers = int(os.getenv("GUNICORN_WORKERS", "4"))
worker_class = "gevent"
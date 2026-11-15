"""
platforms/truenas/tests/pylib/truenas_api_client - stand-in for TrueNAS's
Python API client (python3-truenas-api-client), for testing
platforms/truenas/truenas_app.py's `call` command.

Same surface as the parts the installer uses in TrueNAS 25.10:
Client(uri=None) as a context manager, and
Client.call(method, *params, job=False, callback=None, ...), which raises
truenas_api_client.exc.ClientException when the call or the job fails.
Calls are checked and answered by tests/lib/fake_middleware.py.

Written for these tests. License: MIT (see LICENSE in the repository root).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import fake_middleware  # noqa: E402

from .exc import ClientException  # noqa: E402,F401


class Client:
    def __init__(self, uri=None, reserved_ports=False, private_methods=False, py_exceptions=False,
                 log_py_exceptions=False, call_timeout=None, verify_ssl=True):
        self.uri = uri

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def call(self, method, *params, background=False, callback=None, job=False,
             register_call=None, timeout=None):
        try:
            return fake_middleware.call(method, list(params), job=bool(job), via="client",
                                        callback=callback)
        except fake_middleware.CallError as exc:
            raise ClientException(str(exc)) from None

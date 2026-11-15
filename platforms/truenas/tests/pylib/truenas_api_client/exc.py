"""
platforms/truenas/tests/pylib/truenas_api_client/exc.py - the exception
class of the stand-in API client (see __init__.py).

License: MIT (see LICENSE in the repository root).
"""


class ClientException(Exception):
    def __init__(self, error, errno=None, trace=None, extra=None):
        super().__init__(error)
        self.error = error
        self.errno = errno
        self.trace = trace
        self.extra = extra

    def __str__(self):
        return self.error

"""Puts the fake moonraker package on sys.path so
`fakemoonraker.components.orcaslicer` (a symlink to src/orcaslicer.py)
imports cleanly, and provides fixtures for building an OrcaSlicer instance
against test doubles instead of a real Moonraker."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from fakemoonraker.common import FakeWebRequest  # noqa: E402
from fakemoonraker.confighelper import FakeConfigHelper  # noqa: E402
from fakemoonraker.components.http_client import (  # noqa: E402
    FakeHttpClient,
    FakeHttpResponse,
)
from fakemoonraker.components import orcaslicer as orcaslicer_module  # noqa: E402


class ServerError(Exception):
    def __init__(self, message, status_code=400):
        super().__init__(message)
        self.status_code = status_code


class FakeServer:
    def __init__(self, http_client):
        self._http_client = http_client
        self.endpoints = []

    def lookup_component(self, name):
        assert name == "http_client"
        return self._http_client

    def register_endpoint(self, path, request_type, handler, **kwargs):
        self.endpoints.append(
            {"path": path, "request_type": request_type, "handler": handler}
        )

    def error(self, message, status_code=400):
        return ServerError(message, status_code)


@pytest.fixture
def http_client():
    return FakeHttpClient()


@pytest.fixture
def server(http_client):
    return FakeServer(http_client)


@pytest.fixture
def gcodes_path(tmp_path):
    return tmp_path / "gcodes"


@pytest.fixture
def slicer(server, gcodes_path):
    config = FakeConfigHelper(
        server,
        {
            "orcaslicer_url": "http://localhost:5000",
            "request_timeout": 300,
            "gcodes_path": str(gcodes_path),
        },
    )
    return orcaslicer_module.OrcaSlicer(config)


def make_request(args=None, action="GET"):
    return FakeWebRequest(args=args, action=action)


@pytest.fixture
def make_web_request():
    return make_request


class FakeRawResponse:
    def __init__(self, code=200, headers=None, body=b""):
        self.code = code
        self.headers = headers or {}
        self.body = body


class FakeRawClient:
    """Stand-in for the tornado AsyncHTTPClient used for constructed
    (multipart/raw-body) requests: slice, profile upload, profile rename."""

    def __init__(self):
        self.requests = []
        self._queue = []
        self.raises = None

    def queue_response(self, response):
        self._queue.append(response)

    async def fetch(self, request, raise_error=False):
        self.requests.append(request)
        if self.raises is not None:
            raise self.raises
        if not self._queue:
            raise AssertionError(
                f"FakeRawClient got unexpected fetch to {request.url} "
                "with no queued response"
            )
        return self._queue.pop(0)


@pytest.fixture
def raw_client(slicer):
    fake = FakeRawClient()
    slicer.raw_client = fake
    return fake

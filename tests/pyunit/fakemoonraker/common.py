"""Minimal stand-ins for moonraker.common, just enough for orcaslicer.py's
one runtime import (RequestType, TransportType) plus the WebRequest shape
its handlers expect."""

import enum


class RequestType(enum.Flag):
    GET = enum.auto()
    POST = enum.auto()
    DELETE = enum.auto()
    PATCH = enum.auto()


class TransportType(enum.Flag):
    HTTP = enum.auto()
    WEBSOCKET = enum.auto()


class FakeWebRequest:
    """Test double for moonraker.common.WebRequest.

    Backed by a plain dict of args, plus an explicit HTTP action string
    (Moonraker derives this from the request method).
    """

    def __init__(self, args=None, action="GET", request_handler=None):
        self._args = dict(args or {})
        self._action = action
        self.request_handler = request_handler

    def get_str(self, name, default=None):
        if name not in self._args:
            if default is None:
                raise KeyError(f"missing required arg: {name}")
            return default
        return self._args[name]

    def get_action(self):
        return self._action

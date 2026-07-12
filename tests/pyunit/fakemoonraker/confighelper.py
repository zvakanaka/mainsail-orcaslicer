"""Test double for moonraker.confighelper.ConfigHelper."""


class FakeConfigHelper:
    def __init__(self, server, values=None):
        self._server = server
        self._values = dict(values or {})

    def get(self, key, default=None):
        return self._values.get(key, default)

    def getint(self, key, default=None):
        return int(self._values.get(key, default))

    def get_server(self):
        return self._server

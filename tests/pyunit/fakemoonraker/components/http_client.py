"""Test double for moonraker.components.http_client.HttpClient — the
client orcaslicer.py uses for simple (no-body) GET/DELETE proxying."""


class FakeHttpResponse:
    def __init__(self, status_code=200, json_body=None, text=""):
        self.status_code = status_code
        self._json_body = json_body if json_body is not None else {}
        self.text = text or (str(self._json_body) if status_code >= 400 else "")

    def has_error(self):
        return self.status_code >= 400

    def json(self):
        return self._json_body


class FakeHttpClient:
    """Responses are queued in call order; tests push what they expect
    each call to return, or set `raises` to simulate a connection error."""

    def __init__(self):
        self.calls = []
        self._queue = []
        self.raises = None

    def queue_response(self, response):
        self._queue.append(response)

    async def _record_and_respond(self, method, url, timeout):
        self.calls.append({"method": method, "url": url, "timeout": timeout})
        if self.raises is not None:
            raise self.raises
        if not self._queue:
            raise AssertionError(
                f"FakeHttpClient got unexpected {method} {url} with no queued response"
            )
        return self._queue.pop(0)

    async def get(self, url, request_timeout=None):
        return await self._record_and_respond("GET", url, request_timeout)

    async def delete(self, url, request_timeout=None):
        return await self._record_and_respond("DELETE", url, request_timeout)

    async def request(self, method, url, request_timeout=None):
        return await self._record_and_respond(method, url, request_timeout)

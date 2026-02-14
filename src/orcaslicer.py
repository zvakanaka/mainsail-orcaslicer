# OrcaSlicer Moonraker Component
#
# Proxies orcaslicer-web API endpoints through Moonraker and serves
# a custom slicer UI page for Mainsail integration.
#
# Copyright (C) 2024
# This file may be distributed under the terms of the GNU GPLv3 license.

from __future__ import annotations
import base64
import json
import logging
import os
import pathlib
import re
import uuid
from tornado.httpclient import AsyncHTTPClient, HTTPRequest
from tornado.httputil import HTTPHeaders

from typing import (
    TYPE_CHECKING,
    Any,
    Dict,
    Optional,
)
if TYPE_CHECKING:
    from ..confighelper import ConfigHelper
    from ..common import WebRequest
    from .http_client import HttpClient

from ..common import RequestType, TransportType

VALID_PROFILE_TYPES = {"printer", "process", "filament"}

LOG = logging.getLogger(__name__)


class OrcaSlicer:
    def __init__(self, config: ConfigHelper) -> None:
        self.server = config.get_server()
        self.orcaslicer_url: str = config.get(
            'orcaslicer_url', 'http://localhost:5000'
        ).rstrip('/')
        self.request_timeout: int = config.getint('request_timeout', 300)
        self.gcodes_path: pathlib.Path = pathlib.Path(
            config.get('gcodes_path', '~/printer_data/gcodes')
        ).expanduser()

        # Moonraker's built-in HTTP client for simple proxying
        self.http_client: HttpClient = self.server.lookup_component(
            'http_client')

        # Tornado client for forwarding constructed requests
        self.raw_client = AsyncHTTPClient()

        # Resolve the slicer UI HTML path (follows the symlink back to the
        # repo checkout).  We serve it via a regular endpoint so we can set
        # Content-Type: text/html — register_static_file_handler triggers a
        # file download in some Moonraker versions.
        self._ui_path = pathlib.Path(__file__).resolve().parent / 'slicer_ui.html'
        if self._ui_path.is_file():
            self.server.register_endpoint(
                '/server/orcaslicer/ui',
                RequestType.GET,
                self._handle_ui,
                transports=TransportType.HTTP,
                wrap_result=False,
            )
        else:
            LOG.warning(
                f"slicer_ui.html not found at {self._ui_path}; "
                "UI endpoint will not be available"
            )

        # -- Health & status --------------------------------------------------
        self.server.register_endpoint(
            '/server/orcaslicer/health',
            RequestType.GET,
            self._handle_health,
            transports=TransportType.HTTP,
            wrap_result=False,
        )
        self.server.register_endpoint(
            '/server/orcaslicer/status',
            RequestType.GET,
            self._handle_status,
            transports=TransportType.HTTP,
            wrap_result=False,
        )

        # -- Profile list & upload --------------------------------------------
        self.server.register_endpoint(
            '/server/orcaslicer/profiles/(?P<profile_type>[a-z]+)',
            RequestType.GET | RequestType.POST,
            self._handle_profiles_collection,
            transports=TransportType.HTTP,
            wrap_result=False,
        )

        # -- Single profile operations ----------------------------------------
        self.server.register_endpoint(
            '/server/orcaslicer/profiles/(?P<profile_type>[a-z]+)'
            '/(?P<profile_name>.+)',
            RequestType.GET | RequestType.POST | RequestType.DELETE,
            self._handle_profile_item,
            transports=TransportType.HTTP,
            wrap_result=False,
        )

        # -- Slice ------------------------------------------------------------
        self.server.register_endpoint(
            '/server/orcaslicer/slice',
            RequestType.POST,
            self._handle_slice,
            transports=TransportType.HTTP,
            wrap_result=False,
        )

    # --------------------------------------------------------------------- #
    #  Multipart builder                                                      #
    # --------------------------------------------------------------------- #

    @staticmethod
    def _build_multipart(
        fields: Dict[str, str],
        file_field: Optional[str] = None,
        file_name: Optional[str] = None,
        file_bytes: Optional[bytes] = None,
    ) -> tuple:
        """Build a multipart/form-data body.  Returns (body, content_type)."""
        boundary = uuid.uuid4().hex
        parts = []
        for name, value in fields.items():
            parts.append(
                f'--{boundary}\r\n'
                f'Content-Disposition: form-data; name="{name}"\r\n'
                f'\r\n'
                f'{value}\r\n'
            )
        if file_field and file_name and file_bytes is not None:
            parts.append(
                f'--{boundary}\r\n'
                f'Content-Disposition: form-data; name="{file_field}"; '
                f'filename="{file_name}"\r\n'
                f'Content-Type: application/octet-stream\r\n'
                f'\r\n'
            )
            # File content added as bytes below
        body = ''.join(parts).encode('utf-8')
        if file_field and file_bytes is not None:
            body += file_bytes + f'\r\n--{boundary}--\r\n'.encode('utf-8')
        else:
            body += f'--{boundary}--\r\n'.encode('utf-8')
        content_type = f'multipart/form-data; boundary={boundary}'
        return body, content_type

    # --------------------------------------------------------------------- #
    #  Proxy helpers                                                          #
    # --------------------------------------------------------------------- #

    async def _proxy_simple(
        self, method: str, path: str, timeout: Optional[float] = None
    ) -> Dict[str, Any]:
        """Proxy a simple GET/DELETE with no body via Moonraker HttpClient."""
        url = f"{self.orcaslicer_url}{path}"
        t = timeout or 10.0
        try:
            if method == "GET":
                resp = await self.http_client.get(
                    url, request_timeout=t)
            elif method == "DELETE":
                resp = await self.http_client.delete(
                    url, request_timeout=t)
            else:
                resp = await self.http_client.request(
                    method=method, url=url, request_timeout=t)
        except Exception as e:
            raise self.server.error(
                f"orcaslicer-web unreachable: {e}", 503)

        if resp.has_error():
            raise self.server.error(
                f"orcaslicer-web error: {resp.text}", resp.status_code)

        return resp.json()

    async def _send_multipart(
        self,
        method: str,
        path: str,
        body: bytes,
        content_type: str,
        timeout: Optional[float] = None,
    ):
        """Send a request with a constructed body via Tornado."""
        url = f"{self.orcaslicer_url}{path}"
        t = timeout or float(self.request_timeout)
        request = HTTPRequest(
            url,
            method=method,
            body=body,
            headers=HTTPHeaders({"Content-Type": content_type}),
            request_timeout=t,
            allow_nonstandard_methods=True,
        )
        try:
            response = await self.raw_client.fetch(
                request, raise_error=False)
        except Exception as e:
            raise self.server.error(
                f"orcaslicer-web unreachable: {e}", 503)

        return response

    # --------------------------------------------------------------------- #
    #  Validation                                                             #
    # --------------------------------------------------------------------- #

    def _validate_profile_type(self, profile_type: str) -> None:
        if profile_type not in VALID_PROFILE_TYPES:
            raise self.server.error(
                f"Invalid profile type '{profile_type}'. "
                f"Must be one of: {', '.join(sorted(VALID_PROFILE_TYPES))}",
                400,
            )

    # --------------------------------------------------------------------- #
    #  Endpoint handlers                                                      #
    # --------------------------------------------------------------------- #

    async def _handle_ui(self, web_request: WebRequest) -> str:
        """Serve the slicer UI as text/html."""
        try:
            html = self._ui_path.read_text(encoding='utf-8')
        except OSError as e:
            raise self.server.error(f"Failed to read UI: {e}", 500)
        # Write the HTML directly to the Tornado RequestHandler so we
        # bypass Moonraker's JSON serialisation.
        handler = None
        for attr in ('request_handler', '_request_handler', '_handler'):
            handler = getattr(web_request, attr, None)
            if handler is not None and hasattr(handler, 'write'):
                break
        if handler is not None and hasattr(handler, 'write'):
            handler.set_header('Content-Type', 'text/html; charset=utf-8')
            handler.write(html)
            handler.finish()
            return None  # type: ignore
        # If we can't find the handler, fall back to returning the string.
        # Moonraker will likely JSON-wrap it, but this is better than 500.
        LOG.warning("Could not locate Tornado handler; UI may not render")
        return html

    async def _handle_health(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._proxy_simple("GET", "/api/health")

    async def _handle_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._proxy_simple("GET", "/api/slice/status")

    async def _handle_profiles_collection(
        self, web_request: WebRequest
    ) -> Dict[str, Any]:
        profile_type = web_request.get_str('profile_type')
        self._validate_profile_type(profile_type)

        action = web_request.get_action()

        if action == "GET":
            return await self._proxy_simple(
                "GET", f"/api/profiles/{profile_type}")

        # POST — upload a new profile.
        # The browser JS reads the file and sends JSON:
        #   { "filename": "...", "content": "..." }
        # We reconstruct a multipart upload for orcaslicer-web.
        filename = web_request.get_str('filename')
        content = web_request.get_str('content')

        body, ct = self._build_multipart(
            fields={},
            file_field='file',
            file_name=filename,
            file_bytes=content.encode('utf-8'),
        )
        response = await self._send_multipart(
            "POST", f"/api/profiles/{profile_type}", body, ct, timeout=30)

        if response.code >= 400:
            body_text = response.body.decode('utf-8', errors='replace')
            raise self.server.error(
                f"Profile upload failed: {body_text}", response.code)

        return json.loads(response.body)

    async def _handle_profile_item(
        self, web_request: WebRequest
    ) -> Dict[str, Any]:
        profile_type = web_request.get_str('profile_type')
        profile_name = web_request.get_str('profile_name')
        self._validate_profile_type(profile_type)

        action = web_request.get_action()
        api_path = f"/api/profiles/{profile_type}/{profile_name}"

        if action == "GET":
            return await self._proxy_simple("GET", api_path)

        if action == "DELETE":
            return await self._proxy_simple("DELETE", api_path)

        # POST — rename operation.  Browser sends JSON: { "new_name": "..." }
        new_name = web_request.get_str('new_name')
        rename_body = json.dumps({"new_name": new_name}).encode('utf-8')
        response = await self._send_multipart(
            "PATCH", api_path, rename_body,
            'application/json', timeout=10)

        if response.code >= 400:
            body_text = response.body.decode('utf-8', errors='replace')
            raise self.server.error(
                f"Profile operation failed: {body_text}", response.code)

        return json.loads(response.body)

    async def _handle_slice(self, web_request: WebRequest) -> Dict[str, Any]:
        # The browser JS reads the model file and sends JSON:
        #   { "model_filename": "...", "model_data": "<base64>",
        #     "printer": "...", "process": "...", "filament": "..." }
        model_filename = web_request.get_str('model_filename')
        model_data_b64 = web_request.get_str('model_data')
        printer = web_request.get_str('printer')
        process = web_request.get_str('process')
        filament = web_request.get_str('filament')

        try:
            model_bytes = base64.b64decode(model_data_b64)
        except Exception:
            raise self.server.error("Invalid base64 model data", 400)

        body, ct = self._build_multipart(
            fields={
                'printer': printer,
                'process': process,
                'filament': filament,
            },
            file_field='model',
            file_name=model_filename,
            file_bytes=model_bytes,
        )

        response = await self._send_multipart(
            "POST", "/api/slice", body, ct,
            timeout=float(self.request_timeout))

        if response.code == 409:
            raise self.server.error("Slicer is busy", 409)
        if response.code >= 400:
            body_text = response.body.decode('utf-8', errors='replace')
            raise self.server.error(
                f"Slice failed: {body_text}", response.code)

        # Extract filename from Content-Disposition header
        cd = response.headers.get('Content-Disposition', '')
        match = re.search(r'filename="?([^";\s]+)"?', cd)
        filename = (match.group(1)
                    if match
                    else f"slice_{uuid.uuid4().hex[:8]}.gcode")

        # Sanitise filename
        filename = pathlib.Path(filename).name
        if not filename.endswith('.gcode'):
            filename += '.gcode'

        # Write GCODE to the gcodes directory
        output_path = self.gcodes_path / filename
        self.gcodes_path.mkdir(parents=True, exist_ok=True)

        try:
            output_path.write_bytes(response.body)
        except OSError as e:
            raise self.server.error(
                f"Failed to write GCODE file: {e}", 500)

        slice_time = response.headers.get('X-Slice-Time-Seconds', 'unknown')
        LOG.info(
            f"Slice complete: {filename} "
            f"({len(response.body)} bytes, {slice_time}s)"
        )

        return {
            'filename': filename,
            'size': len(response.body),
            'slice_time': slice_time,
        }


def load_component(config: ConfigHelper) -> OrcaSlicer:
    return OrcaSlicer(config)

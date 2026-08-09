import base64
import json

import pytest

from conftest import FakeRawResponse, ServerError


def make_slice_request(make_web_request, **overrides):
    args = {
        "model_filename": "cube.stl",
        "model_data": base64.b64encode(b"fake-stl-bytes").decode(),
        "printer": "my-printer",
        "process": "my-process",
        "filament": "my-filament",
    }
    args.update(overrides)
    return make_web_request(args, action="POST")


async def test_slice_success_writes_gcode(slicer, raw_client, make_web_request, gcodes_path):
    raw_client.queue_response(
        FakeRawResponse(
            200,
            headers={
                "Content-Disposition": 'attachment; filename="cube.gcode"',
                "X-Slice-Time-Seconds": "12.3",
            },
            body=b"; sliced gcode content",
        )
    )
    req = make_slice_request(make_web_request)
    result = await slicer._handle_slice(req)

    assert result["filename"] == "cube.gcode"
    assert result["slice_time"] == "12.3"
    written = gcodes_path / "cube.gcode"
    assert written.read_bytes() == b"; sliced gcode content"


async def test_slice_sends_correct_multipart_fields(slicer, raw_client, make_web_request):
    raw_client.queue_response(FakeRawResponse(200, body=b"gcode"))
    req = make_slice_request(make_web_request, bed_type="Textured PEI Plate")
    await slicer._handle_slice(req)

    sent = raw_client.requests[0]
    assert sent.method == "POST"
    assert sent.url == "http://localhost:5000/api/slice"
    assert b"my-printer" in sent.body
    assert b"my-process" in sent.body
    assert b"my-filament" in sent.body
    assert b"Textured PEI Plate" in sent.body
    assert b"fake-stl-bytes" in sent.body


async def test_slice_invalid_base64_returns_400(slicer, raw_client, make_web_request):
    req = make_slice_request(make_web_request, model_data="not-valid-base64!!!")
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_slice(req)
    assert exc_info.value.status_code == 400


async def test_slice_forwards_process_overrides(slicer, raw_client, make_web_request):
    raw_client.queue_response(FakeRawResponse(200, body=b"gcode"))
    req = make_slice_request(
        make_web_request,
        layer_height="0.28",
        fill_density="25",
        enable_support="1",
        orient="1",
    )
    await slicer._handle_slice(req)

    sent = raw_client.requests[0]
    assert b"0.28" in sent.body
    assert b"25" in sent.body
    assert b'name="enable_support"' in sent.body
    assert b'name="orient"' in sent.body


async def test_slice_omits_process_overrides_when_not_provided(
    slicer, raw_client, make_web_request
):
    raw_client.queue_response(FakeRawResponse(200, body=b"gcode"))
    req = make_slice_request(make_web_request)
    await slicer._handle_slice(req)

    sent = raw_client.requests[0]
    assert b'name="layer_height"' not in sent.body
    assert b'name="fill_density"' not in sent.body
    assert b'name="enable_support"' not in sent.body
    assert b'name="orient"' not in sent.body


async def test_slice_busy_returns_409(slicer, raw_client, make_web_request):
    raw_client.queue_response(FakeRawResponse(409, body=b"busy"))
    req = make_slice_request(make_web_request)
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_slice(req)
    assert exc_info.value.status_code == 409
    assert "busy" in str(exc_info.value).lower()


async def test_slice_error_passthrough(slicer, raw_client, make_web_request):
    raw_client.queue_response(FakeRawResponse(500, body=b"slicer crashed"))
    req = make_slice_request(make_web_request)
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_slice(req)
    assert exc_info.value.status_code == 500
    assert "slicer crashed" in str(exc_info.value)


async def test_slice_debug_mode_returns_full_json_payload(
    slicer, raw_client, make_web_request
):
    slicer.debug = True
    raw_client.queue_response(
        FakeRawResponse(
            500,
            body=b'{"error": "Slicing failed: no GCODE output produced", '
                 b'"exit_code": 251, "stdout": "run found error\\n", '
                 b'"stderr": "unknown config type in load-settings"}',
        )
    )
    req = make_slice_request(make_web_request)
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_slice(req)

    assert exc_info.value.status_code == 500
    payload = json.loads(str(exc_info.value))
    assert payload["upstream_status"] == 500
    assert payload["exit_code"] == 251
    assert payload["printer"] == "my-printer"
    assert payload["process"] == "my-process"
    assert payload["filament"] == "my-filament"
    assert "unknown config type" in payload["stderr"]


async def test_slice_debug_mode_wraps_non_json_upstream_body(
    slicer, raw_client, make_web_request
):
    slicer.debug = True
    raw_client.queue_response(FakeRawResponse(500, body=b"not json at all"))
    req = make_slice_request(make_web_request)
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_slice(req)

    payload = json.loads(str(exc_info.value))
    assert payload["raw_body"] == "not json at all"


async def test_slice_falls_back_to_generated_filename(
    slicer, raw_client, make_web_request, gcodes_path
):
    raw_client.queue_response(FakeRawResponse(200, headers={}, body=b"gcode"))
    req = make_slice_request(make_web_request)
    result = await slicer._handle_slice(req)

    assert result["filename"].endswith(".gcode")
    assert (gcodes_path / result["filename"]).exists()


async def test_slice_forces_gcode_extension(slicer, raw_client, make_web_request, gcodes_path):
    raw_client.queue_response(
        FakeRawResponse(
            200,
            headers={"Content-Disposition": 'attachment; filename="cube.txt"'},
            body=b"gcode",
        )
    )
    req = make_slice_request(make_web_request)
    result = await slicer._handle_slice(req)

    assert result["filename"] == "cube.txt.gcode"


async def test_slice_sanitizes_path_traversal_in_filename(
    slicer, raw_client, make_web_request, gcodes_path
):
    raw_client.queue_response(
        FakeRawResponse(
            200,
            headers={
                "Content-Disposition": 'attachment; filename="../../etc/evil.gcode"'
            },
            body=b"gcode",
        )
    )
    req = make_slice_request(make_web_request)
    result = await slicer._handle_slice(req)

    assert result["filename"] == "evil.gcode"
    assert (gcodes_path / "evil.gcode").exists()
    assert not (gcodes_path.parent.parent / "etc" / "evil.gcode").exists()


async def test_slice_creates_gcodes_dir_if_missing(
    slicer, raw_client, make_web_request, gcodes_path
):
    assert not gcodes_path.exists()
    raw_client.queue_response(FakeRawResponse(200, body=b"gcode"))
    req = make_slice_request(make_web_request)
    await slicer._handle_slice(req)
    assert gcodes_path.is_dir()

import pytest

from conftest import FakeRawResponse, ServerError
from fakemoonraker.components.http_client import FakeHttpResponse


async def test_health_proxies_to_orcaslicer_web(slicer, http_client):
    http_client.queue_response(FakeHttpResponse(200, json_body={"status": "ok"}))
    result = await slicer._handle_health(None)
    assert result == {"status": "ok"}
    assert http_client.calls[0]["url"] == "http://localhost:5000/api/health"


async def test_status_proxies_to_orcaslicer_web(slicer, http_client):
    http_client.queue_response(FakeHttpResponse(200, json_body={"busy": False}))
    result = await slicer._handle_status(None)
    assert result == {"busy": False}
    assert http_client.calls[0]["url"] == "http://localhost:5000/api/slice/status"


async def test_proxy_simple_returns_503_when_unreachable(slicer, http_client):
    http_client.raises = ConnectionRefusedError("no route to host")
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_health(None)
    assert exc_info.value.status_code == 503
    assert "unreachable" in str(exc_info.value)


async def test_proxy_simple_passes_through_error_status(slicer, http_client):
    http_client.queue_response(FakeHttpResponse(500, text="boom"))
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_health(None)
    assert exc_info.value.status_code == 500
    assert "boom" in str(exc_info.value)


async def test_profile_item_get(slicer, http_client, make_web_request):
    http_client.queue_response(
        FakeHttpResponse(200, json_body={"name": "my-printer"})
    )
    req = make_web_request(
        {"profile_type": "printer", "profile_name": "my-printer"}, action="GET"
    )
    result = await slicer._handle_profile_item(req)
    assert result == {"name": "my-printer"}
    assert http_client.calls[0]["url"] == (
        "http://localhost:5000/api/profiles/printer/my-printer"
    )


async def test_profile_item_delete(slicer, http_client, make_web_request):
    http_client.queue_response(FakeHttpResponse(200, json_body={"deleted": True}))
    req = make_web_request(
        {"profile_type": "printer", "profile_name": "my-printer"}, action="DELETE"
    )
    result = await slicer._handle_profile_item(req)
    assert result == {"deleted": True}
    assert http_client.calls[0]["method"] == "DELETE"


async def test_profile_item_rename(slicer, raw_client, make_web_request):
    raw_client.queue_response(
        FakeRawResponse(200, body=b'{"renamed": true}')
    )
    req = make_web_request(
        {
            "profile_type": "printer",
            "profile_name": "old-name",
            "new_name": "new-name",
        },
        action="POST",
    )
    result = await slicer._handle_profile_item(req)
    assert result == {"renamed": True}
    sent = raw_client.requests[0]
    assert sent.method == "PATCH"
    assert sent.url == "http://localhost:5000/api/profiles/printer/old-name"
    assert b'"new-name"' in sent.body


async def test_profile_item_rename_failure_passthrough(
    slicer, raw_client, make_web_request
):
    raw_client.queue_response(FakeRawResponse(409, body=b"name taken"))
    req = make_web_request(
        {"profile_type": "printer", "profile_name": "a", "new_name": "b"},
        action="POST",
    )
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_profile_item(req)
    assert exc_info.value.status_code == 409
    assert "name taken" in str(exc_info.value)


async def test_profile_upload(slicer, raw_client, make_web_request):
    raw_client.queue_response(FakeRawResponse(201, body=b'{"uploaded": true}'))
    req = make_web_request(
        {
            "profile_type": "printer",
            "filename": "my-printer.json",
            "content": '{"nozzle_diameter": [0.4]}',
        },
        action="POST",
    )
    result = await slicer._handle_profiles_collection(req)
    assert result == {"uploaded": True}
    sent = raw_client.requests[0]
    assert sent.method == "POST"
    assert sent.url == "http://localhost:5000/api/profiles/printer"
    assert b"my-printer.json" in sent.body
    assert b"nozzle_diameter" in sent.body


async def test_registers_expected_endpoints(slicer):
    paths = {e["path"] for e in slicer.server.endpoints}
    assert "/server/orcaslicer/health" in paths
    assert "/server/orcaslicer/status" in paths
    assert "/server/orcaslicer/slice" in paths
    assert any(p.startswith("/server/orcaslicer/profiles/") for p in paths)

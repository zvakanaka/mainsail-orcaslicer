import pytest

from conftest import ServerError


async def test_rejects_invalid_profile_type(slicer, make_web_request):
    req = make_web_request({"profile_type": "nozzle"}, action="GET")
    with pytest.raises(ServerError) as exc_info:
        await slicer._handle_profiles_collection(req)
    assert exc_info.value.status_code == 400
    assert "nozzle" in str(exc_info.value)


@pytest.mark.parametrize("profile_type", ["printer", "process", "filament"])
async def test_accepts_valid_profile_types(
    slicer, make_web_request, http_client, profile_type
):
    from fakemoonraker.components.http_client import FakeHttpResponse

    http_client.queue_response(FakeHttpResponse(200, json_body=[]))
    req = make_web_request({"profile_type": profile_type}, action="GET")
    result = await slicer._handle_profiles_collection(req)
    assert result == []
    assert http_client.calls[0]["url"] == (
        f"http://localhost:5000/api/profiles/{profile_type}"
    )

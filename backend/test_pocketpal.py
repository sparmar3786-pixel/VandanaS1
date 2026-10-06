import pytest

import ai_orchestrator as ai


def test_pocketpal_requires_backend_url(monkeypatch):
    monkeypatch.setattr(ai, "POCKETPAL_URL", "")
    with pytest.raises(RuntimeError, match="POCKETPAL_URL is not configured"):
        ai.pocketpal_chat("hello")


def test_pocketpal_uses_server_side_auth_and_clamps_temperature(monkeypatch):
    calls = {}

    class Response:
        def raise_for_status(self):
            pass

        def json(self):
            return {"response": "OK", "tokens_used": 1}

    def fake_post(url, **kwargs):
        calls.update({"url": url, **kwargs})
        return Response()

    monkeypatch.setattr(ai, "POCKETPAL_URL", "http://pocketpal.test")
    monkeypatch.setattr(ai, "POCKETPAL_TOKEN", "server-secret")
    monkeypatch.setattr(ai.requests, "post", fake_post)

    result = ai.pocketpal_chat("hello", temperature=99)

    assert result["response"] == "OK"
    assert calls["url"] == "http://pocketpal.test/api/chat"
    assert calls["json"]["temperature"] == 2.0
    assert calls["headers"]["Authorization"] == "Bearer server-secret"

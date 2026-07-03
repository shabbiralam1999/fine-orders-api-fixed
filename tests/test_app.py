def test_index_returns_service_status(client):
    response = client.get("/")
    assert response.status_code == 200
    body = response.get_json()
    assert body["service"] == "orders-api"
    assert body["status"] == "ok"


def test_healthz_returns_healthy(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "healthy"}


def test_orders_returns_order_list(client):
    response = client.get("/orders")
    assert response.status_code == 200
    body = response.get_json()
    assert "orders" in body
    assert isinstance(body["orders"], list)
    assert body["orders"][0]["item"] == "widget"


def test_unknown_route_returns_404(client):
    response = client.get("/does-not-exist")
    assert response.status_code == 404

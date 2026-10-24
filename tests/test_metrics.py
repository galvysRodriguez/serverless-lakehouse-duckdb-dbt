from lakehouse.metrics import estimate_cost, runtime


def test_estimate_cost_uses_configured_rates(monkeypatch):
    monkeypatch.setenv("LAKEHOUSE_COST_PER_SECOND", "0.00004")
    monkeypatch.setenv("LAKEHOUSE_COST_PER_RUN", "0.0000002")
    assert estimate_cost(10) == 0.0004002


def test_estimate_cost_is_unknown_without_rates(monkeypatch):
    monkeypatch.delenv("LAKEHOUSE_COST_PER_SECOND", raising=False)
    assert estimate_cost(10) is None


def test_runtime_detection(monkeypatch):
    monkeypatch.delenv("AWS_LAMBDA_FUNCTION_NAME", raising=False)
    monkeypatch.delenv("K_SERVICE", raising=False)
    assert runtime() == "local"
    monkeypatch.setenv("K_SERVICE", "lakehouse")
    assert runtime() == "gcp-cloud-run"

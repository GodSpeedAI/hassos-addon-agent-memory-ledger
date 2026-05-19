"""Tests for BridgeConfig."""

import os


class TestBridgeConfig:
    """Tests for BridgeConfig dataclass and from_env()."""

    def test_default_values(self, bridge_module):
        cfg = bridge_module.BridgeConfig()
        assert cfg.db_host == "localhost"
        assert cfg.db_port == 5432
        assert cfg.db_name == "agent_memory"
        assert cfg.db_user == "bridge_worker"
        assert cfg.nats_url == "nats://127.0.0.1:4222"
        assert cfg.js_stream_name == "SEA_LEDGER"
        assert cfg.health_port == 8099
        assert cfg.fail_closed is True

    def test_from_env_defaults(self, bridge_module):
        # Clear any existing env vars
        env_vars = [
            "DB_HOST",
            "DB_PORT",
            "DB_NAME",
            "DB_USER",
            "DB_PASSWORD",
            "NATS_URL",
            "HEALTH_PORT",
            "JS_ENABLED",
        ]
        saved = {}
        for v in env_vars:
            saved[v] = os.environ.pop(v, None)
        try:
            cfg = bridge_module.BridgeConfig.from_env()
            assert cfg.db_host == "localhost"
            assert cfg.db_port == 5432
            assert cfg.health_port == 8099
        finally:
            for v, val in saved.items():
                if val is not None:
                    os.environ[v] = val

    def test_from_env_custom(self, bridge_module):
        saved = {
            "DB_HOST": os.environ.get("DB_HOST"),
            "DB_PORT": os.environ.get("DB_PORT"),
            "HEALTH_PORT": os.environ.get("HEALTH_PORT"),
        }
        try:
            os.environ["DB_HOST"] = "myhost"
            os.environ["DB_PORT"] = "5433"
            os.environ["HEALTH_PORT"] = "9090"
            cfg = bridge_module.BridgeConfig.from_env()
            assert cfg.db_host == "myhost"
            assert cfg.db_port == 5433
            assert cfg.health_port == 9090
        finally:
            for k, v in saved.items():
                if v is not None:
                    os.environ[k] = v
                else:
                    os.environ.pop(k, None)

    def test_db_dsn(self, bridge_module):
        cfg = bridge_module.BridgeConfig(
            db_host="myhost",
            db_port=5433,
            db_name="mydb",
            db_user="myuser",
            db_password="mypass",
        )
        assert cfg.db_dsn == "postgresql://myuser:mypass@myhost:5433/mydb"

    def test_db_dsn_url_encodes_password(self, bridge_module):
        cfg = bridge_module.BridgeConfig(
            db_host="myhost",
            db_port=5433,
            db_name="mydb",
            db_user="myuser",
            db_password="p@ss word:/?#[]",
        )
        assert cfg.db_dsn == "postgresql://myuser:p%40ss+word%3A%2F%3F%23%5B%5D@myhost:5433/mydb"

    def test_js_subjects_default(self, bridge_module):
        cfg = bridge_module.BridgeConfig()
        assert "sea.agent.event.>" in cfg.js_subjects
        assert "sea.governance.request.>" in cfg.js_subjects
        assert "sea.governance.decision.>" in cfg.js_subjects
        assert "sea.memory.write.>" in cfg.js_subjects
        assert "sea.memory.lifecycle.>" in cfg.js_subjects

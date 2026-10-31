import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("molly_lavalink_env", Path("ops/configure_lavalink_env.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

total = 0
failed = 0


def test(name, fn):
    global total, failed
    total += 1
    try:
        fn()
        print("ok - " + name)
    except Exception as error:
        failed += 1
        print("not ok - " + name + ": " + type(error).__name__)


def test_extracts_only_required_credentials():
    result = module.extract_container_env([{"Config": {"Env": [
        "LAVALINK_SERVER_PASSWORD=password-fixture",
        "SPOTIFY_CLIENT_ID=id-fixture",
        "SPOTIFY_CLIENT_SECRET=secret-fixture",
        "UNRELATED=value",
    ]}}])
    assert set(result) == set(module.REQUIRED_SOURCE_KEYS)
    assert len(module.render_env(result).splitlines()) == 3


def test_rejects_missing_duplicate_or_multiline_credentials():
    cases = [
        ["LAVALINK_SERVER_PASSWORD=x", "SPOTIFY_CLIENT_ID=y"],
        ["LAVALINK_SERVER_PASSWORD=x", "LAVALINK_SERVER_PASSWORD=x", "SPOTIFY_CLIENT_ID=y", "SPOTIFY_CLIENT_SECRET=z"],
        ["LAVALINK_SERVER_PASSWORD=x\ny", "SPOTIFY_CLIENT_ID=y", "SPOTIFY_CLIENT_SECRET=z"],
    ]
    for entries in cases:
        try:
            module.extract_container_env([{"Config": {"Env": entries}}])
            raise AssertionError("invalid source credentials were accepted")
        except ValueError:
            pass


def test_checks_existing_molly_auth_without_disclosing_it():
    source = {"LAVALINK_SERVER_PASSWORD": "source-fixture"}
    module.verify_molly_password({"MOLLY_LAVALINK_PASSWORD": "source-fixture"}, source)
    try:
        module.verify_molly_password({"MOLLY_LAVALINK_PASSWORD": "different-fixture"}, source)
        raise AssertionError("mismatching credentials were accepted")
    except ValueError as error:
        assert str(error) == "molly_lavalink_auth_mismatch"
        assert "source-fixture" not in str(error)
        assert "different-fixture" not in str(error)


def test_raw_env_render_is_deterministic():
    source = {
        "LAVALINK_SERVER_PASSWORD": "password-fixture",
        "SPOTIFY_CLIENT_ID": "id-fixture",
        "SPOTIFY_CLIENT_SECRET": "secret-fixture",
    }
    result = module.render_env(source)
    assert result.splitlines() == [f"{key}={source[key]}" for key in module.REQUIRED_SOURCE_KEYS]


test("extracts only Lavalink and Spotify credentials", test_extracts_only_required_credentials)
test("rejects missing duplicate and multiline credentials", test_rejects_missing_duplicate_or_multiline_credentials)
test("checks existing Molly auth without disclosing it", test_checks_existing_molly_auth_without_disclosing_it)
test("renders a deterministic raw environment file", test_raw_env_render_is_deterministic)
print(f"{total} tests, {failed} failures")
raise SystemExit(1 if failed else 0)

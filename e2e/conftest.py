import os

# cast/forge and the observability scripts are invoked with repo-relative paths
# (src/..., scripts/...). `import alpha_e2e` itself is resolved by
# `pythonpath = .` in pytest.ini.
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault("RUST_LOG", "error,alloy_provider::blocks=off")

pytest_plugins = ["alpha_e2e.fixtures"]

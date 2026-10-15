import os

# cast, forge and the scripts take repo-relative paths.
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault("RUST_LOG", "error,alloy_provider::blocks=off")

pytest_plugins = ["alpha_e2e.fixtures"]

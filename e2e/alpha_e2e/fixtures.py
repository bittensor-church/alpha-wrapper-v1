import pytest

from . import bootstrap, config


@pytest.fixture(scope="session")
def recovery_window():
    return config.RECOVERY_WINDOW_SECONDS


@pytest.fixture(scope="session")
def env(recovery_window):
    return bootstrap.build_environment(recovery_window=recovery_window)

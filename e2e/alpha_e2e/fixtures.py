import pytest

from . import bootstrap


@pytest.fixture(scope="session")
def recovery_window():
    return 3 * 60 * 60


@pytest.fixture(scope="session")
def env(recovery_window):
    return bootstrap.build_environment(recovery_window=recovery_window)

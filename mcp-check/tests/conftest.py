from __future__ import annotations

from pathlib import Path

import pytest


@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    return Path(__file__).parent / "fixtures"


@pytest.fixture()
def state_dir(tmp_path: Path) -> Path:
    return tmp_path / "state"


@pytest.fixture()
def root_path(fixtures_dir: Path) -> Path:
    return fixtures_dir

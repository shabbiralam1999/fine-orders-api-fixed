import os
import sys

# Make sure a SECRET_KEY is present before app.py is imported, since app.py
# now fails fast if it's missing (see app/app.py).
os.environ.setdefault("SECRET_KEY", "test-secret-key")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

import pytest

from app import app as flask_app


@pytest.fixture
def client():
    flask_app.config.update(TESTING=True)
    with flask_app.test_client() as test_client:
        yield test_client

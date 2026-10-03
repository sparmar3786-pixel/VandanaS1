"""Railway entrypoint for the canonical NSE Algo backend.

Railway service root should be set to /backend.
The application itself remains backend/server.py so Railway, Fly.io and local
deployments use the same API implementation.
"""
from server import app

__all__ = ["app"]

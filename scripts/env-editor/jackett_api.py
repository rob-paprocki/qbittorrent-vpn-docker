"""Thin wrapper over Jackett's REST API for listing and configuring indexers."""
from __future__ import annotations

from typing import Any

import requests
import xml.etree.ElementTree as ET


class JackettClient:
    """Jackett API client scoped to one host+key.

    The relevant endpoints:
      GET  /api/v2.0/indexers/all/results/torznab/api?t=indexers&configured=false
      GET  /api/v2.0/indexers/all/results/torznab/api?t=indexers&configured=true
      POST /api/v2.0/indexers/<id>/config
      GET  /api/v2.0/indexers/<id>/config
      DELETE /api/v2.0/indexers/<id>
    """

    def __init__(self, base_url: str, api_key: str, timeout: int = 10):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def ping(self) -> bool:
        try:
            r = requests.get(f"{self.base_url}/UI/Dashboard", timeout=self.timeout)
            return r.status_code < 500
        except requests.RequestException:
            return False

    def list_indexers(self, configured: bool | None = None) -> list[dict[str, Any]]:
        """Return a list of {id, name, type, description, configured}.

        Jackett returns Torznab XML here; parse to a flat list.
        """
        params = {"t": "indexers", "apikey": self.api_key}
        if configured is True:
            params["configured"] = "true"
        elif configured is False:
            params["configured"] = "false"
        r = requests.get(
            f"{self.base_url}/api/v2.0/indexers/all/results/torznab/api",
            params=params, timeout=self.timeout,
        )
        r.raise_for_status()
        return _parse_indexer_xml(r.text)

    def get_config_schema(self, indexer_id: str) -> list[dict[str, Any]]:
        """Return the per-field schema Jackett wants for a given indexer.

        Each item: {id, type, name, value}. Types seen in the wild:
          'inputstring', 'inputbool', 'inputselect', 'displayinfo', 'hiddendata'.
        """
        r = requests.get(
            f"{self.base_url}/api/v2.0/indexers/{indexer_id}/config",
            params={"apikey": self.api_key}, timeout=self.timeout,
        )
        r.raise_for_status()
        return r.json()

    def configure(self, indexer_id: str, config: list[dict[str, Any]]) -> dict[str, Any]:
        r = requests.post(
            f"{self.base_url}/api/v2.0/indexers/{indexer_id}/config",
            params={"apikey": self.api_key},
            json=config, timeout=self.timeout,
        )
        if r.status_code >= 400:
            try:
                detail = r.json()
            except ValueError:
                detail = {"error": r.text}
            return {"ok": False, "status": r.status_code, "detail": detail}
        return {"ok": True}

    def delete(self, indexer_id: str) -> bool:
        r = requests.delete(
            f"{self.base_url}/api/v2.0/indexers/{indexer_id}",
            params={"apikey": self.api_key}, timeout=self.timeout,
        )
        return r.status_code < 400


def _parse_indexer_xml(xml_text: str) -> list[dict[str, Any]]:
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return []
    out: list[dict[str, Any]] = []
    for ind in root.findall(".//indexer"):
        out.append({
            "id": ind.attrib.get("id", ""),
            "name": (ind.findtext("title") or "").strip(),
            "description": (ind.findtext("description") or "").strip(),
            "type": (ind.findtext("type") or "").strip(),
            "language": (ind.findtext("language") or "").strip(),
            "configured": (ind.findtext("configured") or "").strip().lower() == "true",
        })
    return out

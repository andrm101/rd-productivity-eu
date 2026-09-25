"""
Shared utilities: manifest writing, SHA-256 hashing, idempotency guards.
"""
import hashlib
import json
import logging
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

log = logging.getLogger(__name__)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def write_manifest(
    manifest_path: Path,
    source_id: str,
    source_url: str,
    files: list[Path],
    vintage: str,
    extra: dict | None = None,
) -> None:
    """Write or append a JSON-lines manifest entry for one ingest run."""
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "source_id":  source_id,
        "source_url": source_url,
        "vintage":    vintage,
        "retrieved":  datetime.now(timezone.utc).isoformat(),
        "files":      [
            {"path": str(p.relative_to(p.parents[3])), "sha256": sha256(p)}
            for p in files
            if p.exists()
        ],
    }
    if extra:
        entry.update(extra)
    with open(manifest_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")
    log.info("Manifest updated: %s", manifest_path.name)


def is_already_ingested(manifest_path: Path, source_id: str, vintage: str) -> bool:
    """Return True if this source_id × vintage combination was already written today."""
    if not manifest_path.exists():
        return False
    today = datetime.now(timezone.utc).date().isoformat()
    with open(manifest_path, encoding="utf-8") as f:
        for line in f:
            try:
                entry = json.loads(line)
                if (
                    entry.get("source_id") == source_id
                    and entry.get("vintage") == vintage
                    and entry.get("retrieved", "")[:10] == today
                ):
                    return True
            except json.JSONDecodeError:
                continue
    return False


def long_to_wide(
    df: pd.DataFrame,
    index_cols: list[str],
    variable_col: str,
    value_col: str,
) -> pd.DataFrame:
    """Pivot a long panel to wide format, keeping index columns as-is."""
    return (
        df.pivot_table(
            index=index_cols, columns=variable_col, values=value_col, aggfunc="first"
        )
        .reset_index()
        .rename_axis(None, axis=1)
    )

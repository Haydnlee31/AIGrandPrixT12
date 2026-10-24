"""Optional SQLite FTS5 candidate lookup; other databases retain LIKE search."""
from __future__ import annotations

import re

from sqlalchemy import Integer, String, column, literal_column, select, table, text

from ..db import CatalogProduct


_TRIGGERS = {
    "catalog_fts_insert": """CREATE TRIGGER IF NOT EXISTS catalog_fts_insert AFTER INSERT ON catalog_products BEGIN
      INSERT INTO catalog_fts(rowid, search_text) VALUES (new.rowid, new.search_text);
    END""",
    "catalog_fts_delete": """CREATE TRIGGER IF NOT EXISTS catalog_fts_delete AFTER DELETE ON catalog_products BEGIN
      INSERT INTO catalog_fts(catalog_fts, rowid, search_text) VALUES ('delete', old.rowid, old.search_text);
    END""",
    "catalog_fts_update": """CREATE TRIGGER IF NOT EXISTS catalog_fts_update AFTER UPDATE ON catalog_products BEGIN
      INSERT INTO catalog_fts(catalog_fts, rowid, search_text) VALUES ('delete', old.rowid, old.search_text);
      INSERT INTO catalog_fts(rowid, search_text) VALUES (new.rowid, new.search_text);
    END""",
}


def ensure_index(connection):
    """Install/rebuild FTS only when missing, within the caller's transaction.

    SQLite rowid is the internal join key. Source filtering remains in the
    service's outer query, and no private Library table enters this index.
    PostgreSQL intentionally uses the existing portable search path.
    """
    if connection.dialect.name != "sqlite":
        return False
    existing = set(connection.execute(text(
        "SELECT name FROM sqlite_master WHERE name = 'catalog_fts' OR name IN "
        "('catalog_fts_insert', 'catalog_fts_delete', 'catalog_fts_update')"
    )).scalars())
    connection.exec_driver_sql(
        "CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5("
        "search_text, content='catalog_products', content_rowid='rowid', "
        "tokenize='unicode61 remove_diacritics 0')"
    )
    for statement in _TRIGGERS.values():
        connection.exec_driver_sql(statement)
    if "catalog_fts" not in existing or not set(_TRIGGERS).issubset(existing):
        connection.exec_driver_sql("INSERT INTO catalog_fts(catalog_fts) VALUES ('rebuild')")
    return True


def drop_index(connection):
    if connection.dialect.name != "sqlite":
        return
    for name in _TRIGGERS:
        connection.exec_driver_sql(f"DROP TRIGGER IF EXISTS {name}")
    connection.exec_driver_sql("DROP TABLE IF EXISTS catalog_fts")


def matching_product_ids(db, query):
    """Return an indexed candidate-ID SELECT, or None for the LIKE fallback.

    ASCII word queries use AND between quoted token prefixes. Punctuation,
    non-ASCII input and unavailable indexes retain existing literal substring
    behavior. Inputs never become unquoted FTS operators or SQL syntax.
    """
    if (db.get_bind().dialect.name != "sqlite" or not isinstance(query, str) or not 1 <= len(query) <= 100
            or not query.isascii() or any(ord(char) < 32 for char in query)):
        return None
    query = query.strip().casefold()
    if not re.fullmatch(r"[a-z0-9]+(?: +[a-z0-9]+)*", query):
        return None
    if not db.scalar(text("SELECT 1 FROM sqlite_master WHERE type='table' AND name='catalog_fts'")):
        return None
    expression = " AND ".join(f'"{token}"*' for token in query.split())
    fts = table("catalog_fts", column("rowid", Integer), column("search_text", String))
    return select(CatalogProduct.id).join(
        fts, literal_column("catalog_products.rowid") == fts.c.rowid
    ).where(fts.c.search_text.match(expression))

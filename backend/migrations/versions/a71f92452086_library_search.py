"""Searchable private Library annotations.

Revision ID: a71f92452086
Revises: f60e81341f75
"""
from alembic import op
import sqlalchemy as sa
import unicodedata

revision = "a71f92452086"
down_revision = "f60e81341f75"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("saved_items", sa.Column("search_text", sa.String(), nullable=False, server_default=""))
    op.add_column("saved_items", sa.Column("category_text", sa.String(), nullable=False, server_default=""))
    # Existing captures remain searchable immediately. Rich product categories
    # are populated by the versioned analysis job, never guessed by a migration.
    from alembic import context
    if context.is_offline_mode():
        op.execute("UPDATE saved_items SET search_text = lower(title || ' ' || selected_text || ' ' || note || ' ' || original_url || ' ' || source) WHERE deleted = false")
        return
    bind = op.get_bind()
    rows = bind.execute(sa.text("SELECT id, title, selected_text, note, original_url, source FROM saved_items WHERE deleted = false")).mappings()
    for row in rows:
        text = " ".join(str(row[key] or "") for key in ("title", "selected_text", "note", "original_url", "source"))
        notes = bind.execute(sa.text("SELECT text FROM evidence WHERE item_id=:id AND active=true AND origin IN ('confirmed_annotation', 'explicit_statement')"), {"id": row["id"]}).scalars()
        text += " " + " ".join(dict.fromkeys(notes))
        bind.execute(sa.text("UPDATE saved_items SET search_text=:text WHERE id=:id"),
            {"text": " ".join(unicodedata.normalize("NFKC", text).casefold().split())[:64000], "id": row["id"]})


def downgrade():
    op.drop_column("saved_items", "category_text")
    op.drop_column("saved_items", "search_text")

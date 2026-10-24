"""Index source-scoped lookup/export and SQLite catalog full-text candidates."""
from alembic import op

from backend.app.catalog.search_index import drop_index, ensure_index

revision = "e59d79230e64"
down_revision = "d48c68120d53"
branch_labels = None
depends_on = None


def upgrade():
    op.create_index("ix_catalog_products_feed_id_id", "catalog_products", ["feed_id", "id"])
    op.create_index("ix_catalog_products_feed_record", "catalog_products", ["feed_id", "source_record_id"])
    ensure_index(op.get_bind())


def downgrade():
    drop_index(op.get_bind())
    op.drop_index("ix_catalog_products_feed_record", table_name="catalog_products")
    op.drop_index("ix_catalog_products_feed_id_id", table_name="catalog_products")

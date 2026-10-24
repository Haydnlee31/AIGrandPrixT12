"""Catalog-backed price observations; preserve existing simulated watches."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "b82fa63e9012"
down_revision = "a71f92452086"
branch_labels = None
depends_on = None


def upgrade():
    document = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")
    op.add_column("watch_rules", sa.Column("catalog_ref", document, nullable=True))
    op.add_column("watch_rules", sa.Column("next_check_at", sa.Float(), nullable=False, server_default="0"))
    op.add_column("watch_rules", sa.Column("check_status", sa.String(), nullable=True))
    op.add_column("price_observations", sa.Column("offer_snapshot", document, nullable=True))


def downgrade():
    # Dropping the identity would reinterpret merchant watches as fixture watches.
    from alembic import context
    if context.is_offline_mode():
        raise RuntimeError("Online validation is required before removing catalog watch identities")
    if op.get_bind().scalar(sa.text("SELECT count(*) FROM watch_rules WHERE check_status IS NOT NULL")):
        raise RuntimeError("Catalog watches exist; preserve/export them before downgrading")
    op.drop_column("price_observations", "offer_snapshot")
    op.drop_column("watch_rules", "check_status")
    op.drop_column("watch_rules", "next_check_at")
    op.drop_column("watch_rules", "catalog_ref")

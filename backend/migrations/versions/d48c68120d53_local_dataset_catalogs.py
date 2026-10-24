"""Allow historical catalog records without a current merchant offer."""
from alembic import op
import sqlalchemy as sa

revision = "d48c68120d53"
down_revision = "c38b57a10c42"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("catalog_imports") as batch:
        batch.alter_column("expires_at", existing_type=sa.Float(), nullable=True)
    with op.batch_alter_table("catalog_offers") as batch:
        batch.alter_column("merchant_id", existing_type=sa.String(), nullable=True)
        batch.alter_column("observed_at", existing_type=sa.Float(), nullable=True)
        batch.alter_column("expires_at", existing_type=sa.Float(), nullable=True)


def downgrade():
    # Refuse to erase historical records just to satisfy an older schema.
    connection = op.get_bind()
    if connection.execute(sa.text("SELECT COUNT(*) FROM catalog_offers WHERE merchant_id IS NULL OR observed_at IS NULL OR expires_at IS NULL")).scalar():
        raise RuntimeError("Revoke local dataset catalogs before downgrading this schema")
    if connection.execute(sa.text("SELECT COUNT(*) FROM catalog_imports WHERE expires_at IS NULL")).scalar():
        raise RuntimeError("Dataset import audit records must be archived before this schema downgrade")
    with op.batch_alter_table("catalog_offers") as batch:
        batch.alter_column("merchant_id", existing_type=sa.String(), nullable=False)
        batch.alter_column("observed_at", existing_type=sa.Float(), nullable=False)
        batch.alter_column("expires_at", existing_type=sa.Float(), nullable=False)
    with op.batch_alter_table("catalog_imports") as batch:
        batch.alter_column("expires_at", existing_type=sa.Float(), nullable=False)

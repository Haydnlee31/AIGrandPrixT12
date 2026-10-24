"""Track capture client independently from content source."""
from alembic import op
import sqlalchemy as sa

revision = "b1b3483f9a02"
down_revision = "d82e11b429d8"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("saved_items", sa.Column("client", sa.String(), nullable=False, server_default="web"))


def downgrade():
    op.drop_column("saved_items", "client")

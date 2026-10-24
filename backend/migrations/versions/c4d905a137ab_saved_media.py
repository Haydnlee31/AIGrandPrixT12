"""Private image attachments, separate from paginated save metadata."""
from alembic import op
import sqlalchemy as sa

revision = "c4d905a137ab"
down_revision = "b1b3483f9a02"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("saved_media", sa.Column("item_id", sa.String(), sa.ForeignKey("saved_items.id"), primary_key=True),
                    sa.Column("user_id", sa.String(), nullable=False), sa.Column("image_data", sa.String(), nullable=False))
    op.create_index("ix_saved_media_user_id", "saved_media", ["user_id"])


def downgrade():
    op.drop_table("saved_media")

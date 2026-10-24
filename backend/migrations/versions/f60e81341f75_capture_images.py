"""Private normalized images for predictive annotations.

Revision ID: f60e81341f75
Revises: e59d79230e64
"""
from alembic import op
import sqlalchemy as sa

revision = "f60e81341f75"
down_revision = "e59d79230e64"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("saved_items", sa.Column("image_data_url", sa.String(), nullable=True))


def downgrade():
    op.drop_column("saved_items", "image_data_url")

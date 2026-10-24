"""Add isolated, owned multimodal captures and binary assets.

Existing saves, local client libraries, and their identities are unchanged.
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "b82a03563197"
down_revision = "a71f92452086"
branch_labels = None
depends_on = None


def upgrade():
    document = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")
    op.create_table("multimodal_captures",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), nullable=False),
        sa.Column("title", sa.String(), nullable=False),
        sa.Column("text", sa.String(), nullable=False),
        sa.Column("note", sa.String(), nullable=False),
        sa.Column("url", sa.String(), nullable=True),
        sa.Column("client", sa.String(), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("stage", sa.String(), nullable=False),
        sa.Column("result", document, nullable=True),
        sa.Column("error_code", sa.String(), nullable=True),
        sa.Column("model_version", sa.String(), nullable=True),
        sa.Column("published_save_id", sa.String(), nullable=True),
        sa.Column("created_at", sa.Float(), nullable=False),
        sa.Column("updated_at", sa.Float(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False))
    op.create_index("ix_multimodal_captures_user_id", "multimodal_captures", ["user_id"])
    op.create_index("ix_multimodal_captures_published_save_id", "multimodal_captures", ["published_save_id"])
    op.create_table("multimodal_assets",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), nullable=False),
        sa.Column("capture_id", sa.String(), sa.ForeignKey("multimodal_captures.id"), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("media_type", sa.String(), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("content_hash", sa.String(), nullable=False),
        sa.Column("content", sa.LargeBinary(), nullable=False),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("transcript", sa.String(), nullable=True),
        sa.Column("transcript_origin", sa.String(), nullable=True),
        sa.Column("created_at", sa.Float(), nullable=False),
        sa.UniqueConstraint("capture_id", "content_hash"))
    op.create_index("ix_multimodal_assets_user_id", "multimodal_assets", ["user_id"])
    op.create_index("ix_multimodal_assets_capture_id", "multimodal_assets", ["capture_id"])


def downgrade():
    op.drop_table("multimodal_assets")
    op.drop_table("multimodal_captures")

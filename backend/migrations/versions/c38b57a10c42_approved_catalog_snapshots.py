"""approved_catalog_snapshots

Revision ID: c38b57a10c42
Revises: b1b3483f9a02
Create Date: 2026-10-25 00:22:30.390766

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = 'c38b57a10c42'
down_revision: Union[str, Sequence[str], None] = 'b1b3483f9a02'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('catalog_feeds',
    sa.Column('id', sa.String(), nullable=False),
    sa.Column('source_id', sa.String(), nullable=False),
    sa.Column('catalog_id', sa.String(), nullable=False),
    sa.Column('approval_reference', sa.String(), nullable=False),
    sa.Column('enabled', sa.Boolean(), nullable=False),
    sa.Column('last_import_id', sa.String(), nullable=True),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('source_id', 'catalog_id')
    )
    op.create_index(op.f('ix_catalog_feeds_source_id'), 'catalog_feeds', ['source_id'], unique=False)
    op.create_table('catalog_imports',
    sa.Column('id', sa.String(), nullable=False),
    sa.Column('feed_id', sa.String(), nullable=False),
    sa.Column('digest', sa.String(), nullable=False),
    sa.Column('approval_reference', sa.String(), nullable=False),
    sa.Column('imported_at', sa.Float(), nullable=False),
    sa.Column('source_observed_at', sa.Float(), nullable=False),
    sa.Column('expires_at', sa.Float(), nullable=False),
    sa.Column('row_count', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['feed_id'], ['catalog_feeds.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_catalog_imports_feed_id'), 'catalog_imports', ['feed_id'], unique=False)
    op.create_table('catalog_merchants',
    sa.Column('id', sa.String(), nullable=False),
    sa.Column('feed_id', sa.String(), nullable=False),
    sa.Column('external_id', sa.String(), nullable=False),
    sa.Column('name', sa.String(), nullable=False),
    sa.Column('platform', sa.String(), nullable=False),
    sa.ForeignKeyConstraint(['feed_id'], ['catalog_feeds.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_catalog_merchants_feed_id'), 'catalog_merchants', ['feed_id'], unique=False)
    op.create_table('catalog_products',
    sa.Column('id', sa.String(), nullable=False),
    sa.Column('feed_id', sa.String(), nullable=False),
    sa.Column('import_id', sa.String(), nullable=False),
    sa.Column('source_record_id', sa.String(), nullable=False),
    sa.Column('product_key', sa.String(), nullable=True),
    sa.Column('variant_key', sa.String(), nullable=True),
    sa.Column('title', sa.String(), nullable=False),
    sa.Column('search_text', sa.String(), nullable=False),
    sa.Column('record', sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), 'postgresql'), nullable=False),
    sa.ForeignKeyConstraint(['feed_id'], ['catalog_feeds.id'], ),
    sa.ForeignKeyConstraint(['import_id'], ['catalog_imports.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_catalog_products_feed_id'), 'catalog_products', ['feed_id'], unique=False)
    op.create_table('catalog_offers',
    sa.Column('id', sa.String(), nullable=False),
    sa.Column('product_id', sa.String(), nullable=False),
    sa.Column('merchant_id', sa.String(), nullable=False),
    sa.Column('price_minor', sa.BigInteger(), nullable=True),
    sa.Column('currency', sa.String(), nullable=True),
    sa.Column('availability', sa.String(), nullable=False),
    sa.Column('observed_at', sa.Float(), nullable=False),
    sa.Column('expires_at', sa.Float(), nullable=False),
    sa.ForeignKeyConstraint(['merchant_id'], ['catalog_merchants.id'], ),
    sa.ForeignKeyConstraint(['product_id'], ['catalog_products.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('product_id')
    )
    op.create_index(op.f('ix_catalog_offers_expires_at'), 'catalog_offers', ['expires_at'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f('ix_catalog_offers_expires_at'), table_name='catalog_offers')
    op.drop_table('catalog_offers')
    op.drop_index(op.f('ix_catalog_products_feed_id'), table_name='catalog_products')
    op.drop_table('catalog_products')
    op.drop_index(op.f('ix_catalog_merchants_feed_id'), table_name='catalog_merchants')
    op.drop_table('catalog_merchants')
    op.drop_index(op.f('ix_catalog_imports_feed_id'), table_name='catalog_imports')
    op.drop_table('catalog_imports')
    op.drop_index(op.f('ix_catalog_feeds_source_id'), table_name='catalog_feeds')
    op.drop_table('catalog_feeds')

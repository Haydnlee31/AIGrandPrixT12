"""Unify Chrome attachments with the shared private image column.

Both published migration histories remain valid upgrade starting points. Save IDs,
canonical dedupe keys, annotations and idempotency records are unchanged.
"""
from alembic import op

revision = "b82fa3563197"
down_revision = ("a71f92452086", "c4d905a137ab")
branch_labels = None
depends_on = None


def upgrade():
    op.execute("""UPDATE saved_items SET image_data_url = (
        SELECT image_data FROM saved_media
        WHERE saved_media.item_id = saved_items.id AND saved_media.user_id = saved_items.user_id
    ) WHERE deleted = false AND image_data_url IS NULL AND EXISTS (
        SELECT 1 FROM saved_media WHERE saved_media.item_id = saved_items.id AND saved_media.user_id = saved_items.user_id
    )""")
    # One private storage location going forward; retain the old table for history.
    op.execute("DELETE FROM saved_media")


def downgrade():
    op.execute("""INSERT INTO saved_media (item_id, user_id, image_data)
        SELECT id, user_id, image_data_url FROM saved_items
        WHERE deleted = false AND image_data_url IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM saved_media WHERE saved_media.item_id = saved_items.id)""")

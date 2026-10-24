"""Merge Chrome and multimodal histories, preserving private saved images.

Both main-only and earlier Chrome installations can upgrade to this one head.
Legacy media is normalized into the current column. The old row is retained for
rollback and for a previous deployment still serving requests during the build.
Invalid legacy media stops the migration instead of silently losing it.
"""
from alembic import op
import sqlalchemy as sa

revision = "e93ab6824d10"
down_revision = ("b82a03563197", "c4d905a137ab")
branch_labels = None
depends_on = None


def upgrade():
    from backend.app.media import validate_image_data_url

    connection = op.get_bind()
    saved = sa.table("saved_items", sa.column("id", sa.String()), sa.column("user_id", sa.String()),
                     sa.column("deleted", sa.Boolean()), sa.column("image_data_url", sa.String()))
    media = sa.table("saved_media", sa.column("item_id", sa.String()), sa.column("user_id", sa.String()),
                     sa.column("image_data", sa.String()))
    cursor = ""
    while True:
        rows = connection.execute(sa.select(media.c.item_id, media.c.user_id, media.c.image_data)
                                  .where(media.c.item_id > cursor).order_by(media.c.item_id).limit(100)).all()
        if not rows:
            break
        for item_id, user_id, data in rows:
            item = connection.execute(sa.select(saved.c.user_id, saved.c.deleted, saved.c.image_data_url)
                                      .where(saved.c.id == item_id)).first()
            if item and item.user_id != user_id:
                raise RuntimeError("Legacy saved image ownership mismatch; migration stopped without deleting media")
            if item and not item.deleted:
                try:
                    normalized = validate_image_data_url(data)
                except ValueError:
                    raise RuntimeError("Legacy saved image needs repair before upgrading; no media was discarded") from None
                if not item.image_data_url:
                    connection.execute(saved.update().where(saved.c.id == item_id).values(image_data_url=normalized))
                connection.execute(media.update().where(media.c.item_id == item_id).values(image_data=normalized))
        cursor = rows[-1].item_id


def downgrade():
    # Preserve normalized image pixels for a downgrade to the Chrome schema.
    op.execute("INSERT INTO saved_media (item_id, user_id, image_data) "
               "SELECT id, user_id, image_data_url FROM saved_items "
               "WHERE image_data_url IS NOT NULL AND deleted = false "
               "AND id NOT IN (SELECT item_id FROM saved_media)")

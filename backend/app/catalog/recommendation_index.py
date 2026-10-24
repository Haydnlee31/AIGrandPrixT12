"""Category-only SQLite candidates so accessories do not consume the window."""
from sqlalchemy import column, select, table, text


def ensure_recommendation_index(connection):
    if connection.dialect.name != "sqlite":
        return
    present = connection.scalar(text("SELECT 1 FROM sqlite_master WHERE name='recommendation_categories'"))
    connection.exec_driver_sql("CREATE VIRTUAL TABLE IF NOT EXISTS recommendation_categories USING fts5(product_id UNINDEXED, category)")
    connection.exec_driver_sql("""CREATE TRIGGER IF NOT EXISTS recommendation_category_insert AFTER INSERT ON catalog_products BEGIN
        INSERT INTO recommendation_categories(rowid,product_id,category) VALUES(new.rowid,new.id,coalesce(json_extract(new.record,'$.category'),'')); END""")
    connection.exec_driver_sql("""CREATE TRIGGER IF NOT EXISTS recommendation_category_delete AFTER DELETE ON catalog_products BEGIN
        DELETE FROM recommendation_categories WHERE rowid=old.rowid; END""")
    connection.exec_driver_sql("""CREATE TRIGGER IF NOT EXISTS recommendation_category_update AFTER UPDATE ON catalog_products BEGIN
        DELETE FROM recommendation_categories WHERE rowid=old.rowid;
        INSERT INTO recommendation_categories(rowid,product_id,category) VALUES(new.rowid,new.id,coalesce(json_extract(new.record,'$.category'),'')); END""")
    if not present:
        connection.exec_driver_sql("INSERT INTO recommendation_categories(rowid,product_id,category) SELECT rowid,id,coalesce(json_extract(record,'$.category'),'') FROM catalog_products")


def category_product_ids(db, anchors):
    if db.get_bind().dialect.name != "sqlite" or not db.scalar(text("SELECT 1 FROM sqlite_master WHERE name='recommendation_categories'")):
        return None
    expressions = []
    for anchor in anchors:
        quoted = '"' + anchor.replace('"', '""') + '"*'
        if anchor in {"watch", "phone"}:
            quoted += ' NOT ("case"* OR "strap"* OR "band"* OR "box"* OR "accessory"* OR "holder"* OR "stand"*)'
        expressions.append("(" + quoted + ")")
    indexed = table("recommendation_categories", column("product_id"), column("category"))
    return select(indexed.c.product_id).where(indexed.c.category.match(" OR ".join(expressions)))

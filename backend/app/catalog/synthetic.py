"""Deterministic invented products/offers for missing merchant and price scenarios.

Nothing is attached to a real dataset product, company, URL or brand. This source
is explicitly synthetic in every row and can be withdrawn independently.
"""
import random


TEMPLATES = [
    ("Lighting", "LED desk lamp", 1800, 13000, ["metal", "wood", "ceramic"], ["dimmable", "warm light", "adjustable arm"]),
    ("Furniture", "desk chair", 6000, 35000, ["mesh", "fabric", "wood"], ["height adjustable", "lumbar support", "compact footprint"]),
    ("Furniture", "writing desk", 8000, 65000, ["oak", "bamboo", "steel"], ["cable management", "drawer storage", "small spaces"]),
    ("Storage", "shelf organizer", 1500, 14000, ["wood", "steel", "bamboo"], ["modular", "stackable", "easy access"]),
    ("Electronics", "wireless headphones", 2500, 36000, ["polymer", "aluminum"], ["rechargeable", "wireless", "foldable"]),
    ("Computer accessories", "mechanical keyboard", 3500, 24000, ["polymer", "aluminum"], ["compact layout", "removable cable", "quiet switches"]),
    ("Computer accessories", "wireless mouse", 1200, 15000, ["polymer", "aluminum"], ["ergonomic grip", "wireless", "rechargeable"]),
    ("Kitchen", "insulated water bottle", 1200, 7000, ["stainless steel", "glass"], ["reusable", "leak resistant", "carry handle"]),
    ("Kitchen", "coffee mug", 800, 5000, ["ceramic", "glass", "steel"], ["easy grip", "reusable", "wide opening"]),
    ("Kitchen", "cooking pot", 2500, 18000, ["stainless steel", "cast iron"], ["with lid", "easy grip handles", "even heating"]),
    ("Bedding", "throw blanket", 1800, 16000, ["cotton", "linen", "wool"], ["soft weave", "breathable", "textured finish"]),
    ("Decor", "cushion cover", 1000, 6500, ["cotton", "linen", "velvet"], ["removable cover", "textured finish", "zip closure"]),
    ("Bags", "daily backpack", 2200, 22000, ["canvas", "nylon"], ["laptop sleeve", "padded straps", "multiple pockets"]),
    ("Travel", "packing cube set", 1000, 6000, ["nylon", "polyester"], ["zip closure", "lightweight", "nested storage"]),
    ("Outdoor", "camping lantern", 2200, 12000, ["polymer", "aluminum"], ["carry handle", "rechargeable", "adjustable light"]),
    ("Fitness", "exercise mat", 1400, 12000, ["rubber", "cork"], ["non-slip texture", "roll storage", "easy clean"]),
    ("Stationery", "hardcover notebook", 500, 4500, ["paper", "recycled paper"], ["lay-flat binding", "bookmark ribbon", "numbered pages"]),
    ("Garden", "indoor planter", 900, 12000, ["ceramic", "terracotta", "polymer"], ["drainage tray", "indoor use", "wide opening"]),
    ("Bathroom", "towel set", 1800, 13000, ["cotton", "bamboo fiber"], ["soft weave", "hanging loop", "absorbent"]),
    ("Organization", "cable organizer", 400, 4000, ["silicone", "wood", "polymer"], ["reusable", "compact", "desk organization"]),
]
COLORS = ["sand", "charcoal", "sage", "navy", "cream", "terracotta", "forest", "white"]
STYLES = ["Arc", "Grove", "Harbor", "Aster", "Lumen", "Cove", "Willow", "Orbit"]


def iter_synthetic(count=20000, seed=31):
    if type(count) is not int or not 1 <= count <= 100000:
        raise ValueError("Generate between one and 100000 synthetic records")
    if type(seed) is not int or not 0 <= seed < 2**32:
        raise ValueError("Use a nonnegative 32-bit seed")
    rng = random.Random(seed)
    for index in range(count):
        family, variant = divmod(index, 4)
        category, noun, low, high, materials, features = TEMPLATES[family % len(TEMPLATES)]
        material = materials[family % len(materials)]
        color = COLORS[(family + variant) % len(COLORS)]
        style = STYLES[family % len(STYLES)]
        currency = ("SGD", "USD", "EUR")[family % 3]
        merchant_number = (family * 7 + variant) % 24 + 1
        record_id = f"generated-{index:06d}"
        yield {
            "source_id": "synthetic", "source_record_id": record_id, "data_kind": "synthetic",
            "title": f"{style} {color} {noun} {family:05d}",
            "description": f"{color.capitalize()} {noun} in {material}. {', '.join(features).capitalize()}. Collection {family:05d}, variant {variant + 1}.",
            "category": category, "brand": f"Mymah Studio {family % 12 + 1:02d}",
            "attributes": {"material": material, "color": color, "features": features,
                           "generated": True, "variant_number": variant + 1,
                           "width_cm": rng.randint(6, 25) if category == "Lighting" else None},
            "product_key": f"synthetic-family-{family:05d}", "variant_key": record_id,
            "merchant": {"id": f"fictional-merchant-{merchant_number:02d}",
                         "name": f"Mymah Fictional Merchant {merchant_number:02d}", "platform": "synthetic"},
            "offer": {"id": record_id, "price_minor": rng.randrange(low, high, 50), "currency": currency,
                      "shipping_minor": rng.choice([0, 300, 500, None]),
                      "availability": rng.choice(["in_stock", "in_stock", "out_of_stock", "unknown"]),
                      "condition": "new", "url": None, "image_url": None, "observed_at": None,
                      "expires_at": None, "marketplace_id": None, "environment": "local"},
            "provenance": {"generator": "mymah-catalog-v1", "seed": seed, "is_synthetic": True,
                           "is_current_offer": False, "merchant_is_fictional": True},
        }

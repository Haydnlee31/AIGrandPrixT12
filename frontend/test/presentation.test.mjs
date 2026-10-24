import test from "node:test";
import assert from "node:assert/strict";
import {
  priceText,
  currentOffer,
  offerLink,
  sourceLink,
  exploreKey,
  validateImage,
} from "../presentation.mjs";
const idea = () => ({
  action: "view_offer",
  action_url: "https://shop.example.com/product",
  product: {
    source_id: "merchant",
    source_record_id: "123",
    data_kind: "merchant_feed",
    offer: {
      environment: "production",
      price_minor: 1234,
      currency: "SGD",
      observed_at: 100,
      expires_at: 200,
      url: "https://shop.example.com/product",
    },
  },
  catalog_citation: { record_url: "https://catalog.example.com/123" },
});
test("prices respect currency exponents and distinguish zero from missing data", () => {
  assert.equal(priceText(1234, "USD", "en-US"), "$12.34");
  assert.equal(priceText(1234, "JPY", "en-US"), "¥1,234");
  assert.equal(priceText(1234, "KWD", "en-US"), "KWD\u00a01.234");
  assert.equal(priceText(0, "USD", "en-US"), "$0.00");
  for (const v of [null, undefined, -1, NaN, 1.2])
    assert.equal(priceText(v, "USD"), "Price unavailable");
  assert.equal(priceText(1234, "XXX"), "XXX 1234 minor units");
});
test("only fresh merchant observations with matching HTTPS offer URLs are presented as offers", () => {
  const item = idea();
  assert.equal(currentOffer(item, 150), true);
  assert.equal(offerLink(item, 150), item.action_url);
  assert.equal(currentOffer(item, 200), false);
  assert.equal(currentOffer(item, 99), false);
  for (const patch of [
    { expires_at: null },
    { observed_at: null },
    { currency: "XXX" },
    { price_minor: null },
    { environment: "local" },
  ]) {
    const changed = idea();
    Object.assign(changed.product.offer, patch);
    assert.equal(currentOffer(changed, 150), false);
  }
  item.product.data_kind = "open_dataset";
  assert.equal(offerLink(item, 150), null);
  item.product.data_kind = "merchant_feed";
  item.action_url = "https://other.example.com/product";
  assert.equal(offerLink(item, 150), null);
  assert.equal(sourceLink(item), "https://catalog.example.com/123");
  item.catalog_citation.record_url = "javascript:alert(1)";
  item.action_url = "data:text/html,bad";
  assert.equal(sourceLink(item), null);
});
test("catalog identities cannot collide across sources", () => {
  const a = idea(),
    b = idea();
  b.product.source_id = "other";
  assert.notEqual(exploreKey(a), exploreKey(b));
});
test("photo upload rejects unsupported or oversized data before creating a save", () => {
  validateImage({ type: "image/png", size: 4 * 1024 * 1024 });
  for (const file of [
    { type: "image/heic", size: 5 },
    { type: "image/svg+xml", size: 5 },
    { type: "image/jpeg", size: 4 * 1024 * 1024 + 1 },
    { type: "image/png", size: 0 },
  ])
    assert.throws(() => validateImage(file));
});

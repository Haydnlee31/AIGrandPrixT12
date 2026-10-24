import { safeLink } from "./library.js";
const TWO_DECIMAL = new Set(
  "USD SGD EUR GBP AUD CAD NZD HKD CNY MYR THB PHP IDR INR CHF SEK NOK DKK PLN CZK AED SAR ZAR BRL MXN TWD".split(
    " ",
  ),
);
export function currencyExponent(currency) {
  if (["JPY", "KRW"].includes(currency)) return 0;
  if (["KWD", "BHD", "OMR"].includes(currency)) return 3;
  return TWO_DECIMAL.has(currency) ? 2 : null;
}
export function priceText(minor, currency, locale) {
  if (!Number.isSafeInteger(minor) || minor < 0 || !currency)
    return "Price unavailable";
  const exponent = currencyExponent(currency);
  if (exponent === null) return `${currency} ${minor} minor units`;
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency,
    minimumFractionDigits: exponent,
    maximumFractionDigits: exponent,
  }).format(minor / 10 ** exponent);
}
export function currentOffer(item, now = Date.now() / 1000) {
  const product = item.product,
    offer = product.offer;
  return (
    product.data_kind === "merchant_feed" &&
    offer.environment === "production" &&
    Number.isSafeInteger(offer.price_minor) &&
    offer.price_minor >= 0 &&
    currencyExponent(offer.currency) !== null &&
    Number.isFinite(offer.observed_at) &&
    offer.observed_at <= now &&
    Number.isFinite(offer.expires_at) &&
    offer.expires_at > now &&
    offer.expires_at > offer.observed_at
  );
}
export function offerLink(item, now) {
  const href = safeLink(item.action_url);
  return item.action === "view_offer" &&
    currentOffer(item, now) &&
    href?.startsWith("https:") &&
    href === safeLink(item.product.offer.url)
    ? href
    : null;
}
export function sourceLink(item) {
  return (
    safeLink(item.catalog_citation?.record_url) || safeLink(item.action_url)
  );
}
export function exploreKey(item) {
  return JSON.stringify([
    item.product.source_id,
    item.product.source_record_id,
  ]);
}
export const EXPLORE_EMPTY = {
  needs_saves: [
    "Start with a find.",
    "Save a photo or link to your shared library. Your saved details will help shape ideas here.",
  ],
  needs_analysis: [
    "A little more context.",
    "Your finds are saved. Product details need to be understood before we can connect them with ideas. You can also search above.",
  ],
  no_matches: [
    "No matching ideas yet.",
    "Try a different style, product or category. We’ll only show results the catalog can support.",
  ],
  ready: [
    "No matching ideas yet.",
    "Try a different style, product or category.",
  ],
};
export function validateImage(file) {
  if (!file?.size) throw new Error("Choose a photo to upload.");
  if (!["image/jpeg", "image/png", "image/webp"].includes(file.type))
    throw new Error("Choose a JPEG, PNG or WebP photo.");
  if (file.size > 4 * 1024 * 1024)
    throw new Error("Choose a photo smaller than 4 MB.");
}

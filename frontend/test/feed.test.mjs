import test from "node:test";
import assert from "node:assert/strict";
import { PagedFeed } from "../feed.mjs";
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => {
    resolve = a;
    reject = b;
  });
  return { promise, resolve, reject };
};
test("late search results cannot replace a newer query even if transport ignores abort", async () => {
  const feed = new PagedFeed(),
    old = deferred(),
    current = deferred();
  let oldSignal;
  const first = feed.load(({ signal }) => {
    oldSignal = signal;
    return old.promise;
  });
  const next = feed.load(() => current.promise);
  assert.equal(oldSignal.aborted, true);
  current.resolve({ items: [{ id: "new" }], next_offset: null });
  await next;
  old.resolve({ items: [{ id: "old" }], next_offset: 20 });
  await first;
  assert.deepEqual(feed.items, [{ id: "new" }]);
  assert.equal(feed.page.next_offset, null);
  assert.equal(feed.loading, false);
});
test("changing accounts clears private results and discards in-flight responses", async () => {
  const request = deferred(),
    feed = new PagedFeed();
  const load = feed.load(() => request.promise);
  feed.clear();
  request.resolve({ items: [{ id: "private" }], next_offset: null });
  await load;
  assert.deepEqual(feed.items, []);
  assert.equal(feed.page, null);
  assert.equal(feed.error, null);
});
test("paging deduplicates shifted boundaries and preserves rows after failed pagination", async () => {
  const feed = new PagedFeed();
  await feed.load(async () => ({
    items: [{ id: "a", v: 1 }],
    next_offset: 20,
  }));
  await feed.load(
    async ({ offset }) => {
      assert.equal(offset, 20);
      return { items: [{ id: "a", v: 2 }, { id: "b" }], next_offset: 40 };
    },
    { append: true },
  );
  assert.deepEqual(feed.items, [{ id: "a", v: 2 }, { id: "b" }]);
  await feed.load(
    async () => {
      throw new Error("Offline");
    },
    { append: true },
  );
  assert.equal(feed.error.message, "Offline");
  assert.equal(feed.page.next_offset, 40);
  assert.equal(feed.items.length, 2);
  await feed.load(
    async ({ offset }) => {
      assert.equal(offset, 40);
      return { items: [{ id: "c" }], next_offset: null };
    },
    { append: true },
  );
  assert.equal(feed.items.length, 3);
  assert.equal(feed.error, null);
});
test("duplicate load-more requests are ignored while a page is loading", async () => {
  const feed = new PagedFeed();
  await feed.load(async () => ({ items: [], next_offset: 20 }));
  const request = deferred();
  const load = feed.load(() => request.promise, { append: true });
  await feed.load(
    () => {
      throw new Error("Must not request twice");
    },
    { append: true },
  );
  request.resolve({ items: [], next_offset: null });
  await load;
  assert.equal(feed.error, null);
});

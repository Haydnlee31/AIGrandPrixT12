/** Keeps paged searches isolated when a query or connected account changes. */
export class PagedFeed {
  constructor({ key = (item) => item.id, onChange = () => {} } = {}) {
    this.key = key;
    this.onChange = onChange;
    this.generation = 0;
    this.clear();
  }
  clear() {
    this.controller?.abort();
    this.generation++;
    this.items = [];
    this.page = null;
    this.error = null;
    this.loading = false;
  }
  async load(request, { append = false } = {}) {
    if (append && (this.loading || this.page?.next_offset == null)) return;
    this.controller?.abort();
    const generation = ++this.generation,
      controller = new AbortController();
    this.controller = controller;
    const offset = append ? this.page.next_offset : 0;
    if (!append) {
      this.items = [];
      this.page = null;
    }
    this.loading = true;
    this.error = null;
    this.onChange();
    try {
      const page = await request({ offset, signal: controller.signal });
      if (generation !== this.generation) return;
      this.items = [
        ...new Map(
          [...this.items, ...page.items].map((item) => [this.key(item), item]),
        ).values(),
      ];
      this.page = page;
    } catch (error) {
      if (generation !== this.generation) return;
      if (error.name !== "AbortError") this.error = error;
    } finally {
      if (generation === this.generation) {
        this.loading = false;
        this.onChange();
      }
    }
  }
}

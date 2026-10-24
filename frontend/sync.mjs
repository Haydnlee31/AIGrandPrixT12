/** Visible clients poll a small account revision, fetching data only on change. */
export class SyncCheck {
  constructor() { this.reset(); }
  reset() { this.generation = (this.generation || 0) + 1; this.revision = null; this.running = false; this.retryAt = 0; this.failures = 0; }
  async check({scope, state, refresh, now = Date.now()}) {
    if (this.running || now < this.retryAt) return;
    const generation = this.generation;
    this.running = true;
    try {
      const remote = await state();
      if (generation !== this.generation) return;
      if (remote.user_id !== scope) throw new Error('The connected account changed. Sign in again.');
      if (remote.revision !== this.revision) {
        await refresh();
        if (generation !== this.generation) return;
        this.revision = remote.revision;
      }
      this.failures = 0;
      this.retryAt = 0;
    } catch (error) {
      if (generation !== this.generation) return;
      this.retryAt = now + Math.min(60000, 15000 * 2 ** this.failures++);
      throw error;
    } finally {
      if (generation === this.generation) this.running = false;
    }
  }
}

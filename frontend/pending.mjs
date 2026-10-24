// Submitted-but-unconfirmed captures keep their original body/key per account.
export class PendingCaptureStore {
  constructor(storage) { this.storage = storage; }
  key(accountId) { return 'mynah-pending-capture:' + encodeURIComponent(accountId); }
  get(accountId) {
    try {
      const value = JSON.parse(this.storage().getItem(this.key(accountId)));
      return value?.accountId === accountId && value.key && value.payload ? value : null;
    } catch { return null; }
  }
  put(attempt) {
    try { this.storage().setItem(this.key(attempt.accountId), JSON.stringify(attempt)); }
    catch { throw new Error('Your browser could not keep a retry copy. Free some browser storage before saving this find.'); }
  }
  remove(attempt) {
    if (attempt && this.get(attempt.accountId)?.key === attempt.key) this.storage().removeItem(this.key(attempt.accountId));
  }
}

// One in-flight credential refresh per account, shared by parallel API requests.
// The token stays in memory; every new batch checks the managed session again.
export function sessionToken({subject, session, issueToken, isCurrent, onExpired}) {
  let flight = null;
  return async () => {
    if (!isCurrent()) throw new Error('Your account changed. Please try again.');
    if (flight) return flight;
    const pending = (async () => {
      const current = await session();
      if (current?.user?.id !== subject) {
        await onExpired();
        throw new Error('Please sign in again.');
      }
      const data = await issueToken();
      if (!isCurrent() || !data?.token) throw new Error('Please sign in again.');
      let tokenSubject;
      try { tokenSubject = JSON.parse(atob(data.token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).sub; } catch {}
      if (tokenSubject !== subject) throw new Error('Your account changed. Please try again.');
      return data.token;
    })();
    flight = pending;
    try { return await pending; } finally { if (flight === pending) flight = null; }
  };
}

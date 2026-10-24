import { applyAnswer } from './questions.js';

let connection;
function database() {
  if (!connection) connection = new Promise((resolve, reject) => {
    const request = indexedDB.open('saved-shopping', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('saves', { keyPath: 'id' });
    request.onsuccess = () => {
      request.result.onversionchange = () => { request.result.close(); connection = null; };
      resolve(request.result);
    };
    request.onerror = () => { connection = null; reject(new Error('Local storage could not open. Please reopen the extension.')); };
  });
  return connection;
}

async function transaction(mode, work) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const tx = db.transaction('saves', mode);
    let result;
    let failure;
    tx.oncomplete = () => resolve(result);
    tx.onabort = () => reject(failure || new Error('Could not save locally. Your previous saves are safe; free some space and try again.'));
    tx.onerror = () => {};
    try { work(tx.objectStore('saves'), value => { result = value; }, error => { failure = error; tx.abort(); }); }
    catch (error) { failure = error; tx.abort(); }
  });
}

export const listSaves = () => transaction('readonly', (store, done) => {
  const request = store.getAll();
  request.onsuccess = () => done(request.result.sort((a, b) => b.createdAt.localeCompare(a.createdAt)));
});

export const addSave = item => transaction('readwrite', (store, done) => { store.add(item); done(item); });
export const deleteSave = id => transaction('readwrite', store => { store.delete(id); });
export const getSave = id => transaction('readonly', (store, done) => {
  const request = store.get(id);
  request.onsuccess = () => done(request.result);
});
export const updateSave = (id, change) => transaction('readwrite', (store, done, fail) => {
  const request = store.get(id);
  request.onsuccess = () => {
    if (!request.result) return fail(new Error('This save was removed.'));
    try { const updated = change(request.result); store.put(updated); done(updated); }
    catch (error) { fail(error); }
  };
});

export const saveAnswer = (id, answer) => transaction('readwrite', (store, done, fail) => {
  const request = store.get(id);
  request.onsuccess = () => {
    if (!request.result) return fail(new Error('This save was removed. Please choose another.'));
    try {
      const updated = applyAnswer(request.result, answer);
      store.put(updated);
      done(updated);
    } catch (error) { fail(error); }
  };
});

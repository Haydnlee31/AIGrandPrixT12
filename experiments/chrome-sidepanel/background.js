import { captureSelectedImage } from './image-capture.js';
import { addSave } from './storage.js';
import { getConnection, sync } from './connection.js';

// The action click grants activeTab before opening the panel.
chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: false }).catch(console.error);
chrome.action.onClicked.addListener(tab => {
  chrome.sidePanel.open({ windowId: tab.windowId }).catch(console.error);
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: 'save-image', title: 'Save image to Mymah Finds', contexts: ['image'], documentUrlPatterns: ['http://*/*', 'https://*/*'] });
  });
});

let capturing = false;
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== 'save-image' || capturing || !tab?.id) return;
  capturing = true;
  // Open synchronously from the user gesture; waiting first loses Chrome's gesture token.
  const opening = chrome.sidePanel.open({ windowId: tab.windowId }).catch(() => {});
  const status = value => chrome.storage.session.set({ imageCapture: { ...value, revision: crypto.randomUUID() } });
  (async () => {
    await status({ state: 'saving' });
    await opening;
    const item = await captureSelectedImage(info, tab);
    const connection = await getConnection({allowCached: true}).catch(() => null);
    if (connection) item.queuedScope = JSON.stringify([connection.baseURL, connection.userId]);
    await addSave(item);
    await status({ state: 'saved', id: item.id });
    if (await getConnection()) {
      try { await sync(item.id); await status({state: 'saved', id: item.id}); }
      catch (error) { await status({state: 'saved', id: item.id, error: `Image saved locally. ${error.message}`}); }
    }
  })().catch(error => status({ state: 'failed', error: error.message || 'Could not save that image. Try again.' }))
    .catch(console.error).finally(() => { capturing = false; });
});

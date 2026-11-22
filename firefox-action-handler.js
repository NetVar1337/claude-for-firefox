// Firefox action handler — intercepts action.onClicked to toggle the
// Firefox sidebar instead of opening a Chrome sidePanel.

(function () {
  'use strict';

  // Stub chrome.sidePanel so calls from the Chrome bundle don't throw
  if (typeof chrome !== 'undefined' && !chrome.sidePanel) {
    chrome.sidePanel = {
      open: function () { return Promise.resolve(); },
      close: function () { return Promise.resolve(); },
      setOptions: function () { return Promise.resolve(); },
      setPanelBehavior: function () { return Promise.resolve(); },
      getOptions: function () { return Promise.resolve({}); },
      getPanelBehavior: function () { return Promise.resolve({}); },
    };
  }

  if (typeof chrome === 'undefined' || !chrome.action || !chrome.action.onClicked) {
    return;
  }

  var sidebarApi = chrome.sidebarAction || (typeof browser !== 'undefined' && browser.sidebarAction);
  if (!sidebarApi) {
    console.warn('[firefox-action-handler] sidebarAction API not available');
    return;
  }

  chrome.action.onClicked.addListener(function (tab) {
    var tabId = tab && tab.id;

    // Set the sidebar panel URL with the tabId parameter so the panel
    // knows which tab context it belongs to.
    if (sidebarApi.setPanel) {
      var panelUrl = chrome.runtime.getURL('sidepanel.html');
      if (tabId) {
        panelUrl += '?tabId=' + encodeURIComponent(tabId);
      }
      sidebarApi.setPanel({ panel: panelUrl });
    }

    // Toggle sidebar visibility
    if (sidebarApi.toggle) {
      sidebarApi.toggle();
    } else if (sidebarApi.open) {
      sidebarApi.open();
    }
  });
})();

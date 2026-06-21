'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('walletAPI', {
  getBalances: (payload) => ipcRenderer.invoke('balances:get', payload),
  getPrices: (payload) => ipcRenderer.invoke('prices:get', payload),
  getMeta: (payload) => ipcRenderer.invoke('tokens:meta', payload),
  openExternal: (url) => ipcRenderer.invoke('open:external', url),
});

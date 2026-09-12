// Writers and readers share these limits so idle polling cannot look like a
// disconnected VPN. Allow scheduling jitter and several missed status ticks.
export const VPN_REQUEST_INTERVAL_MS: number = 1000;
export const VPN_STATUS_INTERVAL_MS: number = 5000;
export const VPN_HEARTBEAT_FRESH_MS: number = 15000;
// Cold UI launches must observe a new heartbeat, not trust a persisted one.
export const VPN_HEARTBEAT_CONFIRM_TIMEOUT_MS: number = VPN_STATUS_INTERVAL_MS * 2 + 1000;
export const VPN_SNAPSHOT_FRESH_MS: number = 20000;

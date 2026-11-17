// DripPay configuration.
// Fill in the deployed addresses after running ./script/deploy.sh.
// Until then the app shows the "not deployed yet" state honestly.
export const CONFIG = {
  // Base Sepolia — where the DripVault lives (destination chain).
  vaultChainId: 84532,
  vaultChainName: "Base Sepolia",
  vaultRpc: "https://sepolia.base.org",
  vaultAddress: "", // TBD after deploy, e.g. "0x..."
  vaultExplorer: "https://sepolia.basescan.org",
  // Reactive Lasna — where the DripReactive contract lives.
  reactiveChainId: 5318007,
  reactiveChainName: "Reactive Lasna",
  reactiveRpc: "https://lasna-rpc.rnk.dev/",
  reactiveAddress: "", // TBD after deploy, e.g. "0x..."
  reactiveExplorer: "https://lasna.reactscan.net",
  // Callback proxy on Base Sepolia (from dev.reactive.network).
  baseSepoliaProxy: "0x476F44b11F5C942c58f4c8E3d0300E5710743585",
  // Gas reserve the vault requires per schedule (see DripVault.GAS_RESERVE).
  gasReserveEth: "0.002",
};

export const DEPLOYED = Boolean(CONFIG.vaultAddress && CONFIG.reactiveAddress);

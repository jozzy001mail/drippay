# DripPay — recurring payments that run themselves

**Reactive Omni Buildathon entry — "Set It and Forget It" track**
($2,000 first place, $250 runner-up; closes 5 Dec 2026, submissions via DoraHacks)

Set a recurring payment once — a recipient, an amount, an interval — and a
reactive contract on Reactive Lasna releases every payment automatically. No
bot, no keeper, no server. The automation lives entirely on-chain.

## How it works

```
User creates schedule + escrow
        │  (Base Sepolia)
        ▼
DripVault ──ScheduleCreated──▶ DripReactive (Lasna)
   ▲                              │ subscribes to vault events
   │                              │ + CRON100 tick (~every 2 min)
   │                              ▼
   └──── release() ◀── callback ──┘
        pays the recipient, advances nextDue
```

1. **DripVault** (`src/DripVault.sol`, destination chain) holds escrowed funds.
   `createSchedule()` locks `amount × payments + 0.002 ETH` (callback reserve)
   and emits `ScheduleCreated`. `release()` pays one installment — callable
   ONLY by the Reactive callback proxy on behalf of the authorised reactive
   contract (`onlyServiceProvider` + `onlyCallbackSender`).
2. **DripReactive** (`src/DripReactive.sol`, Reactive Lasna) mirrors schedules
   from the vault's `ScheduleCreated` / `ScheduleCancelled` /
   `PaymentReleased` events, then on every CRON100 tick checks which schedules
   are due and requests a callback to `release()` them. A pending guard with a
   10-minute timeout prevents duplicate requests and retries failed ones.
   Pause/resume, vault re-pointing, and debt settlement are owner-only.

## Status (honest)

| Piece | State |
|---|---|
| Contracts (`forge test`) | **20/20 pass**, incl. a full mocked end-to-end loop (event → react → callback → release → mirror update) |
| Front end | **Live**: https://app-omega-eight-12.vercel.app (contracts live since 17 Nov 2026) |
| Live contracts | **Not yet deployed** — waiting on free testnet funds (see below) |
| Demo video | **Not yet recorded** — needs the live loop first |
| DoraHacks submission | **Not yet submitted** — form needs a signed-in session (see `SUBMISSION.md`) |

## What you need to deploy (free testnet funds, $0 real money)

The deployer is a throwaway testnet-only key in `.deployer.json`
(git-ignored). Its address: `0x9b07C2625BC0027Dc636ED77F9A05e3Fb7F26436`
(balance 0 everywhere right now).

1. **Sepolia ETH** — Google Cloud Web3 faucet
   (https://cloud.google.com/application/web3/faucet/ethereum/sepolia,
   sign in with Google, 0.05 ETH/day) to the deployer address.
2. **lREACT on Lasna** — send 0.02 Sepolia ETH to the Reactive faucet
   `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` (1 ETH = 100 lREACT → 2 lREACT).
   Or `cast send` the same from the CLI.
3. **Base Sepolia ETH** — bridge ~0.02 Sepolia ETH at https://bridge.base.org,
   or the Alchemy Base Sepolia faucet.
4. Run `./script/deploy.sh` (needs `DEPLOYER_KEY` in `.env` — copy from
   `.deployer.json`). It predicts the vault address, deploys the reactive
   contract on Lasna, deploys the vault on Base Sepolia, verifies the wiring,
   and prints the addresses.
5. Put the addresses in `app/src/config.js`, redeploy the front end
   (`cd app && vercel deploy --prod --yes`), record the demo, fill in
   `SUBMISSION.md`, submit on DoraHacks.

Fallback topology (Lasna-only, needs only lREACT): run
`DEST_CHAIN_ID=5318007 DEST_RPC=https://lasna-rpc.rnk.dev/ DEST_PROXY=0x8888888888888888888888888888888888888888 ./script/deploy.sh`.
The same contracts run single-chain on Lasna — the vault lives on Lasna and
callbacks target Lasna itself.

## Run the tests

```bash
forge test          # 20 tests, incl. end-to-end loop with mocked system contract
forge build
```

## Project layout

```
src/
  DripVault.sol      # destination-chain escrow + callback receiver
  DripReactive.sol   # Lasna reactive contract (mirror + CRON + callbacks)
script/
  DeployReactive.s.sol  DeployVault.s.sol  deploy.sh
test/
  DripPay.t.sol      # 20 tests
  Mocks.sol          # MockSystem (etched at 0x8888…) + MockProxy
app/                 # Vite + React + ethers v6 front end (Vercel)
```

## Key addresses (docs-verified)

- Reactive system contract (mainnet + Lasna): `0x8888888888888888888888888888888888888888`
- Base Sepolia callback proxy: `0x476F44b11F5C942c58f4c8E3d0300E5710743585`
- Unichain Sepolia callback proxy: `0x775c9B990ADe401060B78D0e98684eEf8d2466C1`
- Lasna RPC: `https://lasna-rpc.rnk.dev/` (chain 5318007) · Base Sepolia RPC: `https://sepolia.base.org` (chain 84532)
- Reactive docs: https://dev.reactive.network · Buildathon: https://dorahacks.io/hackathon/reactive-omni-buildathon

## Built by

Joshua Owoade (jozzy-001 / @owoade on DoraHacks), Nigeria. Built during the
buildathon (5 Nov – 5 Dec 2026). Prior work (CashLink, KudiWallet, JozzyPay)
was not reused as the submission — DripPay is a new build; only the general
payment-link experience informed the design.

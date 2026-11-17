# DripPay — DoraHacks submission pack (Reactive Omni Buildathon)

Everything below is ready to paste into the DoraHacks submission form for
https://dorahacks.io/hackathon/reactive-omni-buildathon. The project is built
and tested; the live deploy + demo video are the only steps left (both need
free testnet funds first — see README.md). The form needs a signed-in browser
session as @owoade.

## Form fields

- **Project name:** DripPay
- **Tagline:** Recurring payments that run themselves — set it and forget it
- **Track:** Set It and Forget It
- **Team:** Owoade (solo) — DoraHacks @owoade, GitHub jozzy001mail
- **Live demo:** https://app-omega-eight-12.vercel.app
- **GitHub repo (public):** https://github.com/jozzy001mail/drippay
- **Demo video:** TBD — record after the live deploy (script in DEMO.md)
- **Deployed contracts (live 2026-11-17, verified on-chain):**
  - DripVault (Base Sepolia 84532): 0x0aF42A25922A05Db33064c60cB74e41F8EE34C6a (funded 0.015 ETH)
  - DripReactive (Lasna 5318007): 0x0aF42A25922A05Db33064c60cB74e41F8EE34C6a (funded 0.05 lREACT)
- **Loop transactions (origin event → reactive tx → callback):** TBD after deploy

## Short description (paste-ready)

DripPay is "set it and forget it" recurring payments, powered by Reactive
Network. A user creates a payment schedule once — recipient, amount, interval
— and escrows the funds in a vault on Base Sepolia. A reactive contract on
Reactive Lasna mirrors the schedule from the vault's ScheduleCreated event,
then on every network CRON tick (about every 2 minutes) it releases each due
payment by callback to the vault. No bot, no keeper, no server: the schedule
runs itself until the payments run out or the owner cancels (escrow refunded).
Useful for payroll, allowances, subscriptions — anything you pay on a schedule
and never want to think about again.

## What was built during the buildathon (17 Nov – 5 Dec 2026)

- **DripVault.sol** — destination-chain escrow + callback receiver. Only the
  Reactive callback proxy, on behalf of the authorised reactive contract, can
  release a payment (`onlyServiceProvider` + `onlyCallbackSender`). Owners can
  top up or cancel (refund).
- **DripReactive.sol** — Lasna reactive contract. Subscribes to the vault's
  `ScheduleCreated` / `ScheduleCancelled` / `PaymentReleased` events on Base
  Sepolia plus the network CRON100 tick; mirrors schedules on-chain; requests
  `release()` callbacks for due schedules. Pending guard + 10-minute timeout
  prevents duplicate requests and retries failed ones. Owner can pause/resume
  and re-point the vault.
- **Tests: `forge test` — 20/20 pass**, including a full mocked end-to-end
  loop (origin event → react → callback request → release → mirror update)
  and negative tests (wrong caller, wrong sender, early release, short deposit).
- **Front end** — Vite + React + ethers v6, live on Vercel (free tier):
  create a schedule, watch schedules/payments, watch the reactive mirror on
  Lasna. Shows an honest "not deployed yet" state until contracts land.
- **Deploy scripts** — `script/deploy.sh` orchestrates the two-chain deploy
  (predicts the vault address, deploys reactive on Lasna, deploys the vault on
  Base Sepolia, verifies wiring). A Lasna-only fallback topology is documented.

## Requirements checklist

- [x] Built during the event (started 17 Nov 2026)
- [x] Public repo, open source
- [x] Reactive contract does real work (mirrors + drives releases)
- [x] Live, usable demo (front end live with deployed contract addresses)
- [x] Deployed contract addresses (vault + reactive verified on-chain, wiring checked both ways)
- [ ] Loop transaction hashes (need a real schedule created + a CRON tick + callback — next step)
- [ ] Demo video under 3 minutes (script in DEMO.md; record after the live loop runs)

## Deadline

Submissions close **5 Dec 2026** (DoraHacks page; HackathonRadar lists
6 Dec 12:00 UTC). Judged by the Reactive team on Execution, Integration,
Usefulness, Craft (1–5 each, equally weighted). Entries without on-chain
reactive transactions and callbacks are not scored further — the live deploy
is the critical remaining step.

## Prizes (this track)

Set It and Forget It: **$2,000 first place, $250 runner-up**, paid in REACT.

# DripPay — demo video script (under 3 minutes)

Record AFTER the live deploy, when the loop has run at least once on-chain.
Screen-record the live front end + the two explorers. Keep it under 3:00.

## 0:00–0:20 — The problem

> "Every recurring payment today needs someone — or something — to remember
> it. Payroll, allowances, subscriptions: a bot, a cron job, a person who
> forgets. DripPay removes the rememberer. You set a payment schedule once,
> and a reactive contract on Reactive Network pays it out on time, forever,
> with no server running anywhere."

Show: the live front end (app-49qc38t8w-owoade1.vercel.app).

## 0:20–1:20 — The loop, live

1. **Create a schedule (20s).** Connect wallet (Base Sepolia), fill in
   recipient / 0.001 ETH / 300 seconds / 4 payments, submit. "The vault locks
   the escrow and emits ScheduleCreated."
2. **The mirror (20s).** Switch to the Lasna section: the schedule appears in
   the reactive mirror. "The reactive contract saw the event on Base Sepolia
   and recorded it — no one told it to."
3. **The tick (20s).** Wait for the next CRON tick (~2 min) — or show the
   already-released payment. "Every two minutes the network itself ticks. The
   reactive contract checks what's due and asks for a callback."
4. **The payment (20s).** Show the PaymentReleased row + the Base Sepolia
   explorer transaction. "The callback landed, the recipient was paid, the
   next due date advanced. Nobody clicked anything."

## 1:20–2:00 — Why it's real

> "This is not a mockup. The vault only pays when the Reactive callback proxy
> calls it on behalf of the exact reactive contract — anyone else gets
> reverted. The tests prove it: 20 out of 20 pass, including the full loop
> and the negative cases. The contracts are verified on Sourcify."

Show (optional): the repo, the test output, the Sourcify verification.

## 2:00–2:30 — What's next

> "Next: the same contracts on mainnet, and schedules in stablecoins once
> there's a price feed. DripPay — set it and forget it."

End card: repo URL + "Built by Joshua Owoade (jozzy-001), Nigeria."

## If the judges test it themselves

- The front end works with any Base Sepolia wallet (test ETH from any faucet).
- Minimum interval is 60 seconds; the demo uses 300 so a payment lands
  within a few minutes of creating a schedule.
- Contract addresses + loop transaction hashes: see SUBMISSION.md.

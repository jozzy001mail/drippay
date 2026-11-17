import { useEffect, useState, useCallback } from "react";
import { BrowserProvider, Contract, JsonRpcProvider, formatEther, parseEther } from "ethers";
import { CONFIG, DEPLOYED } from "./config";
import vaultAbi from "./abi/DripVault.json";
import reactiveAbi from "./abi/DripReactive.json";

const fmtTime = (ts) => (ts ? new Date(Number(ts) * 1000).toLocaleString() : "—");
const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");

export default function App() {
  const [account, setAccount] = useState("");
  const [provider, setProvider] = useState(null);
  const [schedules, setSchedules] = useState([]);
  const [payments, setPayments] = useState([]);
  const [mirror, setMirror] = useState([]);
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState({ recipient: "", amount: "0.001", interval: "300", payments: "4" });

  const readProvider = new JsonRpcProvider(CONFIG.vaultRpc);
  const lasnaProvider = new JsonRpcProvider(CONFIG.reactiveRpc);

  const loadData = useCallback(async () => {
    if (!DEPLOYED) return;
    try {
      const vault = new Contract(CONFIG.vaultAddress, vaultAbi, readProvider);
      const created = await vault.queryFilter(vault.filters.ScheduleCreated, -200000);
      const rows = [];
      for (const ev of created) {
        const s = await vault.getSchedule(ev.args.scheduleId);
        rows.push({
          id: Number(ev.args.scheduleId),
          owner: s.owner,
          recipient: s.recipient,
          amount: formatEther(s.amount),
          interval: Number(s.intervalSeconds),
          left: Number(s.paymentsLeft),
          nextDue: Number(s.nextDue),
          escrow: formatEther(s.escrow),
          active: s.active,
        });
      }
      setSchedules(rows.reverse());
      const released = await vault.queryFilter(vault.filters.PaymentReleased, -200000);
      setPayments(
        released
          .map((ev) => ({
            id: Number(ev.args.scheduleId),
            recipient: ev.args.recipient,
            amount: formatEther(ev.args.amount),
            left: Number(ev.args.paymentsLeft),
            nextDue: Number(ev.args.nextDue),
            tx: ev.transactionHash,
          }))
          .reverse()
      );
      const reactive = new Contract(CONFIG.reactiveAddress, reactiveAbi, lasnaProvider);
      const ids = await reactive.getActiveIds();
      const mirrors = [];
      for (const id of ids) {
        const m = await reactive.getMirror(id);
        mirrors.push({
          id: Number(id),
          recipient: m.recipient,
          amount: formatEther(m.amount),
          left: Number(m.paymentsLeft),
          nextDue: Number(m.nextDue),
          active: m.active,
        });
      }
      setMirror(mirrors);
    } catch (e) {
      setStatus("Could not load on-chain data: " + (e?.reason || e?.message || e));
    }
  }, []);

  useEffect(() => {
    loadData();
    const t = setInterval(loadData, 30000);
    return () => clearInterval(t);
  }, [loadData]);

  async function connect() {
    if (!window.ethereum) return setStatus("No wallet found — install MetaMask.");
    const p = new BrowserProvider(window.ethereum);
    const [acc] = await p.send("eth_requestAccounts", []);
    const net = await p.getNetwork();
    if (Number(net.chainId) !== CONFIG.vaultChainId) {
      try {
        await window.ethereum.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: "0x14a34" }],
        });
      } catch {
        return setStatus("Please switch your wallet to Base Sepolia (chain 84532).");
      }
    }
    setProvider(p);
    setAccount(acc);
    setStatus("");
  }

  async function createSchedule(e) {
    e.preventDefault();
    if (!provider || !DEPLOYED) return;
    setBusy(true);
    try {
      const signer = await provider.getSigner();
      const vault = new Contract(CONFIG.vaultAddress, vaultAbi, signer);
      const amount = parseEther(form.amount);
      const payments = BigInt(form.payments);
      const value = amount * payments + parseEther(CONFIG.gasReserveEth);
      const tx = await vault.createSchedule(form.recipient, amount, BigInt(form.interval), payments, { value });
      setStatus("Creating schedule… tx " + tx.hash);
      await tx.wait();
      setStatus("Schedule created. The reactive contract will pick it up from the event and pay it out on schedule — no bot needed.");
      loadData();
    } catch (err) {
      setStatus("Failed: " + (err?.reason || err?.message || err));
    } finally {
      setBusy(false);
    }
  }

  async function cancelSchedule(id) {
    if (!provider || !DEPLOYED) return;
    setBusy(true);
    try {
      const signer = await provider.getSigner();
      const vault = new Contract(CONFIG.vaultAddress, vaultAbi, signer);
      const tx = await vault.cancelSchedule(id);
      setStatus("Cancelling… tx " + tx.hash);
      await tx.wait();
      setStatus("Schedule cancelled — remaining escrow refunded.");
      loadData();
    } catch (err) {
      setStatus("Failed: " + (err?.reason || err?.message || err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ maxWidth: 860, margin: "0 auto", padding: 24, fontFamily: "system-ui, sans-serif", lineHeight: 1.5 }}>
      <h1>DripPay 💧</h1>
      <p>
        <strong>Set it and forget it.</strong> Schedule a recurring payment once; a reactive
        contract on Reactive Lasna watches the vault on Base Sepolia and releases each
        payment automatically — no bot, no keeper, no server.
      </p>
      <p>
        How it works: you create a schedule + escrow on the vault → the reactive contract
        mirrors it from the <code>ScheduleCreated</code> event → every ~2 min the network
        CRON tick fires → due payments are released by callback to the vault. Built for the{" "}
        <a href="https://dorahacks.io/hackathon/reactive-omni-buildathon" target="_blank" rel="noreferrer">
          Reactive Omni Buildathon
        </a>{" "}
        (Set It and Forget It track).
      </p>

      {!DEPLOYED && (
        <div style={{ background: "#fff4d6", border: "1px solid #e0a800", padding: 12, borderRadius: 8 }}>
          <strong>Contracts not deployed yet.</strong> The contracts are written and tested
          (20/20 Foundry tests pass), and the deploy scripts are ready. Live deployment is
          waiting on free testnet funds — Sepolia ETH for the Lasna faucet. See the repo README
          for the exact steps. This page will light up the moment the addresses land in{" "}
          <code>src/config.js</code>.
        </div>
      )}

      <div style={{ margin: "16px 0" }}>
        {account ? (
          <span>Connected: <code>{short(account)}</code></span>
        ) : (
          <button onClick={connect} disabled={!DEPLOYED}>Connect wallet (Base Sepolia)</button>
        )}
        <button onClick={loadData} style={{ marginLeft: 8 }} disabled={!DEPLOYED}>Refresh</button>
      </div>

      {status && <p style={{ background: "#eef", padding: 10, borderRadius: 8 }}>{status}</p>}

      <h2>Create a schedule</h2>
      <form onSubmit={createSchedule} style={{ display: "grid", gap: 8, maxWidth: 480 }}>
        <label>Recipient address <input required value={form.recipient} onChange={(e) => setForm({ ...form, recipient: e.target.value })} placeholder="0x…" style={{ width: "100%" }} /></label>
        <label>Amount per payment (ETH) <input required value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} style={{ width: "100%" }} /></label>
        <label>Interval (seconds, min 60) <input required type="number" min="60" value={form.interval} onChange={(e) => setForm({ ...form, interval: e.target.value })} style={{ width: "100%" }} /></label>
        <label>Number of payments <input required type="number" min="1" value={form.payments} onChange={(e) => setForm({ ...form, payments: e.target.value })} style={{ width: "100%" }} /></label>
        <p style={{ margin: 0, fontSize: 14 }}>
          Total escrow: {form.amount && form.payments ? (Number(form.amount) * Number(form.payments) + Number(CONFIG.gasReserveEth)).toFixed(4) : "—"} ETH
          (payments + {CONFIG.gasReserveEth} ETH callback reserve).
        </p>
        <button type="submit" disabled={!account || busy || !DEPLOYED}>{busy ? "Working…" : "Create schedule"}</button>
      </form>

      <h2>Schedules on the vault</h2>
      {schedules.length === 0 ? <p>No schedules yet.</p> : (
        <table cellPadding="6" style={{ borderCollapse: "collapse", width: "100%" }}>
          <thead><tr><th>#</th><th>Recipient</th><th>Amount</th><th>Every</th><th>Left</th><th>Next due</th><th>Escrow</th><th></th></tr></thead>
          <tbody>
            {schedules.map((s) => (
              <tr key={s.id} style={{ borderTop: "1px solid #ccc" }}>
                <td>{s.id}</td>
                <td><code>{short(s.recipient)}</code></td>
                <td>{s.amount} ETH</td>
                <td>{s.interval}s</td>
                <td>{s.left}</td>
                <td>{fmtTime(s.nextDue)}</td>
                <td>{s.escrow} ETH</td>
                <td>{s.active && s.owner.toLowerCase() === account.toLowerCase() ? <button onClick={() => cancelSchedule(s.id)}>Cancel</button> : s.active ? "active" : "done"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <h2>Reactive mirror (Lasna)</h2>
      {mirror.length === 0 ? <p>No schedules mirrored yet — the reactive contract mirrors each schedule from its vault event.</p> : (
        <table cellPadding="6" style={{ borderCollapse: "collapse", width: "100%" }}>
          <thead><tr><th>#</th><th>Recipient</th><th>Amount</th><th>Left</th><th>Next due</th><th>Active</th></tr></thead>
          <tbody>
            {mirror.map((m) => (
              <tr key={m.id} style={{ borderTop: "1px solid #ccc" }}>
                <td>{m.id}</td>
                <td><code>{short(m.recipient)}</code></td>
                <td>{m.amount} ETH</td>
                <td>{m.left}</td>
                <td>{fmtTime(m.nextDue)}</td>
                <td>{m.active ? "yes" : "no"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <h2>Payments released</h2>
      {payments.length === 0 ? <p>None yet — payments appear here the moment a callback releases them.</p> : (
        <ul>
          {payments.map((p, i) => (
            <li key={i}>
              Schedule #{p.id}: {p.amount} ETH → <code>{short(p.recipient)}</code> — {p.left} left, next {fmtTime(p.nextDue)}{" "}
              <a href={`${CONFIG.vaultExplorer}/tx/${p.tx}`} target="_blank" rel="noreferrer">tx</a>
            </li>
          ))}
        </ul>
      )}

      <hr />
      <p style={{ fontSize: 14 }}>
        Contracts: {DEPLOYED ? (<>
          vault <a href={`${CONFIG.vaultExplorer}/address/${CONFIG.vaultAddress}`} target="_blank" rel="noreferrer"><code>{short(CONFIG.vaultAddress)}</code></a>
          {" · "}reactive <a href={`${CONFIG.reactiveExplorer}/address/${CONFIG.reactiveAddress}`} target="_blank" rel="noreferrer"><code>{short(CONFIG.reactiveAddress)}</code></a>
        </>) : "addresses pending deployment."}{" "}
        Code: <a href="https://github.com/jozzy001mail/drippay" target="_blank" rel="noreferrer">github.com/jozzy001mail/drippay</a>.
        Built by Joshua Owoade (jozzy-001), Nigeria.
      </p>
    </div>
  );
}

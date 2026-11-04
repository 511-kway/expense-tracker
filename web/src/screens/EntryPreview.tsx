import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { formatMoney } from "../money";
import { formatSigned, warningLines } from "../entries";
import { previewLines, type AccountCounters, type EntryPreview as PreviewData } from "../preview";
import { OwnershipBar } from "./Accounts";

type RpcError = { message?: string; details?: string | null };

export type PreviewState =
  | { kind: "idle" }
  | { kind: "ready"; data: PreviewData; pending: boolean }
  | { kind: "error"; error: RpcError; pending: boolean };

/**
 * Живой предпросмотр (ADR-0010): тот же payload, что уйдёт в create_entry / update_entry, сервер
 * применяет его, пересчитывает и откатывает. Пауза 300 мс после последнего изменения; пока идёт
 * новый запрос, на экране остаётся прошлый ответ, чтобы полоса принадлежности плавно перетекла.
 * payload = "wait": форма ждёт другой ответ сервера (суммы пополнения), прошлый ответ остаётся.
 */
export function useEntryPreview(payload: Record<string, unknown> | null | "wait", entryId?: string): PreviewState {
  const [state, setState] = useState<PreviewState>({ kind: "idle" });
  const key = payload === "wait" ? "wait" : payload ? JSON.stringify(payload) : "";
  useEffect(() => {
    if (!key) return setState({ kind: "idle" });
    setState((s) => (s.kind === "idle" ? s : { ...s, pending: true }));
    if (key === "wait") return;
    let live = true;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc("preview_entry", {
        p_payload: JSON.parse(key) as Record<string, unknown>,
        p_entry_id: entryId ?? null,
      });
      if (!live) return;
      setState(error ? { kind: "error", error, pending: false } : { kind: "ready", data: data as PreviewData, pending: false });
    }, 300);
    return () => {
      live = false;
      window.clearTimeout(t);
    };
  }, [key, entryId]);
  return state;
}

/** Что станет с остатком, авансом и долгом, если записать: числа от сервера, клиент не считает. */
export function EffectPreview(props: {
  state: PreviewState;
  accountNames?: ReadonlyMap<string, string>;
  errorText: (error: RpcError) => string;
}) {
  const { state } = props;
  if (state.kind === "idle") return null;
  const busy = state.pending ? " is-pending" : "";
  if (state.kind === "error")
    return (
      <section className={`effect effect--error${busy}`} aria-live="polite" aria-labelledby="effect-title">
        <h3 id="effect-title" className="effect__title">
          Не запишется
        </h3>
        <p className="effect__error">{props.errorText(state.error)}</p>
      </section>
    );

  const { accounts, debt } = previewLines(state.data);
  const still = debt.length === 0 && accounts.every((a) => a.delta.balance_minor === 0 && a.delta.advance_minor === 0);
  const names = new Map([
    ...(props.accountNames ?? new Map<string, string>()),
    ...state.data.accounts.map((a) => [a.account_id, a.name] as const),
  ]);
  const currencies = new Map(state.data.accounts.map((a) => [a.account_id, a.currency] as const));
  const notices = warningLines(state.data.warnings ?? [], names, currencies);
  return (
    <section className={`effect${busy}`} aria-live="polite" aria-labelledby="effect-title" aria-busy={state.pending}>
      <h3 id="effect-title" className="effect__title">
        {still ? "Остаток и долг не изменятся" : "Что изменится"}
      </h3>
      {accounts.map((a) => {
        const withAdvance = a.before.advance_minor !== 0 || a.after.advance_minor !== 0;
        return (
          <div className="effect__account" key={a.account_id}>
            <div className="effect__head">
              <span className="effect__name">{a.name}</span>
              <span className={`amount effect__total${a.after.balance_minor < 0 ? " is-negative" : ""}`}>
                {formatMoney(a.after.balance_minor, a.currency)}
              </span>
            </div>
            <MovingBar before={a.before} after={a.after} />
            <dl className="effect__rows">
              <EffectRow label="Остаток" before={a.before.balance_minor} after={a.after.balance_minor} delta={a.delta.balance_minor} currency={a.currency} />
              {withAdvance && (
                <>
                  <EffectRow label="Свои" side="own" before={a.before.own_minor} after={a.after.own_minor} delta={a.delta.own_minor} currency={a.currency} />
                  <EffectRow label="Аванс" side="company" before={a.before.advance_minor} after={a.after.advance_minor} delta={a.delta.advance_minor} currency={a.currency} />
                </>
              )}
            </dl>
          </div>
        );
      })}
      {debt.length > 0 ? (
        <dl className="effect__rows effect__debt">
          {debt.map((d) => (
            <EffectRow
              key={d.side}
              label={d.label}
              side={d.side === "company_owes_me" ? "own" : "company"}
              before={d.before}
              after={d.after}
              delta={d.delta}
              currency="KZT"
            />
          ))}
        </dl>
      ) : (
        !still && <p className="field__hint">Долг с компанией не изменится.</p>
      )}
      {notices.map((n) => (
        <p className="effect__warning" key={n}>
          {n}
        </p>
      ))}
    </section>
  );
}

/** Строка «было → станет (изменение)». */
function EffectRow(props: {
  label: string;
  side?: "own" | "company";
  before: number;
  after: number;
  delta: number;
  currency: string;
}) {
  const neg = (m: number) => (m < 0 ? " is-negative" : "");
  return (
    <div className={`effect__row${props.delta === 0 ? " is-still" : ""}`}>
      <dt>
        {props.side && <span className={`swatch swatch--${props.side}`} aria-hidden="true" />}
        {props.label}
      </dt>
      <dd>
        {props.delta === 0 ? (
          <span className="amount">{formatMoney(props.after, props.currency)}</span>
        ) : (
          <>
            <span className="effect__change">
              <span className={`amount effect__was${neg(props.before)}`}>{formatMoney(props.before, props.currency)}</span>
              <span aria-label="станет"> → </span>
              <span className={`amount${neg(props.after)}`}>{formatMoney(props.after, props.currency)}</span>
            </span>
            <span className="effect__delta">{formatSigned(props.delta, props.currency)}</span>
          </>
        )}
      </dd>
    </div>
  );
}

/**
 * Полоса принадлежности, которая перетекает из «было» в «станет» (единственная анимация
 * приложения, 200 мс, docs/design.md); prefers-reduced-motion выключает переход в styles.css.
 */
function MovingBar({ before, after }: { before: AccountCounters; after: AccountCounters }) {
  const [shown, setShown] = useState(before);
  useEffect(() => {
    const id = window.requestAnimationFrame(() => setShown(after));
    return () => window.cancelAnimationFrame(id);
  }, [after.own_minor, after.advance_minor]);
  return <OwnershipBar own={shown.own_minor} company={shown.advance_minor} />;
}

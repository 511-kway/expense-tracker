import { useState, type FormEvent } from "react";
import { supabase } from "../supabase";
import { currencySign, formatAmountInput, formatMoney, parseAmountInput } from "../money";
import { todayInAlmaty } from "../dates";
import { errorText } from "../errors";
import type { EntryWarning } from "../entries";
import type { AccountRow } from "./Accounts";
import { ChoiceOption, useSourceNeeded, type EntryPrefill, type SaveResult } from "./EntryForm";
import { useNbkRate } from "./Conversion";

type Purpose = "personal" | "work";

/** Сколько счетов показывать кнопками; больше — выпадающим списком. */
const ACCOUNT_CHIPS = 6;

/**
 * Быстрый ввод траты (ADR-0009; spec.md, истории 69–75): сумма, счёт, личное или работа, коротко
 * что это. Сервер (quick_capture) решает, учесть сразу или оставить черновиком «источник?» в
 * инбоксе; форма заранее говорит, что будет, по ответу expense_source_needed. Всё введённое
 * переносится в полную форму кнопкой «Развернуть в полную форму».
 */
export function QuickCapture(props: {
  accounts: AccountRow[];
  accountingStartDate: string;
  onSaved: (result: SaveResult) => void;
  onExpand: (prefill: EntryPrefill) => void;
  /** Режим «заметка» (док 04, 4.1): текст или скрин, не запись. */
  onNote?: () => void;
}) {
  const accounts = props.accounts.filter((a) => !a.is_archived);
  const today = todayInAlmaty();
  const date = today < props.accountingStartDate ? props.accountingStartDate : today;
  const [amount, setAmount] = useState("");
  const [accountId, setAccountId] = useState(accounts.length === 1 ? accounts[0]!.account_id : "");
  const [purpose, setPurpose] = useState<Purpose | null>(null);
  const [title, setTitle] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  const account = accounts.find((a) => a.account_id === accountId);
  const currency = account?.currency ?? "KZT";
  // Валютный счёт: трата в его валюте по курсу Нацбанка; курс сначала кладёт в кэш fetch_rates.
  const nbk = useNbkRate(currency !== "KZT", currency, date);
  const sourceCheck = useSourceNeeded(purpose === "personal" ? accountId : "", date);
  const becomesDraft = purpose === "personal" && sourceCheck?.needed === true;

  function expand() {
    props.onExpand({ amount, accountId, purpose, title: title.trim(), date });
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    const parsed = parseAmountInput(amount);
    if (!parsed.ok)
      return setFailure(parsed.error === "empty" ? "Введите сумму." : "Введите сумму цифрами, копейки не больше двух знаков.");
    if (parsed.minor === 0) return setFailure("Сумма должна быть больше нуля.");
    if (!accountId) return setFailure("Выберите счёт.");
    if (!purpose) return setFailure("Выберите: личное или работа.");
    if (currency !== "KZT" && nbk.state !== "ready")
      return setFailure(
        nbk.state === "pending" || nbk.state === "idle"
          ? "Загружаем курс Нацбанка, нажмите ещё раз через секунду."
          : "Курса Нацбанка нет. Разверните полную форму и введите свой курс или сумму в тенге.",
      );

    setBusy(true);
    const { data, error } = await supabase.rpc("quick_capture", {
      p_payload: {
        occurred_on: date,
        amount_minor: parsed.minor,
        currency,
        rate_source: currency === "KZT" ? null : "nbk",
        account_id: accountId,
        purpose,
        title: title.trim() || null,
      },
    });
    setBusy(false);
    if (error) return setFailure(errorText(error));
    const d = data as { status: "done" | "draft"; warnings?: EntryWarning[] };
    props.onSaved({
      message: d.status === "draft" ? "Черновик в инбоксе: уточните, чьими деньгами" : "Трата записана, категорию выберите в инбоксе",
      warnings: d.warnings ?? [],
    });
  }

  if (accounts.length === 0)
    return (
      <p className="empty">
        Сначала добавьте счёт: трата всегда идёт по счёту. <a href="#/accounts">Перейти к счетам</a>
      </p>
    );

  return (
    <form className="account-form quick" onSubmit={submit} noValidate>
      <div className="field">
        <label htmlFor="quick-amount">Сумма</label>
        <div className="money-input money-input--large">
          <input
            id="quick-amount"
            type="text"
            inputMode="decimal"
            autoComplete="off"
            enterKeyHint="next"
            placeholder="0"
            value={amount}
            onChange={(e) => setAmount(formatAmountInput(e.target.value))}
            autoFocus
          />
          <span aria-hidden="true">{currencySign(currency)}</span>
        </div>
      </div>

      {accounts.length <= ACCOUNT_CHIPS ? (
        <fieldset className="choice">
          <legend>Счёт</legend>
          <div className="choice__options">
            {accounts.map((a) => (
              <ChoiceOption
                key={a.account_id}
                name="quick-account"
                checked={accountId === a.account_id}
                onChange={() => setAccountId(a.account_id)}
                label={a.name}
              />
            ))}
          </div>
        </fieldset>
      ) : (
        <div className="field">
          <label htmlFor="quick-account">Счёт</label>
          <select id="quick-account" value={accountId} onChange={(e) => setAccountId(e.target.value)}>
            {!accountId && <option value="">Выберите счёт</option>}
            {accounts.map((a) => (
              <option key={a.account_id} value={a.account_id}>
                {a.name}
              </option>
            ))}
          </select>
        </div>
      )}

      <fieldset className="choice">
        <legend>Для чего</legend>
        <div className="choice__options">
          <ChoiceOption name="quick-purpose" checked={purpose === "personal"} onChange={() => setPurpose("personal")} label="Личное" />
          <ChoiceOption name="quick-purpose" checked={purpose === "work"} onChange={() => setPurpose("work")} label="Работа" />
        </div>
      </fieldset>

      <div className="field">
        <label htmlFor="quick-title">Что это</label>
        <input
          id="quick-title"
          type="text"
          autoComplete="off"
          enterKeyHint="done"
          placeholder="Например, такси до офиса"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
        />
      </div>

      {becomesDraft && sourceCheck && (
        <p className="source-question quick__draft" role="status">
          На счёте аванс <span className="amount">{formatMoney(sourceCheck.advance, "KZT")}</span>: непонятно, чьими
          деньгами оплачено. Трата ляжет в инбокс черновиком «источник?» и не изменит остаток, пока вы не уточните.
        </p>
      )}

      <div className="account-form__actions">
        <button className="button button--primary" type="submit" disabled={busy}>
          {becomesDraft ? "Сохранить черновик" : "Записать трату"}
        </button>
        <button className="button button--quiet" type="button" onClick={expand}>
          Развернуть в полную форму
        </button>
        {props.onNote && (
          <button className="button button--quiet" type="button" onClick={props.onNote}>
            Это заметка, не трата
          </button>
        )}
        {failure && (
          <p className="error" role="alert">
            {failure}
          </p>
        )}
      </div>
    </form>
  );
}

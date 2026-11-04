import { useEffect, useState, type FormEvent } from "react";
import { supabase } from "../supabase";
import { formatAmountInput, formatMoney, minorToAmountInput, parseAmountInput } from "../money";
import { formatDate, todayInAlmaty } from "../dates";
import { errorText } from "../errors";
import { advanceReturnErrorText, errorDetails, type EntryRow, type EntryWarning } from "../entries";
import { MoneyField } from "./form";
import type { AccountRow } from "./Accounts";
import type { CategoryRow } from "./Categories";

type FormType = "expense" | "income" | "company_topup" | "company_advance_return";
type FeeStyle = "arrived_fee" | "sent_fee" | "sent_arrived";
type Purpose = "personal" | "work";
type Source = "own" | "company";

const FORM_TYPES: FormType[] = ["expense", "income", "company_topup", "company_advance_return"];

const SAVED: Record<FormType, string> = {
  expense: "Трата записана",
  income: "Поступление записано",
  company_topup: "Пополнение записано",
  company_advance_return: "Изъятие записано",
};

const SUBMIT: Record<FormType, string> = {
  expense: "Записать трату",
  income: "Записать поступление",
  company_topup: "Записать пополнение",
  company_advance_return: "Записать изъятие",
};

/** Три способа ввести комиссию пополнения: какие два числа известны. Суммы считает сервер. */
const FEE_STYLES: Record<FeeStyle, { option: string; first: string; second: string }> = {
  arrived_fee: { option: "Сколько пришло и комиссия", first: "Пришло на счёт", second: "Комиссия" },
  sent_fee: { option: "Сколько отправила компания и комиссия", first: "Отправила компания", second: "Комиссия" },
  sent_arrived: { option: "Сколько отправила и сколько пришло", first: "Отправила компания", second: "Пришло на счёт" },
};

export type SaveResult = { message: string; warnings: EntryWarning[] };

/**
 * Форма записи (док 04, 4.2): трата, поступление, пополнение от компании, изъятие аванса.
 * Клиент собирает ввод и зовёт create_entry / update_entry; сплит, источник по умолчанию,
 * суммы пополнения с комиссией и проверки делает сервер. Вопрос «чьими деньгами» только у
 * личной траты, когда сервер говорит, что на счёте на эту дату есть аванс.
 */
export function EntryForm(props: {
  entry?: EntryRow;
  accounts: AccountRow[];
  categories: CategoryRow[];
  accountingStartDate: string;
  onSaved: (result: SaveResult) => void;
}) {
  const { entry, accountingStartDate } = props;
  const accounts = props.accounts.filter((a) => !a.is_archived || a.account_id === entry?.account_id);
  const categories = props.categories.filter((c) => !c.is_archived || c.id === entry?.category_id);
  const today = todayInAlmaty();

  const [type, setType] = useState<FormType>(
    entry && (FORM_TYPES as string[]).includes(entry.type) ? (entry.type as FormType) : "expense",
  );
  const isTopup = entry?.type === "company_topup";
  // Пополнение на правке открывается способом «пришло и комиссия»: пришло = движение остатка по журналу.
  const [amount, setAmount] = useState(
    entry ? minorToAmountInput(isTopup ? entry.balance_delta_minor : entry.amount_minor) : "",
  );
  const [feeStyle, setFeeStyle] = useState<FeeStyle>("arrived_fee");
  const [second, setSecond] = useState(isTopup && entry?.fee_minor ? minorToAmountInput(entry.fee_minor) : "");
  const [feePayer, setFeePayer] = useState<Source | null>(entry?.fee_payer ?? null);
  const [accountId, setAccountId] = useState(entry?.account_id ?? (accounts.length === 1 ? accounts[0]!.account_id : ""));
  const [purpose, setPurpose] = useState<Purpose | null>(entry?.purpose ?? null);
  const [source, setSource] = useState<Source | null>(entry?.source ?? null);
  const [categoryId, setCategoryId] = useState(entry?.category_id ?? "");
  const [date, setDate] = useState(entry?.occurred_on ?? (today < accountingStartDate ? accountingStartDate : today));
  const [comment, setComment] = useState(entry?.comment ?? "");
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  const account = accounts.find((a) => a.account_id === accountId);
  const asksSource = type === "expense" && purpose === "personal";
  const sourceCheck = useSourceNeeded(asksSource ? accountId : "", date, entry?.entry_id);
  const sourceNeeded = asksSource && sourceCheck?.needed === true;
  const withdrawalAdvance = useAdvanceOnDate(type === "company_advance_return" ? accountId : "", date, entry?.entry_id);
  const topup = useTopupAmounts(type === "company_topup", feeStyle, amount, second, feePayer);

  // Конфликт изъятия на самой записи из формы, а не на более позднем изъятии.
  function isSelfConflict(d: Record<string, unknown>, amountMinor: number): boolean {
    if (type !== "company_advance_return") return false;
    if (entry) return d.entry_id === entry.entry_id;
    return d.occurred_on === date && d.amount_minor === amountMinor;
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    const parsed = parseAmountInput(amount);
    if (!parsed.ok)
      return setFailure(parsed.error === "empty" ? "Введите сумму." : "Введите сумму цифрами, копейки не больше двух знаков.");
    if (parsed.minor === 0) return setFailure("Сумма должна быть больше нуля.");
    if (!accountId) return setFailure("Выберите счёт.");
    if (type === "company_topup") {
      if (topup.state === "invalid") return setFailure("Введите суммы цифрами, копейки не больше двух знаков.");
      if (topup.state === "error") return setFailure(topup.message);
      if (topup.state !== "ready") return setFailure("Считаем суммы пополнения, нажмите ещё раз через секунду.");
      if (topup.amounts.fee_payer_needed && !feePayer) return setFailure("Выберите, кто заплатил комиссию.");
    }
    if (type === "expense" && !purpose) return setFailure("Выберите: личное или работа.");
    if (type === "expense" && !categoryId) return setFailure("Выберите категорию.");
    if (sourceNeeded && !source) return setFailure("Выберите, чьими деньгами оплачено.");
    if (!date) return setFailure("Выберите дату.");

    const payload: Record<string, unknown> = {
      type,
      occurred_on: date,
      amount_minor: parsed.minor,
      account_id: accountId,
      category_id: type === "expense" || type === "income" ? categoryId || null : null,
      comment: comment.trim() || null,
    };
    if (type === "expense") {
      payload.purpose = purpose;
      payload.source = sourceNeeded ? source : null;
    }
    if (type === "company_topup" && topup.state === "ready") {
      // Сумма записи и комиссия ровно как их посчитал сервер (topup_amounts).
      payload.amount_minor = topup.amounts.amount_minor;
      payload.fee_minor = topup.amounts.fee_minor;
      payload.fee_payer = topup.amounts.fee_payer;
    }

    setBusy(true);
    const { data, error } = entry
      ? await supabase.rpc("update_entry", { p_entry_id: entry.entry_id, p_payload: payload })
      : await supabase.rpc("create_entry", { p_payload: payload });
    setBusy(false);
    if (error) return setFailure(entryErrorText(error, (d) => isSelfConflict(d, parsed.minor)));
    props.onSaved({
      message: entry ? "Запись сохранена" : SAVED[type],
      warnings: ((data as { warnings?: EntryWarning[] }).warnings ?? []) as EntryWarning[],
    });
  }

  async function remove() {
    if (!entry) return;
    if (!confirmDelete) return setConfirmDelete(true);
    setFailure(null);
    setBusy(true);
    const { data, error } = await supabase.rpc("delete_entry", { p_entry_id: entry.entry_id });
    setBusy(false);
    if (error) return setFailure(entryErrorText(error, () => false));
    props.onSaved({ message: "Запись удалена", warnings: ((data as { warnings?: EntryWarning[] }).warnings ?? []) });
  }

  if (accounts.length === 0)
    return (
      <p className="empty">
        Сначала добавьте счёт: запись всегда идёт по счёту. <a href="#/accounts">Перейти к счетам</a>
      </p>
    );

  return (
    <form className="account-form entry-form" onSubmit={submit} noValidate>
      <fieldset className="choice">
        <legend>Что записать</legend>
        <div className="choice__options choice__options--grid">
          <ChoiceOption name="entry-type" checked={type === "expense"} onChange={() => setType("expense")} label="Трата" />
          <ChoiceOption name="entry-type" checked={type === "income"} onChange={() => setType("income")} label="Поступление" />
          <ChoiceOption
            name="entry-type"
            checked={type === "company_topup"}
            onChange={() => setType("company_topup")}
            label="Пополнение от компании"
            swatch="company"
          />
          <ChoiceOption
            name="entry-type"
            checked={type === "company_advance_return"}
            onChange={() => setType("company_advance_return")}
            label="Изъятие аванса"
            swatch="company"
          />
        </div>
      </fieldset>

      {type === "company_topup" && (
        <div className="field">
          <label htmlFor="entry-fee-style">Что известно</label>
          <select id="entry-fee-style" value={feeStyle} onChange={(e) => setFeeStyle(e.target.value as FeeStyle)}>
            {(Object.keys(FEE_STYLES) as FeeStyle[]).map((k) => (
              <option key={k} value={k}>
                {FEE_STYLES[k].option}
              </option>
            ))}
          </select>
        </div>
      )}

      <div className="field">
        <label htmlFor="entry-amount">{type === "company_topup" ? FEE_STYLES[feeStyle].first : "Сумма"}</label>
        <div className="money-input money-input--large">
          <input
            id="entry-amount"
            type="text"
            inputMode="decimal"
            autoComplete="off"
            placeholder="0"
            value={amount}
            onChange={(e) => setAmount(formatAmountInput(e.target.value))}
            autoFocus={!entry}
          />
          <span aria-hidden="true">₸</span>
        </div>
      </div>

      <div className="account-form__row">
        <div className="field">
          <label htmlFor="entry-account">Счёт</label>
          <select id="entry-account" value={accountId} onChange={(e) => setAccountId(e.target.value)}>
            {!accountId && <option value="">Выберите счёт</option>}
            {accounts.map((a) => (
              <option key={a.account_id} value={a.account_id}>
                {a.name}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor="entry-date">Дата</label>
          <input
            id="entry-date"
            type="date"
            min={account?.start_date ?? accountingStartDate}
            value={date}
            onChange={(e) => setDate(e.target.value)}
          />
        </div>
      </div>

      {type === "company_topup" && (
        <>
          <MoneyField
            id="entry-second"
            label={feeStyle === "sent_arrived" ? FEE_STYLES[feeStyle].second : "Комиссия, если была"}
            value={second}
            onChange={setSecond}
          />
          {topup.state === "ready" && topup.amounts.fee_payer_needed && (
            <fieldset className="choice">
              <legend>Кто заплатил комиссию</legend>
              <div className="choice__options">
                <ChoiceOption
                  name="entry-fee-payer"
                  checked={feePayer === "own"}
                  onChange={() => setFeePayer("own")}
                  label="Я, своими"
                  swatch="own"
                />
                <ChoiceOption
                  name="entry-fee-payer"
                  checked={feePayer === "company"}
                  onChange={() => setFeePayer("company")}
                  label="Компания"
                  swatch="company"
                />
              </div>
            </fieldset>
          )}
          <TopupSummary topup={topup} feePayer={feePayer} />
        </>
      )}

      {type === "company_advance_return" && (
        <p className="field__hint">
          Компания забирает свои деньги с этого счёта: аванс и остаток уменьшатся, долг не изменится.
          {withdrawalAdvance !== null && (
            <>
              {" "}
              Аванс на эту дату <span className="amount">{formatMoney(withdrawalAdvance, "KZT")}</span>, изъять
              можно не больше.
            </>
          )}
        </p>
      )}

      {type === "expense" && (
        <fieldset className="choice">
          <legend>Для чего</legend>
          <div className="choice__options">
            <ChoiceOption name="entry-purpose" checked={purpose === "personal"} onChange={() => setPurpose("personal")} label="Личное" />
            <ChoiceOption name="entry-purpose" checked={purpose === "work"} onChange={() => setPurpose("work")} label="Работа" />
          </div>
          {purpose === "work" && (
            <p className="field__hint">Сначала тратится аванс счёта, недостающее запишется как «компания должна мне».</p>
          )}
        </fieldset>
      )}

      {sourceNeeded && sourceCheck && (
        <fieldset className="choice source-question">
          <legend>Чьими деньгами</legend>
          <div className="choice__options">
            <ChoiceOption
              name="entry-source"
              checked={source === "own"}
              onChange={() => setSource("own")}
              label="Своими"
              swatch="own"
            />
            <ChoiceOption
              name="entry-source"
              checked={source === "company"}
              onChange={() => setSource("company")}
              label="Деньгами компании"
              swatch="company"
            />
          </div>
          <p className="field__hint">
            На счёте на эту дату аванс <span className="amount">{formatMoney(sourceCheck.advance, "KZT")}</span>.
            {source === "company" && " Потраченный аванс запишется как «я должен компании»."}
          </p>
        </fieldset>
      )}

      {(type === "expense" || type === "income") && (
        <div className="field">
          <label htmlFor="entry-category">{type === "expense" ? "Категория" : "Категория, по желанию"}</label>
          <select id="entry-category" value={categoryId} onChange={(e) => setCategoryId(e.target.value)}>
            <option value="">{type === "expense" ? "Выберите категорию" : "Без категории"}</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
          {categories.length === 0 && (
            <p className="field__hint">
              Категорий пока нет. <a href="#/categories">Добавьте категорию</a>, чтобы записать трату.
            </p>
          )}
        </div>
      )}

      <div className="field">
        <label htmlFor="entry-comment">Комментарий</label>
        <textarea id="entry-comment" rows={2} value={comment} onChange={(e) => setComment(e.target.value)} />
      </div>

      <div className="account-form__actions">
        <button className="button button--primary" type="submit" disabled={busy}>
          {entry ? "Сохранить" : SUBMIT[type]}
        </button>
        {entry && (
          <div className="account-form__secondary">
            <button className="button button--danger" type="button" disabled={busy} onClick={() => void remove()}>
              {confirmDelete ? "Точно удалить запись" : "Удалить запись"}
            </button>
            {confirmDelete && (
              <button className="button button--quiet" type="button" onClick={() => setConfirmDelete(false)}>
                Не удалять
              </button>
            )}
          </div>
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

function ChoiceOption(props: {
  name: string;
  checked: boolean;
  onChange: () => void;
  label: string;
  swatch?: "own" | "company";
}) {
  return (
    <label className="choice__option">
      <input type="radio" name={props.name} checked={props.checked} onChange={props.onChange} />
      <span>
        {props.swatch && <span className={`swatch swatch--${props.swatch}`} aria-hidden="true" />}
        {props.label}
      </span>
    </label>
  );
}

/** Нужен ли вопрос «чьими деньгами»: решает сервер (expense_source_needed), пауза 250 мс. */
function useSourceNeeded(accountId: string, date: string, entryId?: string): { needed: boolean; advance: number } | null {
  const [state, setState] = useState<{ needed: boolean; advance: number } | null>(null);
  useEffect(() => {
    setState(null);
    if (!accountId || !date) return;
    let live = true;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc("expense_source_needed", {
        p_account_id: accountId,
        p_occurred_on: date,
        p_entry_id: entryId ?? null,
      });
      if (!live || error) return;
      const d = data as { source_needed: boolean; advance_minor: number };
      setState({ needed: d.source_needed, advance: d.advance_minor });
    }, 250);
    return () => {
      live = false;
      window.clearTimeout(t);
    };
  }, [accountId, date, entryId]);
  return state;
}

/** Аванс счёта на дату для формы изъятия: считает сервер (advance_on_date), пауза 250 мс. */
function useAdvanceOnDate(accountId: string, date: string, entryId?: string): number | null {
  const [advance, setAdvance] = useState<number | null>(null);
  useEffect(() => {
    setAdvance(null);
    if (!accountId || !date) return;
    let live = true;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc("advance_on_date", {
        p_account_id: accountId,
        p_occurred_on: date,
        p_entry_id: entryId ?? null,
      });
      if (live && !error) setAdvance((data as { advance_minor: number }).advance_minor);
    }, 250);
    return () => {
      live = false;
      window.clearTimeout(t);
    };
  }, [accountId, date, entryId]);
  return advance;
}

function entryErrorText(
  error: { message?: string; details?: string | null },
  isSelf: (d: Record<string, unknown>) => boolean,
): string {
  if (error.message === "advance_return_too_big") {
    const d = errorDetails(error);
    return advanceReturnErrorText(d, isSelf(d));
  }
  if (error.message === "entry_before_start") {
    const d = errorDetails(error);
    if (typeof d.start_date === "string") return `Запись раньше даты старта счёта, ${formatDate(d.start_date)}.`;
    if (typeof d.accounting_start_date === "string")
      return `Запись раньше начала учёта, ${formatDate(d.accounting_start_date)}.`;
  }
  return errorText(error);
}

type TopupAmounts = {
  sent_minor: number;
  arrived_minor: number;
  fee_minor: number;
  fee_payer_needed: boolean;
  fee_payer: Source | null;
  amount_minor: number | null;
};

type TopupState =
  | { state: "idle" | "pending" | "invalid" }
  | { state: "error"; message: string }
  | { state: "ready"; amounts: TopupAmounts };

/**
 * Суммы пополнения из двух известных чисел (способ ввода комиссии): считает сервер
 * (topup_amounts), пауза 250 мс. Клиент только разбирает ввод.
 */
function useTopupAmounts(active: boolean, style: FeeStyle, first: string, second: string, payer: Source | null): TopupState {
  const [state, setState] = useState<TopupState>({ state: "idle" });
  useEffect(() => {
    if (!active) return setState({ state: "idle" });
    const a = parseAmountInput(first);
    const b = second.trim() === "" && style !== "sent_arrived" ? ({ ok: true, minor: 0 } as const) : parseAmountInput(second);
    if (!a.ok && a.error === "empty") return setState({ state: "idle" });
    if (!a.ok || !b.ok) return setState({ state: b.ok || b.error !== "empty" ? "invalid" : "idle" });
    setState({ state: "pending" });
    let live = true;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc("topup_amounts", {
        p_style: style,
        p_first_minor: a.minor,
        p_second_minor: b.minor,
        p_fee_payer: payer,
      });
      if (!live) return;
      if (error) setState({ state: "error", message: errorText(error) });
      else setState({ state: "ready", amounts: data as TopupAmounts });
    }, 250);
    return () => {
      live = false;
      window.clearTimeout(t);
    };
  }, [active, style, first, second, payer]);
  return state;
}

/** Что получится из пополнения: суммы от сервера и правило комиссии словами (ADR-0003). */
function TopupSummary({ topup, feePayer }: { topup: TopupState; feePayer: Source | null }) {
  if (topup.state === "error")
    return (
      <p className="error" role="alert">
        {topup.message}
      </p>
    );
  if (topup.state !== "ready") return null;
  const t = topup.amounts;
  const money = (m: number) => <span className="amount">{formatMoney(m, "KZT")}</span>;
  return (
    <div className="topup-summary" aria-live="polite">
      <p>
        На счёт придёт {money(t.arrived_minor)}
        {t.fee_minor > 0 && <>, комиссия {money(t.fee_minor)}</>}.
      </p>
      {t.fee_minor === 0 && <p className="field__hint">Всё пришедшее станет авансом.</p>}
      {t.fee_minor > 0 && feePayer === "company" && (
        <p className="field__hint">Комиссию понесла компания: авансом станет то, что пришло, долг не изменится.</p>
      )}
      {t.fee_minor > 0 && feePayer === "own" && (
        <p className="field__hint">
          Компания засчитает авансом {money(t.sent_minor)}. Комиссия спишется со своих денег на счёте и уменьшит «я должен
          компании», остаток запишется как «компания должна мне». Если своих не хватит, нехватку съест аванс.
        </p>
      )}
    </div>
  );
}

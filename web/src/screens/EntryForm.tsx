import { useEffect, useState, type FormEvent } from "react";
import { supabase } from "../supabase";
import { formatAmountInput, formatMoney, minorToAmountInput, parseAmountInput } from "../money";
import { formatDate, todayInAlmaty } from "../dates";
import { errorText } from "../errors";
import { errorDetails, type EntryRow, type EntryWarning } from "../entries";
import type { AccountRow } from "./Accounts";
import type { CategoryRow } from "./Categories";

type FormType = "expense" | "income";
type Purpose = "personal" | "work";
type Source = "own" | "company";

export type SaveResult = { message: string; warnings: EntryWarning[] };

/**
 * Форма траты и поступления (док 04, 4.2). Клиент собирает ввод и зовёт create_entry /
 * update_entry; сплит, источник по умолчанию и проверки делает сервер. Вопрос «чьими деньгами»
 * только у личной траты, когда сервер говорит, что на счёте на эту дату есть аванс.
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

  const [type, setType] = useState<FormType>(entry?.type === "income" ? "income" : "expense");
  const [amount, setAmount] = useState(entry ? minorToAmountInput(entry.amount_minor) : "");
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

  async function submit(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    const parsed = parseAmountInput(amount);
    if (!parsed.ok)
      return setFailure(parsed.error === "empty" ? "Введите сумму." : "Введите сумму цифрами, копейки не больше двух знаков.");
    if (parsed.minor === 0) return setFailure("Сумма должна быть больше нуля.");
    if (!accountId) return setFailure("Выберите счёт.");
    if (type === "expense" && !purpose) return setFailure("Выберите: личное или работа.");
    if (type === "expense" && !categoryId) return setFailure("Выберите категорию.");
    if (sourceNeeded && !source) return setFailure("Выберите, чьими деньгами оплачено.");
    if (!date) return setFailure("Выберите дату.");

    const payload: Record<string, unknown> = {
      type,
      occurred_on: date,
      amount_minor: parsed.minor,
      account_id: accountId,
      category_id: categoryId || null,
      comment: comment.trim() || null,
    };
    if (type === "expense") {
      payload.purpose = purpose;
      payload.source = sourceNeeded ? source : null;
    }

    setBusy(true);
    const { data, error } = entry
      ? await supabase.rpc("update_entry", { p_entry_id: entry.entry_id, p_payload: payload })
      : await supabase.rpc("create_entry", { p_payload: payload });
    setBusy(false);
    if (error) return setFailure(entryErrorText(error));
    props.onSaved({
      message: entry ? "Запись сохранена" : type === "expense" ? "Трата записана" : "Поступление записано",
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
    if (error) return setFailure(entryErrorText(error));
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
        <div className="choice__options">
          <ChoiceOption name="entry-type" checked={type === "expense"} onChange={() => setType("expense")} label="Трата" />
          <ChoiceOption name="entry-type" checked={type === "income"} onChange={() => setType("income")} label="Поступление" />
        </div>
      </fieldset>

      <div className="field">
        <label htmlFor="entry-amount">Сумма</label>
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

      <div className="field">
        <label htmlFor="entry-comment">Комментарий</label>
        <textarea id="entry-comment" rows={2} value={comment} onChange={(e) => setComment(e.target.value)} />
      </div>

      <div className="account-form__actions">
        <button className="button button--primary" type="submit" disabled={busy}>
          {entry ? "Сохранить" : type === "expense" ? "Записать трату" : "Записать поступление"}
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

function entryErrorText(error: { message?: string; details?: string | null }): string {
  if (error.message === "entry_before_start") {
    const d = errorDetails(error);
    if (typeof d.start_date === "string") return `Запись раньше даты старта счёта, ${formatDate(d.start_date)}.`;
    if (typeof d.accounting_start_date === "string")
      return `Запись раньше начала учёта, ${formatDate(d.accounting_start_date)}.`;
  }
  return errorText(error);
}

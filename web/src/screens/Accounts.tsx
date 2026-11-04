import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { supabase } from "../supabase";
import { amountOrZero, formatAmountInput, formatMoney } from "../money";
import { formatDate, todayInAlmaty } from "../dates";
import { errorText } from "../errors";

type AccountType = "card" | "bank_account" | "cash";

export type AccountRow = {
  account_id: string;
  name: string;
  bank: string | null;
  type: AccountType;
  mask: string | null;
  currency: string;
  start_date: string;
  balance_minor: number;
  advance_minor: number;
  own_minor: number;
  is_archived: boolean;
  has_entries: boolean;
};

const TYPE_LABELS: Record<AccountType, string> = { card: "Карта", bank_account: "Банковский счёт", cash: "Наличные" };
const CURRENCIES = ["KZT", "USD", "EUR", "RUB", "TRY"];

type ListState = { kind: "loading" } | { kind: "error" } | { kind: "ready"; rows: AccountRow[] };
type Sheet = { kind: "closed" } | { kind: "create" } | { kind: "edit"; account: AccountRow };

/**
 * «Счета»: у каждого остаток и полоса принадлежности (свои и аванс), всё из v_account_balances.
 * Создание, правка, архив и удаление через RPC; клиент денег не считает.
 */
export function Accounts({ accountingStartDate }: { accountingStartDate: string }) {
  const [state, setState] = useState<ListState>({ kind: "loading" });
  const [sheet, setSheet] = useState<Sheet>({ kind: "closed" });
  const [toast, setToast] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from("v_account_balances")
      .select(
        "account_id, name, bank, type, mask, currency, start_date, balance_minor, advance_minor, own_minor, is_archived, has_entries",
      )
      .order("name");
    setState(error || !data ? { kind: "error" } : { kind: "ready", rows: data as AccountRow[] });
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(null), 3000);
    return () => window.clearTimeout(t);
  }, [toast]);

  function done(message: string) {
    setSheet({ kind: "closed" });
    setToast(message);
    void load();
  }

  const addButton = (
    <button className="button button--primary" type="button" onClick={() => setSheet({ kind: "create" })}>
      Добавить счёт
    </button>
  );

  let body: ReactNode;
  if (state.kind === "loading") body = <p className="muted" aria-busy="true">Загружаем счета…</p>;
  else if (state.kind === "error")
    body = (
      <p className="error" role="alert">
        Не получилось загрузить счета. Обновите страницу.
      </p>
    );
  else {
    const active = state.rows.filter((r) => !r.is_archived);
    const archived = state.rows.filter((r) => r.is_archived);
    body = (
      <>
        {active.length === 0 ? (
          <p className="empty">Счетов пока нет. Добавьте карту, банковский счёт или наличные.</p>
        ) : (
          <ul className="accounts">
            {active.map((a) => (
              <AccountItem key={a.account_id} account={a} onOpen={() => setSheet({ kind: "edit", account: a })} />
            ))}
          </ul>
        )}
        {archived.length > 0 && (
          <details className="accounts-archive">
            <summary>Архив: {archived.length}</summary>
            <ul className="accounts">
              {archived.map((a) => (
                <AccountItem key={a.account_id} account={a} onOpen={() => setSheet({ kind: "edit", account: a })} />
              ))}
            </ul>
          </details>
        )}
      </>
    );
  }

  return (
    <div className="accounts-screen">
      <div className="accounts-screen__actions">{addButton}</div>
      {body}
      {sheet.kind !== "closed" && (
        <SheetDialog
          title={sheet.kind === "create" ? "Новый счёт" : sheet.account.name}
          onClose={() => setSheet({ kind: "closed" })}
        >
          {sheet.kind === "create" ? (
            <CreateAccountForm accountingStartDate={accountingStartDate} onDone={() => done("Счёт добавлен")} />
          ) : (
            <EditAccountForm account={sheet.account} onDone={done} />
          )}
        </SheetDialog>
      )}
      {toast && (
        <p className="toast" role="status">
          {toast}
        </p>
      )}
    </div>
  );
}

function AccountItem({ account: a, onOpen }: { account: AccountRow; onOpen: () => void }) {
  const negative = a.balance_minor < 0;
  return (
    <li>
      <button className="account" type="button" onClick={onOpen} aria-label={`${a.name}: изменить счёт`}>
        <span className="account__head">
          <span className="account__name">{a.name}</span>
          <span className={`account__balance amount${negative ? " is-negative" : ""}`}>
            {formatMoney(a.balance_minor, a.currency)}
          </span>
        </span>
        <span className="account__meta muted">{accountMeta(a)}</span>
        <OwnershipBar own={a.own_minor} company={a.advance_minor} />
        <span className="account__parts">
          <span>
            <span className="swatch swatch--own" aria-hidden="true" />
            Свои <span className={`amount${a.own_minor < 0 ? " is-negative" : ""}`}>{formatMoney(a.own_minor, a.currency)}</span>
          </span>
          <span>
            <span className="swatch swatch--company" aria-hidden="true" />
            Аванс <span className="amount">{formatMoney(a.advance_minor, "KZT")}</span>
          </span>
        </span>
      </button>
    </li>
  );
}

function accountMeta(a: AccountRow): string {
  const parts = [a.type === "cash" ? TYPE_LABELS.cash : [TYPE_LABELS[a.type], a.bank].filter(Boolean).join(" ")];
  if (a.mask) parts.push(`*${a.mask}`);
  if (a.currency !== "KZT") parts.push(a.currency);
  return parts.join(", ");
}

/** Полоса принадлежности: длины частей пропорциональны суммам с сервера, только для картинки. */
export function OwnershipBar({ own, company }: { own: number; company: number }) {
  const ownGrow = Math.max(own, 0);
  const companyGrow = Math.max(company, 0);
  const empty = ownGrow + companyGrow === 0;
  return (
    <span className={`ownership-bar ownership-bar--account${empty ? " is-empty" : ""}`} aria-hidden="true">
      <span className="own" style={{ flexGrow: ownGrow }} />
      <span className="company" style={{ flexGrow: companyGrow }} />
    </span>
  );
}

/** Лист формы: снизу на телефоне, панелью справа на десктопе. Esc и «Закрыть» закрывают. */
function SheetDialog({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);
  return (
    <dialog
      ref={ref}
      className="sheet"
      aria-labelledby="sheet-title"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
    >
      <div className="sheet__inner">
        <div className="sheet__head">
          <h2 id="sheet-title">{title}</h2>
          <button className="button button--quiet" type="button" onClick={onClose}>
            Закрыть
          </button>
        </div>
        {children}
      </div>
    </dialog>
  );
}

function CreateAccountForm({ accountingStartDate, onDone }: { accountingStartDate: string; onDone: () => void }) {
  const today = todayInAlmaty();
  const [name, setName] = useState("");
  const [type, setType] = useState<AccountType>("card");
  const [bank, setBank] = useState("");
  const [mask, setMask] = useState("");
  const [currency, setCurrency] = useState("KZT");
  const [startDate, setStartDate] = useState(today < accountingStartDate ? accountingStartDate : today);
  const [total, setTotal] = useState("");
  const [company, setCompany] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const foreign = currency !== "KZT";
  const totalMinor = foreign ? 0 : amountOrZero(total);
  const companyMinor = foreign ? 0 : amountOrZero(company);
  const preview = useOpeningPreview(totalMinor, companyMinor, currency);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    if (!name.trim()) return setFailure("Введите название счёта.");
    if (totalMinor === null || companyMinor === null)
      return setFailure("Введите сумму цифрами, копейки не больше двух знаков.");
    if (!startDate) return setFailure("Выберите дату старта счёта.");
    setBusy(true);
    const { error } = await supabase.rpc("create_account", {
      p_name: name,
      p_type: type,
      p_bank: type === "cash" ? null : bank,
      p_mask: mask,
      p_currency: currency,
      p_start_date: startDate,
      p_total_minor: totalMinor,
      p_company_minor: companyMinor,
    });
    setBusy(false);
    if (error) return setFailure(accountErrorText(error));
    onDone();
  }

  return (
    <form className="account-form" onSubmit={submit} noValidate>
      <div className="field">
        <label htmlFor="acc-name">Название</label>
        <input id="acc-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Kaspi Gold" autoComplete="off" />
      </div>

      <fieldset className="choice">
        <legend>Тип</legend>
        <div className="choice__options">
          {(Object.keys(TYPE_LABELS) as AccountType[]).map((t) => (
            <label key={t} className="choice__option">
              <input type="radio" name="acc-type" value={t} checked={type === t} onChange={() => setType(t)} />
              <span>{TYPE_LABELS[t]}</span>
            </label>
          ))}
        </div>
      </fieldset>

      <div className="account-form__row">
        {type !== "cash" && (
          <div className="field">
            <label htmlFor="acc-bank">Банк</label>
            <input id="acc-bank" value={bank} onChange={(e) => setBank(e.target.value)} placeholder="Kaspi" autoComplete="off" />
          </div>
        )}
        <div className="field">
          <label htmlFor="acc-mask">Последние цифры</label>
          <input id="acc-mask" value={mask} onChange={(e) => setMask(e.target.value)} inputMode="numeric" autoComplete="off" />
        </div>
      </div>

      <div className="account-form__row">
        <div className="field">
          <label htmlFor="acc-currency">Валюта</label>
          <select id="acc-currency" value={currency} onChange={(e) => setCurrency(e.target.value)}>
            {CURRENCIES.map((c) => (
              <option key={c} value={c}>
                {c === "KZT" ? "Тенге, KZT" : c}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor="acc-start">Дата старта</label>
          <input
            id="acc-start"
            type="date"
            min={accountingStartDate}
            value={startDate}
            onChange={(e) => setStartDate(e.target.value)}
            aria-describedby="acc-start-hint"
          />
        </div>
      </div>
      <p id="acc-start-hint" className="field__hint">
        Не раньше начала учёта, {formatDate(accountingStartDate)}. Потом её не поменять, и записей раньше неё не будет.
      </p>

      <fieldset className="opening">
        <legend>Остаток на дату старта</legend>
        {foreign ? (
          <p className="field__hint">
            Остаток валютного счёта пока можно завести только нулевым: тенговый эквивалент появится вместе с валютой.
          </p>
        ) : (
          <>
            <div className="account-form__row">
              <MoneyField id="acc-total" label="Всего на счёте" value={total} onChange={setTotal} />
              <MoneyField id="acc-company" label="Из них компании" side="company" value={company} onChange={setCompany} />
            </div>
            <OwnershipBar own={preview.kind === "ready" ? preview.own : 0} company={preview.kind === "ready" ? (companyMinor ?? 0) : 0} />
            <p className="opening__own" aria-live="polite">
              {preview.kind !== "error" && <span className="swatch swatch--own" aria-hidden="true" />}
              {preview.kind === "ready" && <>Свои деньги <span className="amount">{formatMoney(preview.own, "KZT")}</span></>}
              {preview.kind === "error" && <span className="error">{accountErrorText({ message: preview.code })}</span>}
              {preview.kind === "idle" && <span className="muted">Свои деньги появятся как разница</span>}
            </p>
          </>
        )}
      </fieldset>

      <div className="account-form__actions">
        <button className="button button--primary" type="submit" disabled={busy}>
          Добавить счёт
        </button>
        {failure && (
          <p className="error" role="alert">
            {failure}
          </p>
        )}
      </div>
    </form>
  );
}

type Preview = { kind: "idle" } | { kind: "ready"; own: number } | { kind: "error"; code: string };

/** «Свои = всего − компании» считает сервер (preview_account_opening), с паузой 300 мс. */
function useOpeningPreview(total: number | null, company: number | null, currency: string): Preview {
  const [preview, setPreview] = useState<Preview>({ kind: "idle" });
  useEffect(() => {
    if (total === null || company === null || (total === 0 && company === 0)) {
      setPreview({ kind: "idle" });
      return;
    }
    let live = true;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc("preview_account_opening", {
        p_total_minor: total,
        p_company_minor: company,
        p_currency: currency,
      });
      if (!live) return;
      if (error) setPreview({ kind: "error", code: error.message });
      else setPreview({ kind: "ready", own: (data as { own_minor: number }).own_minor });
    }, 300);
    return () => {
      live = false;
      window.clearTimeout(t);
    };
  }, [total, company, currency]);
  return preview;
}

function EditAccountForm({ account: a, onDone }: { account: AccountRow; onDone: (message: string) => void }) {
  const [name, setName] = useState(a.name);
  const [bank, setBank] = useState(a.bank ?? "");
  const [mask, setMask] = useState(a.mask ?? "");
  const [currency, setCurrency] = useState(a.currency);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  async function run(rpc: string, args: Record<string, unknown>, message: string) {
    setFailure(null);
    setBusy(true);
    const { error } = await supabase.rpc(rpc, args);
    setBusy(false);
    if (error) return setFailure(accountErrorText(error));
    onDone(message);
  }

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!name.trim()) return setFailure("Введите название счёта.");
    void run(
      "update_account",
      { p_account_id: a.account_id, p_name: name, p_bank: bank, p_mask: mask, p_currency: currency },
      "Счёт сохранён",
    );
  }

  return (
    <form className="account-form" onSubmit={submit} noValidate>
      <dl className="account-form__facts">
        <div>
          <dt className="muted">Остаток</dt>
          <dd className="amount">{formatMoney(a.balance_minor, a.currency)}</dd>
        </div>
        <div>
          <dt className="muted">Аванс</dt>
          <dd className="amount">{formatMoney(a.advance_minor, "KZT")}</dd>
        </div>
        <div>
          <dt className="muted">Учёт с</dt>
          <dd>{formatDate(a.start_date)}</dd>
        </div>
      </dl>

      <div className="field">
        <label htmlFor="acc-name">Название</label>
        <input id="acc-name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="off" />
      </div>
      <div className="account-form__row">
        {a.type !== "cash" && (
          <div className="field">
            <label htmlFor="acc-bank">Банк</label>
            <input id="acc-bank" value={bank} onChange={(e) => setBank(e.target.value)} autoComplete="off" />
          </div>
        )}
        <div className="field">
          <label htmlFor="acc-mask">Последние цифры</label>
          <input id="acc-mask" value={mask} onChange={(e) => setMask(e.target.value)} inputMode="numeric" autoComplete="off" />
        </div>
      </div>
      <div className="field">
        <label htmlFor="acc-currency">Валюта</label>
        <select
          id="acc-currency"
          value={currency}
          disabled={a.has_entries}
          onChange={(e) => setCurrency(e.target.value)}
          aria-describedby={a.has_entries ? "acc-currency-hint" : undefined}
        >
          {CURRENCIES.includes(a.currency) ? null : <option value={a.currency}>{a.currency}</option>}
          {CURRENCIES.map((c) => (
            <option key={c} value={c}>
              {c === "KZT" ? "Тенге, KZT" : c}
            </option>
          ))}
        </select>
        {a.has_entries && (
          <p id="acc-currency-hint" className="field__hint">
            По счёту есть записи, поэтому валюту не поменять.
          </p>
        )}
      </div>

      <div className="account-form__actions">
        <button className="button button--primary" type="submit" disabled={busy}>
          Сохранить
        </button>
        <div className="account-form__secondary">
          {a.is_archived ? (
            <button
              className="button"
              type="button"
              disabled={busy}
              onClick={() => void run("unarchive_account", { p_account_id: a.account_id }, "Счёт возвращён из архива")}
            >
              Вернуть из архива
            </button>
          ) : (
            <button
              className="button"
              type="button"
              disabled={busy}
              onClick={() => void run("archive_account", { p_account_id: a.account_id }, "Счёт в архиве")}
            >
              Архивировать
            </button>
          )}
          {!a.has_entries && (
            <button
              className="button button--danger"
              type="button"
              disabled={busy}
              onClick={() => void run("delete_account", { p_account_id: a.account_id }, "Счёт удалён")}
            >
              Удалить счёт
            </button>
          )}
        </div>
        {!a.is_archived && a.has_entries && (
          <p className="field__hint">
            Счёт с записями не удалить. В архив можно, когда остаток и аванс равны нулю.
          </p>
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

function MoneyField(props: {
  id: string;
  label: string;
  side?: "own" | "company";
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="field">
      <label htmlFor={props.id}>
        {props.side && <span className={`swatch swatch--${props.side}`} aria-hidden="true" />}
        {props.label}
      </label>
      <div className="money-input">
        <input
          id={props.id}
          type="text"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0"
          value={props.value}
          onChange={(e) => props.onChange(formatAmountInput(e.target.value))}
        />
        <span aria-hidden="true">₸</span>
      </div>
    </div>
  );
}

/** Тексты ошибок, где у счёта своя формулировка. */
function accountErrorText(error: { message?: string }): string {
  if (error.message === "entry_before_start") return "Дата старта счёта не может быть раньше начала учёта.";
  return errorText(error);
}

import { useEffect, useState, type FormEvent } from "react";
import { supabase } from "../supabase";
import { currencySign, formatAmountInput, formatMoney, minorToAmountInput, parseAmountInput } from "../money";
import { formatDate, todayInAlmaty } from "../dates";
import { errorText } from "../errors";
import { entryTitle, errorDetails, refundTooBigErrorText, type EntryRow, type EntryWarning } from "../entries";
import type { SaveResult } from "./EntryForm";
import { EffectPreview, useEntryPreview } from "./EntryPreview";

/** Трата, по которой записывается возврат покупки: то, что форма о ней показывает. */
export type RefundParent = {
  entry_id: string;
  title: string | null;
  category_name: string | null;
  account_name: string | null;
  occurred_on: string;
  amount_minor: number;
  /** Валюта траты: возврат покупки в ней же и по её курсу. */
  currency: string;
};

/** Трата из строки ленты: сама трата или трата возврата покупки (поля parent_* и унаследованные). */
export function refundParentOf(e: EntryRow): RefundParent | null {
  if (e.type === "expense")
    return {
      entry_id: e.entry_id,
      title: e.title,
      category_name: e.category_name,
      account_name: e.account_name,
      occurred_on: e.occurred_on,
      amount_minor: e.amount_minor,
      currency: e.currency,
    };
  if (e.type === "refund" && e.parent_entry_id && e.parent_occurred_on && e.parent_amount_minor !== null)
    return {
      entry_id: e.parent_entry_id,
      title: e.parent_title,
      category_name: e.category_name,
      account_name: e.account_name,
      occurred_on: e.parent_occurred_on,
      amount_minor: e.parent_amount_minor,
      currency: e.currency,
    };
  return null;
}

type Remaining = { parent_amount_minor: number; refunded_minor: number; remaining_minor: number };

/**
 * Возврат покупки (док 03, 4.8): по конкретной трате, на её счёт, полностью или частично.
 * Сколько ещё можно вернуть, говорит сервер (refund_remaining); как вернутся аванс и долг,
 * считает пересчёт. Клиент собирает сумму, дату и комментарий.
 */
export function RefundForm(props: {
  parent: RefundParent;
  refund?: EntryRow;
  onSaved: (result: SaveResult) => void;
}) {
  const { parent, refund } = props;
  const [amount, setAmount] = useState(refund ? minorToAmountInput(refund.amount_minor) : "");
  const [date, setDate] = useState(refund?.occurred_on ?? maxDate(parent.occurred_on));
  const [comment, setComment] = useState(refund?.comment ?? "");
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const [remaining, setRemaining] = useState<Remaining | null | "error">(null);

  useEffect(() => {
    let live = true;
    void (async () => {
      const { data, error } = await supabase.rpc("refund_remaining", {
        p_parent_entry_id: parent.entry_id,
        p_entry_id: refund?.entry_id ?? null,
      });
      if (live) setRemaining(error || !data ? "error" : (data as Remaining));
    })();
    return () => {
      live = false;
    };
  }, [parent.entry_id, refund?.entry_id]);

  const nothingLeft = remaining !== null && remaining !== "error" && remaining.remaining_minor === 0;

  /** Ввод → payload возврата покупки или что не так; тот же payload идёт в предпросмотр. */
  function build(): { payload: Record<string, unknown>; amountMinor: number } | string {
    const parsed = parseAmountInput(amount);
    if (!parsed.ok)
      return parsed.error === "empty" ? "Введите сумму." : "Введите сумму цифрами, копейки не больше двух знаков.";
    if (parsed.minor === 0) return "Сумма должна быть больше нуля.";
    if (!date) return "Выберите дату.";
    const payload = {
      type: "refund",
      occurred_on: date,
      amount_minor: parsed.minor,
      parent_entry_id: parent.entry_id,
      comment: comment.trim() || null,
      title: refund?.title ?? null,
    };
    return { payload, amountMinor: parsed.minor };
  }

  const draft = build();
  const preview = useEntryPreview(typeof draft === "string" ? null : draft.payload, refund?.entry_id);
  const isSelf = (d: Record<string, unknown>, amountMinor: number) =>
    d.entry_id === undefined ||
    (refund ? d.entry_id === refund.entry_id : d.occurred_on === date && d.amount_minor === amountMinor);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    const built = build();
    if (typeof built === "string") return setFailure(built);
    const { payload, amountMinor } = built;
    setBusy(true);
    const { data, error } = refund
      ? await supabase.rpc("update_entry", { p_entry_id: refund.entry_id, p_payload: payload })
      : await supabase.rpc("create_entry", { p_payload: payload });
    setBusy(false);
    if (error)
      return setFailure(refundErrorText(error, (d) => isSelf(d, amountMinor), parent.currency));
    props.onSaved({
      message: refund ? "Запись сохранена" : "Возврат покупки записан",
      warnings: ((data as { warnings?: EntryWarning[] }).warnings ?? []) as EntryWarning[],
    });
  }

  async function remove() {
    if (!refund) return;
    if (!confirmDelete) return setConfirmDelete(true);
    setFailure(null);
    setBusy(true);
    const { data, error } = await supabase.rpc("delete_entry", { p_entry_id: refund.entry_id });
    setBusy(false);
    if (error) return setFailure(errorText(error));
    props.onSaved({ message: "Запись удалена", warnings: ((data as { warnings?: EntryWarning[] }).warnings ?? []) });
  }

  return (
    <form className="account-form entry-form" onSubmit={submit} noValidate>
      <div className="refund-parent">
        <p className="refund-parent__title">
          {entryTitle({ type: "expense", title: parent.title, category_name: parent.category_name })}
          <span className="amount">{formatMoney(parent.amount_minor, parent.currency)}</span>
        </p>
        <p className="muted">
          Трата {formatDate(parent.occurred_on)}
          {parent.account_name && <>, деньги вернутся на «{parent.account_name}»</>}
        </p>
        {remaining === "error" ? (
          <p className="error" role="alert">
            Не получилось узнать, сколько ещё можно вернуть. Закройте и откройте форму снова.
          </p>
        ) : remaining === null ? (
          <p className="muted" aria-busy="true">
            Считаем, сколько ещё можно вернуть…
          </p>
        ) : (
          <p aria-live="polite">
            {nothingLeft ? (
              "По этой трате уже всё вернули."
            ) : (
              <>
                Можно вернуть до <span className="amount">{formatMoney(remaining.remaining_minor, parent.currency)}</span>
                {remaining.refunded_minor > 0 && (
                  <span className="muted">, уже вернули {formatMoney(remaining.refunded_minor, parent.currency)}</span>
                )}
                .
              </>
            )}
          </p>
        )}
      </div>

      <div className="field">
        <label htmlFor="refund-amount">Сколько вернули</label>
        <div className="money-input money-input--large">
          <input
            id="refund-amount"
            type="text"
            inputMode="decimal"
            autoComplete="off"
            placeholder="0"
            value={amount}
            onChange={(e) => setAmount(formatAmountInput(e.target.value))}
            autoFocus={!refund}
          />
          <span aria-hidden="true">{currencySign(parent.currency)}</span>
        </div>
        {remaining !== null && remaining !== "error" && !nothingLeft && (
          <button
            className="button button--quiet refund-all"
            type="button"
            onClick={() => setAmount(minorToAmountInput(remaining.remaining_minor))}
          >
            Вернули всё: {formatMoney(remaining.remaining_minor, parent.currency)}
          </button>
        )}
        <p className="field__hint">
          Возврат откатит трату пропорционально: аванс и долг с компанией вернутся в той же доле, что сумма.
          {parent.currency !== "KZT" &&
            " Тенговый эквивалент возврата считается по курсу траты; если банк вернул по другому курсу, разницу запишите корректировкой."}
        </p>
      </div>

      <div className="field">
        <label htmlFor="refund-date">Дата</label>
        <input id="refund-date" type="date" min={parent.occurred_on} value={date} onChange={(e) => setDate(e.target.value)} />
      </div>

      <div className="field">
        <label htmlFor="refund-comment">Комментарий</label>
        <textarea id="refund-comment" rows={2} value={comment} onChange={(e) => setComment(e.target.value)} />
      </div>

      <EffectPreview
        state={preview}
        errorText={(error) => refundErrorText(error, (d) => typeof draft !== "string" && isSelf(d, draft.amountMinor), parent.currency)}
      />

      <div className="account-form__actions">
        <button className="button button--primary" type="submit" disabled={busy || (nothingLeft && !refund)}>
          {refund ? "Сохранить" : "Записать возврат покупки"}
        </button>
        {refund && (
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

/** Дата нового возврата по умолчанию: сегодня, но не раньше траты. */
function maxDate(d: string): string {
  const today = todayInAlmaty();
  return today > d ? today : d;
}

/** Ошибка возврата; isSelf отличает конфликт на этом возврате от более позднего возврата той же траты. */
function refundErrorText(
  error: { message?: string; details?: string | null },
  isSelf: (d: Record<string, unknown>) => boolean,
  currency: string,
): string {
  const d = errorDetails(error);
  // Проверка до пересчёта (валютная трата, без entry_id) считает в валюте траты, пересчёт в тенге.
  if (error.message === "refund_too_big")
    return refundTooBigErrorText(d, isSelf(d), d.entry_id === undefined ? currency : "KZT");
  if (error.message === "refund_before_expense" && typeof d.parent_occurred_on === "string")
    return `Возврат покупки не может быть раньше траты, ${formatDate(d.parent_occurred_on)}.`;
  return errorText(error);
}

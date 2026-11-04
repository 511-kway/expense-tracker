import { useState, type FormEvent } from "react";
import { supabase } from "../supabase";
import { formatAmountInput, parseAmountInput } from "../money";
import { todayInAlmaty } from "../dates";
import { errorText } from "../errors";
import { OwnershipMark } from "./OwnershipMark";

/**
 * Мастер первого запуска (ADR-0008): дата начала учёта и стартовый долг двумя суммами.
 * Сервер сам заводит долговые корректировки и пересчитывает; клиент только собирает ввод.
 */
export function FirstRun({ onDone }: { onDone: () => void }) {
  const [startDate, setStartDate] = useState(todayInAlmaty);
  const [oweMe, setOweMe] = useState("");
  const [iOwe, setIOwe] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setFailure(null);
    const oweMeMinor = amountOrZero(oweMe);
    const iOweMinor = amountOrZero(iOwe);
    if (oweMeMinor === null || iOweMinor === null) {
      setFailure("Введите сумму цифрами, копейки не больше двух знаков.");
      return;
    }
    if (!startDate) {
      setFailure("Выберите дату начала учёта.");
      return;
    }
    setBusy(true);
    const { error } = await supabase.rpc("setup_start", {
      p_accounting_start_date: startDate,
      p_company_owes_me_minor: oweMeMinor,
      p_i_owe_company_minor: iOweMinor,
    });
    setBusy(false);
    // Дата уже задана (например, во второй вкладке): просто идём дальше.
    if (error && error.message !== "start_already_set") {
      setFailure(errorText(error));
      return;
    }
    onDone();
  }

  return (
    <main className="gate">
      <form className="gate__inner first-run" onSubmit={submit} noValidate>
        <OwnershipMark className="gate__mark" />
        <div className="gate__text">
          <h1>Начало учёта</h1>
          <p className="muted">
            С этого дня приложение ведёт ваши деньги и расчёт с компанией. Если долг с компанией уже есть, введите
            его как есть на эту дату.
          </p>
        </div>

        <div className="field">
          <label htmlFor="start-date">Дата начала учёта</label>
          <input
            id="start-date"
            type="date"
            required
            value={startDate}
            onChange={(e) => setStartDate(e.target.value)}
            aria-describedby="start-date-hint"
          />
          <p id="start-date-hint" className="field__hint">
            Потом её не поменять, и записей раньше неё не будет.
          </p>
        </div>

        <fieldset className="first-run__debt">
          <legend>Стартовый долг</legend>
          <AmountField id="owe-me" side="own" label="Компания должна мне" value={oweMe} onChange={setOweMe} />
          <AmountField id="i-owe" side="company" label="Я должен компании" value={iOwe} onChange={setIOwe} />
          <p className="field__hint">Нет долга — оставьте ноль.</p>
        </fieldset>

        <div className="gate__actions">
          <button className="button button--primary" type="submit" disabled={busy}>
            Начать учёт
          </button>
          {failure && (
            <p className="error" role="alert">
              {failure}
            </p>
          )}
        </div>
      </form>
    </main>
  );
}

function AmountField(props: {
  id: string;
  side: "own" | "company";
  label: string;
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="field">
      <label htmlFor={props.id}>
        <span className={`swatch swatch--${props.side}`} aria-hidden="true" />
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

/** Пустое поле = ноль; иначе тиыны или null при ошибке ввода. */
function amountOrZero(text: string): number | null {
  const parsed = parseAmountInput(text);
  if (parsed.ok) return parsed.minor;
  return parsed.error === "empty" ? 0 : null;
}

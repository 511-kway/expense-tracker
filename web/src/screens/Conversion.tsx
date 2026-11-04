import { useEffect, useState } from "react";
import { FunctionsHttpError } from "@supabase/supabase-js";
import { supabase } from "../supabase";
import { currencySign, formatAmountInput, formatMoney, formatRate, parseAmountInput } from "../money";
import { formatDate } from "../dates";
import { errorText } from "../errors";
import {
  CURRENCIES,
  CURRENCY_NAMES,
  RATE_METHODS,
  conversionFields,
  type ConversionInput,
  type RateMethod,
} from "../currency";

/** Выбор валюты рядом с суммой: у тенгового счёта любая, у валютного только его валюта. */
export function CurrencySelect(props: {
  id: string;
  value: string;
  onChange: (currency: string) => void;
  options?: string[];
  label?: string;
}) {
  const options = props.options ?? CURRENCIES;
  return (
    <select
      id={props.id}
      className="currency-select"
      aria-label={props.label ?? "Валюта"}
      value={props.value}
      disabled={options.length < 2}
      onChange={(e) => props.onChange(e.target.value)}
    >
      {(options.includes(props.value) ? options : [props.value, ...options]).map((c) => (
        <option key={c} value={c}>
          {currencySign(c) === c ? c : `${currencySign(c)} ${c}`}
        </option>
      ))}
    </select>
  );
}

export function currencyLabel(c: string): string {
  return CURRENCY_NAMES[c] ? `${CURRENCY_NAMES[c]}, ${c}` : c;
}

export type NbkState =
  | { state: "idle" | "pending" }
  | { state: "ready"; rate: string }
  | { state: "unavailable" | "not_found" | "failed" };

/**
 * Курс Нацбанка на дату: Edge Function fetch_rates (берёт из кэша или с nationalbank.kz и
 * кэширует), пауза 250 мс. Пока курс не в кэше, сохранение со способом «курс Нацбанка» не пройдёт.
 */
export function useNbkRate(active: boolean, currency: string, date: string): NbkState {
  const [state, setState] = useState<NbkState>({ state: "idle" });
  useEffect(() => {
    if (!active || currency === "KZT" || !date) return setState({ state: "idle" });
    setState({ state: "pending" });
    let live = true;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.functions.invoke("fetch_rates", { body: { date, currency } });
      if (!live) return;
      if (!error) return setState({ state: "ready", rate: (data as { rate: string }).rate });
      let code = "";
      if (error instanceof FunctionsHttpError) {
        try {
          code = ((await (error.context as Response).json()) as { error?: string }).error ?? "";
        } catch {
          code = "";
        }
      }
      if (!live) return;
      setState({
        state: code === "fx_rate_not_found" ? "not_found" : code === "fx_source_unavailable" || code === "" ? "unavailable" : "failed",
      });
    }, 250);
    return () => {
      live = false;
      window.clearTimeout(t);
    };
  }, [active, currency, date]);
  return state;
}

type Equivalent = { state: "idle" } | { state: "ready"; kzt: number; rate: string | number } | { state: "error"; text: string };

/** Тенговый эквивалент от сервера (convert_amount, то же округление, что при сохранении), пауза 250 мс. */
function useEquivalent(
  currency: string,
  amountMinor: number | null,
  date: string,
  input: ConversionInput,
  ready: boolean,
): Equivalent {
  const [state, setState] = useState<Equivalent>({ state: "idle" });
  const fields = conversionFields(currency, input);
  const key = typeof fields === "string" ? "" : JSON.stringify(fields);
  useEffect(() => {
    if (!ready || !amountMinor || !date || key === "") return setState({ state: "idle" });
    const f = JSON.parse(key) as { rate_source: RateMethod; rate?: string; amount_kzt_minor?: number };
    let live = true;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc("convert_amount", {
        p_currency: currency,
        p_amount_minor: amountMinor,
        p_occurred_on: date,
        p_rate_source: f.rate_source,
        p_rate: f.rate ?? null,
        p_amount_kzt_minor: f.amount_kzt_minor ?? null,
      });
      if (!live) return;
      if (error) setState({ state: "error", text: conversionErrorText(error) });
      else {
        const d = data as { amount_kzt_minor: number; rate: string | number };
        setState({ state: "ready", kzt: d.amount_kzt_minor, rate: d.rate });
      }
    }, 250);
    return () => {
      live = false;
      window.clearTimeout(t);
    };
  }, [currency, amountMinor, date, key, ready]);
  return state;
}

export function conversionErrorText(error: { message?: string }): string {
  if (error.message === "fx_rate_missing") return "Курса Нацбанка на эту дату нет. Введите свой курс или сумму в тенге.";
  if (error.message === "field_invalid") return "Курс должен быть больше нуля.";
  if (error.message === "amount_not_positive") return "В тенге получается ноль: проверьте сумму и курс.";
  return errorText(error);
}

/**
 * Блок пересчёта (док 04, 4.2): для суммы не в тенге способ получить тенговый эквивалент: курс
 * Нацбанка на дату (по умолчанию), свой курс или сумма в тенге. Аванс и долг считаются по
 * эквиваленту. Если Нацбанк недоступен, блок предлагает ввести курс или сумму руками.
 */
export function ConversionBlock(props: {
  idPrefix: string;
  currency: string;
  amount: string;
  date: string;
  value: ConversionInput;
  onChange: (value: ConversionInput) => void;
  /** Что эквивалент делает: «Спишется», «Придёт», «Остаток в тенге». */
  verb?: string;
  /** Курс Нацбанка, если форма уже спрашивает его сама (чтобы предпросмотр ждал кэша). */
  nbk?: NbkState;
}) {
  const { currency, value, idPrefix } = props;
  const parsed = parseAmountInput(props.amount);
  const amountMinor = parsed.ok && parsed.minor > 0 ? parsed.minor : null;
  const own = useNbkRate(value.method === "nbk" && !props.nbk, currency, props.date);
  const nbk = props.nbk ?? own;
  const equivalent = useEquivalent(currency, amountMinor, props.date, value, value.method !== "nbk" || nbk.state === "ready");
  const set = (patch: Partial<ConversionInput>) => props.onChange({ ...value, ...patch });
  const sign = currencySign(currency);
  const unit = sign === "$" ? "$1" : `1 ${sign}`;

  return (
    <fieldset className="conversion">
      <legend>В тенге</legend>
      <div className="choice__options choice__options--three">
        {(Object.keys(RATE_METHODS) as RateMethod[]).map((m) => (
          <label key={m} className="choice__option">
            <input type="radio" name={`${idPrefix}-rate-method`} checked={value.method === m} onChange={() => set({ method: m })} />
            <span>{RATE_METHODS[m]}</span>
          </label>
        ))}
      </div>

      {value.method === "nbk" && (
        <p className="field__hint" aria-live="polite">
          {nbk.state === "pending" && "Спрашиваем курс у Нацбанка…"}
          {nbk.state === "ready" && (
            <>
              Курс Нацбанка на {formatDate(props.date)}: <span className="amount">{formatRate(nbk.rate)} ₸</span> за {unit}.
            </>
          )}
          {(nbk.state === "unavailable" || nbk.state === "failed") && (
            <span className="conversion__problem">
              Курс Нацбанка сейчас недоступен.{" "}
              <button className="link-button" type="button" onClick={() => set({ method: "manual" })}>
                Ввести свой курс
              </button>{" "}
              или{" "}
              <button className="link-button" type="button" onClick={() => set({ method: "derived" })}>
                сумму в тенге
              </button>
              .
            </span>
          )}
          {nbk.state === "not_found" && (
            <span className="conversion__problem">
              У Нацбанка нет курса {currency} на эту дату.{" "}
              <button className="link-button" type="button" onClick={() => set({ method: "manual" })}>
                Ввести свой курс
              </button>
              .
            </span>
          )}
        </p>
      )}

      {value.method === "manual" && (
        <div className="field">
          <label htmlFor={`${idPrefix}-rate`}>Курс, ₸ за {unit}</label>
          <div className="money-input">
            <input
              id={`${idPrefix}-rate`}
              type="text"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0"
              value={value.rate}
              onChange={(e) => set({ rate: e.target.value.replace(/[^\d.,\s]/g, "") })}
            />
            <span aria-hidden="true">₸</span>
          </div>
        </div>
      )}

      {value.method === "derived" && (
        <div className="field">
          <label htmlFor={`${idPrefix}-kzt`}>Сумма в тенге</label>
          <div className="money-input">
            <input
              id={`${idPrefix}-kzt`}
              type="text"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0"
              value={value.kzt}
              onChange={(e) => set({ kzt: formatAmountInput(e.target.value) })}
            />
            <span aria-hidden="true">₸</span>
          </div>
        </div>
      )}

      <p className="conversion__result" aria-live="polite">
        {equivalent.state === "ready" && (
          <>
            {props.verb ?? "В тенге"} <span className="amount">{formatMoney(equivalent.kzt, "KZT")}</span>
            {value.method === "derived" && (
              <span className="muted">
                {" "}
                по курсу {formatRate(equivalent.rate)} ₸ за {unit}
              </span>
            )}
          </>
        )}
        {equivalent.state === "error" && <span className="error">{equivalent.text}</span>}
        {equivalent.state === "idle" && <span className="muted">Тенговый эквивалент появится, когда будут сумма и курс</span>}
      </p>
    </fieldset>
  );
}

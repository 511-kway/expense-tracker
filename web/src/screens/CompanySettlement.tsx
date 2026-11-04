import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { formatMoney } from "../money";
import { formatDate } from "../dates";
import {
  BREAKDOWN_COLUMNS,
  ENTRY_COLUMNS,
  breakdownLabel,
  formatSigned,
  type BreakdownRow,
  type DebtSide,
  type EntryRow,
} from "../entries";
import { EDITABLE, EntryItem } from "./Entries";

type Settlement = { company_owes_me_minor: number; i_owe_company_minor: number; net_minor: number };

type Data = { settlement: Settlement; breakdown: BreakdownRow[]; repayments: EntryRow[] };

type State = { kind: "loading" } | { kind: "error" } | { kind: "ready"; data: Data };

const SIDE_TITLES: Record<DebtSide, string> = {
  i_owe_company: "Я должен компании",
  company_owes_me: "Компания должна мне",
};

/**
 * «Расчёт с компанией»: обе стороны долга и итог (v_company_settlement), каждая сторона
 * раскрывается до записей, из которых сложилась (v_settlement_breakdown), ниже отдельный список
 * погашений долга и взаимозачётов (v_entries). Строки разбора открывают запись на правку
 * (корректировки долга правятся только отсюда и из ленты). Все числа с сервера, клиент только показывает.
 * Стороны показаны встречными полосами от центра (docs/design.md), итог над ними.
 */
export function CompanySettlement({
  accountingStartDate,
  onEdit,
}: {
  accountingStartDate: string;
  onEdit: (entry: EntryRow) => void;
}) {
  const [state, setState] = useState<State>({ kind: "loading" });
  const [open, setOpen] = useState<Record<DebtSide, boolean>>({ i_owe_company: false, company_owes_me: false });
  const [openFailed, setOpenFailed] = useState(false);

  useEffect(() => {
    let live = true;
    void (async () => {
      const [s, b, r] = await Promise.all([
        supabase.from("v_company_settlement").select("company_owes_me_minor, i_owe_company_minor, net_minor").single(),
        supabase
          .from("v_settlement_breakdown")
          .select(BREAKDOWN_COLUMNS)
          .order("occurred_on")
          .order("occurred_at", { nullsFirst: false })
          .order("created_at")
          .order("seq"),
        supabase
          .from("v_entries")
          .select(ENTRY_COLUMNS)
          .or("type.in.(settlement,netting),transfer_purpose.eq.repay_debt")
          .order("occurred_on", { ascending: false })
          .order("created_at", { ascending: false })
          .order("seq", { ascending: false }),
      ]);
      if (!live) return;
      if (s.error || b.error || r.error || !s.data) return setState({ kind: "error" });
      setState({
        kind: "ready",
        data: {
          settlement: s.data as Settlement,
          breakdown: b.data as unknown as BreakdownRow[],
          repayments: r.data as unknown as EntryRow[],
        },
      });
    })();
    return () => {
      live = false;
    };
  }, []);

  if (state.kind === "loading") return <p className="muted" aria-busy="true">Загружаем расчёт…</p>;
  if (state.kind === "error")
    return (
      <p className="error" role="alert">
        Не получилось загрузить расчёт с компанией. Обновите страницу.
      </p>
    );

  const { settlement, breakdown, repayments } = state.data;
  const { company_owes_me_minor: oweMe, i_owe_company_minor: iOwe, net_minor: net } = settlement;
  // Длина полос только для картинки: доля от большей стороны. Суммы приходят с сервера.
  const scale = Math.max(oweMe, iOwe);
  const share = (v: number) => (scale === 0 ? 0 : Math.max(v / scale, v > 0 ? 0.02 : 0));
  const rowsOf = (side: DebtSide) => breakdown.filter((r) => r.side === side);
  const toggle = (side: DebtSide) => setOpen((o) => ({ ...o, [side]: !o[side] }));
  // Строка разбора открывает запись на правку: полную строку ленты берём по id.
  async function openEntry(entryId: string) {
    setOpenFailed(false);
    const { data, error } = await supabase.from("v_entries").select(ENTRY_COLUMNS).eq("entry_id", entryId).single();
    if (error || !data) return setOpenFailed(true);
    onEdit(data as unknown as EntryRow);
  }

  return (
    <div className="settlement">
      <div className="settlement__net">
        <p className="muted">Итог с компанией</p>
        <p className={`settlement__total amount${net < 0 ? " is-negative" : ""}`}>
          <BigMoney minor={net} />
        </p>
        <p className="muted">{netSentence(net)}</p>
      </div>

      <div className="debt-bars" aria-hidden="true">
        <div className="debt-bars__half debt-bars__half--company">
          <span style={{ width: `${share(iOwe) * 100}%` }} />
        </div>
        <div className="debt-bars__half debt-bars__half--own">
          <span style={{ width: `${share(oweMe) * 100}%` }} />
        </div>
      </div>

      <dl className="debt-sides">
        {(["i_owe_company", "company_owes_me"] as const).map((side) => (
          <div key={side} className={`debt-sides__side debt-sides__side--${side === "i_owe_company" ? "company" : "own"}`}>
            <dt>
              <span className={`swatch swatch--${side === "i_owe_company" ? "company" : "own"}`} aria-hidden="true" />
              {SIDE_TITLES[side]}
            </dt>
            <dd className="amount">{formatMoney(side === "i_owe_company" ? iOwe : oweMe, "KZT")}</dd>
            <dd>
              <button
                className="button button--quiet debt-sides__toggle"
                type="button"
                aria-expanded={open[side]}
                aria-controls={`breakdown-${side}`}
                disabled={rowsOf(side).length === 0}
                onClick={() => toggle(side)}
              >
                {rowsOf(side).length === 0 ? "Записей нет" : open[side] ? "Свернуть" : "Из чего сложилось"}
              </button>
            </dd>
          </div>
        ))}
      </dl>

      {(["i_owe_company", "company_owes_me"] as const).map(
        (side) =>
          open[side] && (
            <section
              key={side}
              id={`breakdown-${side}`}
              className={`breakdown breakdown--${side === "i_owe_company" ? "company" : "own"}`}
              aria-label={`${SIDE_TITLES[side]}: из чего сложилось`}
            >
              <h2 className="breakdown__title">
                <span className={`swatch swatch--${side === "i_owe_company" ? "company" : "own"}`} aria-hidden="true" />
                {SIDE_TITLES[side]}: из чего сложилось
              </h2>
              <ol className="breakdown__list">
                {rowsOf(side).map((r) => {
                  const row = (
                    <>
                      <span className="breakdown__date muted">{formatDate(r.occurred_on)}</span>
                      <span className="breakdown__label">{breakdownLabel(r)}</span>
                      <span className="breakdown__delta amount">{formatSigned(r.delta_minor, "KZT")}</span>
                      <span className="breakdown__after muted">
                        стало <span className="amount">{formatMoney(r.side_after_minor, "KZT")}</span>
                      </span>
                    </>
                  );
                  return (
                    <li key={r.entry_id}>
                      {EDITABLE.has(r.type) ? (
                        <button
                          className="breakdown__row"
                          type="button"
                          aria-label={`${breakdownLabel(r)}, ${formatDate(r.occurred_on)}: изменить запись`}
                          onClick={() => void openEntry(r.entry_id)}
                        >
                          {row}
                        </button>
                      ) : (
                        <div className="breakdown__row">{row}</div>
                      )}
                    </li>
                  );
                })}
              </ol>
            </section>
          ),
      )}

      {openFailed && (
        <p className="error" role="alert">
          Не получилось открыть запись. Обновите страницу и попробуйте ещё раз.
        </p>
      )}

      <section className="repayments" aria-labelledby="repayments-title">
        <h2 id="repayments-title" className="repayments__title">
          Погашения и взаимозачёты
        </h2>
        {repayments.length === 0 ? (
          <p className="muted">
            Погашений долга и взаимозачётов пока нет. Их записывают через «Записать»: «Погашение долга», если деньги прошли
            через счёт, или «Взаимозачёт», если стороны закрыли встречно.
          </p>
        ) : (
          <ul className="feed__list">
            {repayments.map((r) => (
              <li key={r.entry_id}>
                <EntryItem entry={r} onEdit={EDITABLE.has(r.type) ? () => onEdit(r) : undefined} />
              </li>
            ))}
          </ul>
        )}
      </section>

      <p className="settlement__since muted">Учёт ведётся с {formatDate(accountingStartDate)}.</p>
    </div>
  );
}

function netSentence(net: number): string {
  if (net > 0) return `Если закрыть всё встречно, компания должна вам ${formatMoney(net, "KZT")}.`;
  if (net < 0) return `Если закрыть всё встречно, вы должны компании ${formatMoney(-net, "KZT")}.`;
  return "Вы с компанией в расчёте.";
}

/** Крупная сумма: знак валюты на ступень меньше и тоньше (docs/design.md). */
function BigMoney({ minor }: { minor: number }) {
  const text = formatMoney(minor, "KZT");
  const sign = " ₸";
  if (!text.endsWith(sign)) return <>{text}</>;
  return (
    <>
      {text.slice(0, -sign.length)}
      <span className="currency">{sign}</span>
    </>
  );
}

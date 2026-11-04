import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { formatMoney } from "../money";
import { formatDate } from "../dates";

type Settlement = { company_owes_me_minor: number; i_owe_company_minor: number; net_minor: number };

type State = { kind: "loading" } | { kind: "error" } | { kind: "ready"; data: Settlement };

/**
 * «Расчёт с компанией»: обе стороны долга и итог, всё из выборки v_company_settlement.
 * Стороны показаны встречными полосами от центра (docs/design.md), итог над ними.
 */
export function CompanySettlement({ accountingStartDate }: { accountingStartDate: string }) {
  const [state, setState] = useState<State>({ kind: "loading" });

  useEffect(() => {
    let live = true;
    void supabase
      .from("v_company_settlement")
      .select("company_owes_me_minor, i_owe_company_minor, net_minor")
      .single()
      .then(({ data, error }) => {
        if (!live) return;
        setState(error || !data ? { kind: "error" } : { kind: "ready", data: data as Settlement });
      });
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

  const { company_owes_me_minor: oweMe, i_owe_company_minor: iOwe, net_minor: net } = state.data;
  // Длина полос только для картинки: доля от большей стороны. Суммы приходят с сервера.
  const scale = Math.max(oweMe, iOwe);
  const share = (v: number) => (scale === 0 ? 0 : Math.max(v / scale, v > 0 ? 0.02 : 0));

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
        <div className="debt-sides__side debt-sides__side--company">
          <dt>
            <span className="swatch swatch--company" aria-hidden="true" />Я должен компании
          </dt>
          <dd className="amount">{formatMoney(iOwe, "KZT")}</dd>
        </div>
        <div className="debt-sides__side debt-sides__side--own">
          <dt>
            <span className="swatch swatch--own" aria-hidden="true" />Компания должна мне
          </dt>
          <dd className="amount">{formatMoney(oweMe, "KZT")}</dd>
        </div>
      </dl>

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
  const sign = "\u00A0₸";
  if (!text.endsWith(sign)) return <>{text}</>;
  return (
    <>
      {text.slice(0, -sign.length)}
      <span className="currency">{sign}</span>
    </>
  );
}

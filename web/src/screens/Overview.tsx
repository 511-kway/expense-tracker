import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { formatMoney } from "../money";
import { formatDate, todayInAlmaty } from "../dates";
import { presetPeriod, type PeriodPreset } from "../exportPeriod";
import { debtDirection, formatRate } from "../overview";
import { OwnershipBar } from "./Accounts";
import { BigMoney } from "./BigMoney";

type OverviewAccount = {
  account_id: string;
  name: string;
  type: "card" | "bank_account" | "cash";
  bank: string | null;
  mask: string | null;
  currency: string;
  balance_minor: number;
  advance_minor: number;
  own_minor: number;
  /** Остаток в тенге; у валютного по курсу rate на rate_date, null = курса в кэше нет. */
  balance_kzt_minor: number | null;
  rate: string | null;
  rate_date: string | null;
};

/** Ответ RPC overview (supabase/migrations/20261119120000_overview.sql). Все суммы считает сервер. */
type OverviewData = {
  total_balance_minor: number;
  total_own_minor: number;
  total_company_advance_minor: number;
  company_owes_me_minor: number;
  i_owe_company_minor: number;
  net_minor: number;
  personal: {
    from: string | null;
    to: string | null;
    expenses_minor: number;
    adjustments_minor: number;
    refunds_minor: number;
    spent_minor: number;
  };
  accounts: OverviewAccount[];
  unconverted: { account_id: string; name: string; currency: string; balance_minor: number }[];
  inbox_items: number;
};

type Preset = Exclude<PeriodPreset, "all">;

const PRESETS: Preset[] = ["month", "last_month", "year"];

/** Подпись периода коротко и конкретно: «Ноябрь», «Октябрь», «2026». */
function presetLabel(preset: Preset, today: string): string {
  const from = presetPeriod(preset, today).from!;
  if (preset === "year") return from.slice(0, 4);
  const [y, m] = from.split("-").map(Number);
  const month = new Intl.DateTimeFormat("ru-RU", { month: "long", timeZone: "UTC" }).format(new Date(Date.UTC(y!, m! - 1, 1)));
  return month.charAt(0).toUpperCase() + month.slice(1);
}

/**
 * Обзор, главный экран (spec.md, история 90; docs/design.md): всего денег с полосой
 * принадлежности (свои и деньги компании), итог с компанией словами, личные траты за период
 * и строки счетов. Одна RPC `overview(p_from, p_to)`, клиент только показывает.
 */
export function Overview() {
  const [preset, setPreset] = useState<Preset>("month");
  const [data, setData] = useState<OverviewData | null | "error">(null);
  const [loadingPeriod, setLoadingPeriod] = useState(false);

  useEffect(() => {
    let live = true;
    const period = presetPeriod(preset, todayInAlmaty());
    setLoadingPeriod(true);
    void (async () => {
      const { data: d, error } = await supabase.rpc("overview", { p_from: period.from, p_to: period.to });
      if (!live) return;
      setLoadingPeriod(false);
      setData(error || !d ? "error" : (d as OverviewData));
    })();
    return () => {
      live = false;
    };
  }, [preset]);

  if (data === null) return <p className="muted" aria-busy="true">Считаем обзор…</p>;
  if (data === "error")
    return (
      <p className="error" role="alert">
        Не получилось загрузить обзор. Обновите страницу.
      </p>
    );

  const net = data.net_minor;
  const today = todayInAlmaty();
  const spent = data.personal;

  return (
    <div className="overview">
      <section className="overview__total" aria-labelledby="overview-total">
        <h2 id="overview-total" className="overview__label">
          Всего денег
        </h2>
        <p className={`overview__big amount${data.total_balance_minor < 0 ? " is-negative" : ""}`}>
          <BigMoney minor={data.total_balance_minor} />
        </p>
        <OwnershipBar own={data.total_own_minor} company={data.total_company_advance_minor} hero />
        <dl className="overview__parts">
          <div>
            <dt>
              <span className="swatch swatch--own" aria-hidden="true" />
              Свои деньги
            </dt>
            <dd className={`amount${data.total_own_minor < 0 ? " is-negative" : ""}`}>
              {formatMoney(data.total_own_minor, "KZT")}
            </dd>
          </div>
          <div>
            <dt>
              <span className="swatch swatch--company" aria-hidden="true" />
              Деньги компании
            </dt>
            <dd className="amount">{formatMoney(data.total_company_advance_minor, "KZT")}</dd>
          </div>
        </dl>
        {data.unconverted.length > 0 && (
          <p className="overview__note muted">
            Не вошло в итог, нет курса Нацбанка:{" "}
            {data.unconverted.map((u) => `${u.name} ${formatMoney(u.balance_minor, u.currency)}`).join(", ")}. Курс
            появится, когда запишете операцию в этой валюте по курсу Нацбанка.
          </p>
        )}
      </section>

      {data.inbox_items > 0 && (
        <a className="overview__nudge" href="#/inbox">
          <span className="badge">{data.inbox_items}</span>
          <span>Ждут разбора в инбоксе</span>
          <span className="overview__nudge-action">Разобрать</span>
        </a>
      )}

      <section className="overview__block" aria-labelledby="overview-company">
        <h2 id="overview-company" className="overview__label">
          Итог с компанией
        </h2>
        <p className={`overview__direction overview__direction--${net > 0 ? "own" : net < 0 ? "company" : "even"}`}>
          {debtDirection(net)}
        </p>
        <p className="overview__sides muted">
          Компания должна мне <span className="amount">{formatMoney(data.company_owes_me_minor, "KZT")}</span>, я должен
          компании <span className="amount">{formatMoney(data.i_owe_company_minor, "KZT")}</span>.{" "}
          <a href="#/company">Из чего сложилось</a>
        </p>
      </section>

      <section className="overview__block" aria-labelledby="overview-spent" aria-busy={loadingPeriod}>
        <div className="overview__spent-head">
          <h2 id="overview-spent" className="overview__label">
            Личные траты
          </h2>
          <fieldset className="choice overview__periods">
            <legend className="visually-hidden">Период</legend>
            <div className="choice__options">
              {PRESETS.map((p) => (
                <label key={p} className="choice__option">
                  <input type="radio" name="overview-period" checked={preset === p} onChange={() => setPreset(p)} />
                  <span>{presetLabel(p, today)}</span>
                </label>
              ))}
            </div>
          </fieldset>
        </div>
        <p className={`overview__spent amount${spent.spent_minor < 0 ? " is-negative" : ""}`}>
          {formatMoney(spent.spent_minor, "KZT")}
        </p>
        <p className="muted overview__period">
          {spent.from && spent.to ? `с ${formatDate(spent.from)} по ${formatDate(spent.to)}` : ""}
          {(spent.refunds_minor > 0 || spent.adjustments_minor > 0) && (
            <>
              {": "}
              траты {formatMoney(spent.expenses_minor, "KZT")}
              {spent.adjustments_minor > 0 && <>, корректировки {formatMoney(spent.adjustments_minor, "KZT")}</>}
              {spent.refunds_minor > 0 && <>, возвраты покупок −{formatMoney(spent.refunds_minor, "KZT")}</>}
            </>
          )}
        </p>
      </section>

      <section className="overview__block" aria-labelledby="overview-accounts">
        <h2 id="overview-accounts" className="overview__label">
          По счетам
        </h2>
        {data.accounts.length === 0 ? (
          <p className="empty">
            Счетов пока нет. <a href="#/accounts">Добавьте первый счёт</a>, и здесь появятся остаток, свои деньги и
            аванс.
          </p>
        ) : (
          <ul className="accounts">
            {data.accounts.map((a) => (
              <li key={a.account_id}>
                <a className="account" href="#/accounts">
                  <span className="account__head">
                    <span className="account__name">{a.name}</span>
                    <span className={`account__balance amount${a.balance_minor < 0 ? " is-negative" : ""}`}>
                      {formatMoney(a.balance_minor, a.currency)}
                    </span>
                  </span>
                  {a.currency !== "KZT" && (
                    <span className="account__meta muted">
                      {a.balance_kzt_minor !== null && a.rate && a.rate_date
                        ? `≈ ${formatMoney(a.balance_kzt_minor, "KZT")} по курсу Нацбанка ${formatRate(a.rate)} на ${formatDate(a.rate_date)}`
                        : "Курса Нацбанка нет, в итог не входит"}
                    </span>
                  )}
                  <OwnershipBar own={a.own_minor} company={a.advance_minor} />
                  <span className="account__parts">
                    <span>
                      <span className="swatch swatch--own" aria-hidden="true" />
                      Свои{" "}
                      <span className={`amount${a.own_minor < 0 ? " is-negative" : ""}`}>
                        {formatMoney(a.own_minor, a.currency)}
                      </span>
                    </span>
                    {a.currency === "KZT" && (
                      <span>
                        <span className="swatch swatch--company" aria-hidden="true" />
                        Аванс <span className="amount">{formatMoney(a.advance_minor, "KZT")}</span>
                      </span>
                    )}
                  </span>
                </a>
              </li>
            ))}
          </ul>
        )}
      </section>

    </div>
  );
}

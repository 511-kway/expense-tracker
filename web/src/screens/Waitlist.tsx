import { OwnershipMark } from "./OwnershipMark";

export function Waitlist({ onBack }: { onBack: () => void }) {
  return (
    <main className="gate">
      <div className="gate__inner">
        <OwnershipMark className="gate__mark" />
        <div className="gate__text">
          <h1>Добавили вас в лист ожидания</h1>
          <p className="muted">
            Это личное приложение, доступ открывает владелец. Ваша попытка входа записана. Когда доступ откроют,
            войдите снова тем же аккаунтом.
          </p>
        </div>
        <div className="gate__actions">
          <button className="button" type="button" onClick={onBack}>
            Вернуться ко входу
          </button>
        </div>
      </div>
    </main>
  );
}

# Ночные бэкапы базы и Storage

Status: needs-triage
Type: task

Не в MVP, сделать после деплоя на VPS.

- Каждую ночь `pg_dump` базы плюс архив Storage.
- Шифрование (age или gpg), отправка за пределы VPS (вариант: rclone в Google Drive).
- Хранить 30 дней.
- Раз в месяц пробное восстановление на чистую базу.

## Comments

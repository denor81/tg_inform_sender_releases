# Notification Sender releases

## Быстрая установка

Для установки последней стабильной версии выполните одну команду:

```bash
curl -fsSL https://raw.githubusercontent.com/denor81/tg_inform_sender_releases/main/install.sh | sudo bash
```

GitHub token не нужен. Bootstrap автоматически скачает последний stable-релиз,
проверит его GitHub/Sigstore attestations, manifest, SHA-256 и содержимое архива
и только после этого запустит установщик.
Публично устанавливаемый формат начинается с `v0.3.1-rc.1`; более ранний `v0.3.0`
остаётся обновляемым, но его bundle ещё не содержал bootstrap installer.

Для последующих обновлений установленного Sender используйте:

```bash
sudo notify-sender update apply
```

## Расширенная инструкция

Более осторожный вариант сохраняет bootstrap в файл: его можно предварительно
просмотреть, вывести список релизов и только затем запустить от root.

```bash
curl --fail --silent --show-error --location \
  --output /tmp/install-notification-sender.sh \
  https://raw.githubusercontent.com/denor81/tg_inform_sender_releases/main/install.sh
chmod 0755 /tmp/install-notification-sender.sh
/tmp/install-notification-sender.sh --list
sudo /tmp/install-notification-sender.sh
```

По умолчанию устанавливается последний stable-релиз. Можно выбрать точную
стабильную версию или явно разрешить release candidate:

```bash
sudo /tmp/install-notification-sender.sh --version v0.3.1
sudo /tmp/install-notification-sender.sh --channel rc
sudo /tmp/install-notification-sender.sh --version v0.3.0-rc.2
```

Bootstrap скачивает checksum-pinned GitHub CLI verifier, проверяет GitHub
Artifact Attestation манифеста до доверия указанному в нём digest, затем digest
и attestation архива и каждый archive entry по strict manifest. Release-код не
запускается до завершения всех проверок.

Если Sender уже установлен в A/B layout, public bootstrap намеренно не обходит
транзакционный updater:

```bash
sudo notify-sender update check
sudo notify-sender update status
```

## Удаление

Показать план, удалить только программу с сохранением данных или выполнить
полное необратимое удаление:

```bash
sudo notify-sender uninstall --dry-run
sudo notify-sender uninstall
sudo notify-sender uninstall --purge-all
```

Обычное удаление сохраняет конфигурацию, базу, очередь, credentials и системного
пользователя для безопасной повторной установки. `--purge-all` дополнительно
удаляет их и требует ввести точное подтверждение `DELETE notification-sender`.
Ubuntu packages, journald и конфигурация Hub не удаляются.

## О репозитории

Это отдельный публичный binary release repository
`denor81/tg_inform_sender_releases`. Он содержит только минимальный README,
bootstrap, защищённый attestation workflow, immutable release artifacts, strict
manifests и GitHub Artifact Attestation bundles. Здесь никогда не должны
появляться Hub URL, Sender token, credentials, базы данных, логи, уведомления или
история приватных исходников.

Canonical-копии публичных файлов поддерживаются в приватном исходном
репозитории: `release-channel/README.md`, `release-channel/install.sh` и
`release-channel/attest-release.yml`. Последний копируется в публичный путь
`.github/workflows/attest-release.yml`.

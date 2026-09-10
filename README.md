# whiteLIST for iOS

Нативная iOS-оболочка для [OpenFlux](https://github.com/p1neappleXpress/OpenFlux). Приложение использует `NEPacketTunnelProvider`, а не локальный SOCKS-прокси, поэтому кнопка управляет системным VPN-подключением.

## Сборка IPA через GitHub

1. Откройте вкладку **Actions**.
2. Выберите **Build whiteLIST iOS IPA** → **Run workflow**.
3. Скачайте артефакт `whiteLIST-iOS` и распакуйте `whiteLIST-unsigned.ipa`.
4. Подпишите IPA через Sideloadly.

Подпись должна сохранить entitlement `com.apple.developer.networking.networkextension` со значением `packet-tunnel-provider`. Без разрешённого Apple provisioning profile iOS не запустит VPN-расширение.

## Использование

При первом запуске откройте **Настройка** и один раз укажите:

- ссылку на Yandex Docs; или
- MAX token и UID аккаунта выходного узла.

Конфигурация сохраняется в системных настройках VPN. В следующих запусках достаточно нажать **Подключить**.

Статус **Работает** появляется только когда одновременно выполнены три условия:

1. iOS запустила VPN;
2. транспорт OpenFlux установил соединение;
3. контрольный HTTPS-запрос прошёл через туннель и счётчики входящего трафика выросли.

Для работы всё равно требуется запущенный Linux exit node. Клиент не может автоматически угадать ссылку или UID чужого выходного узла.

## Разработка

```bash
go test ./...
```

GitHub Actions собирает arm64-приложение и вложенное Packet Tunnel extension на macOS runner, добавляет ad-hoc подпись с entitlements и упаковывает IPA для последующей переподписи.

OpenFlux распространяется по GPL-3.0-or-later; исходные уведомления и лицензии сохранены.

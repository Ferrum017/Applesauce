# Dead Space Legacy — iPad mini 3, iOS 12.5.7, Chimera

Это экспериментальный ARM64-host для запуска расшифрованного 32-битного Dead Space IPA через HyperHLE/Dynarmic. Android APK не требуется.

## Что изменено

- deployment target снижен до iOS 12.0;
- SwiftUI-host заменён на UIKit/Objective-C, доступный в iOS 12;
- удалён обязательный Scene API из iOS 13;
- добавлен launch storyboard и полноэкранный режим для правильного разрешения на iPad;
- CoreHaptics подключается слабо и не мешает запуску на iOS 12;
- добавлена ad-hoc подпись для Chimera/AppSync Unified с постоянным JIT;
- game IPA не включается в сборку и импортируется пользователем после установки.

## Сборка с Windows через GitHub Actions

Для самой компиляции нужен macOS/Xcode. Workflow `.github/workflows/build-ios12-chimera.yml` выполняет её на macOS runner и публикует только emulator-host без игры.

1. Создать собственный GitHub-репозиторий и отправить в него этот каталог вместе с submodule-ссылками.
2. Открыть вкладку **Actions** → **Build Dead Space Legacy for iOS 12** → **Run workflow**.
3. После успешной сборки скачать artifact `DeadSpaceLegacy-iOS12-Chimera`.
4. Установить `DeadSpaceLegacy-iOS12-Chimera.ipa` через AppSync/Filza или `appinst`.

## Установка игры

1. Запустить **Dead Space Legacy**.
2. Нажать **Импортировать IPA** и выбрать `Dead_Space__1.0.3_ios_3.0.ipa`.
3. Если системный document picker iOS 12 не видит файл, скопировать IPA через Filza в:

   `/var/mobile/Containers/Data/Application/<DeadSpaceLegacy container>/Documents/touchHLE_apps/`

4. Перезапустить host и нажать **Запустить Dead Space**.

Диагностика записывается в `Documents/touchhle-host.log`; предыдущий запуск сохраняется в `Documents/touchhle-host-previous.log`.

## Ожидаемые ограничения

- предоставленный IPA показывает маркетинговую версию 1.0.3, но его внутренний
  `CFBundleVersion` — 1.3.8, а идентификатор — `com.ea.deadspace.inc`;
- в отчёте touchHLE от 15 июня 2026 эта версия доходила до логотипа EA и
  чёрного экрана. В используемом здесь ядре от 13 сентября 2026 уже есть
  отдельные исправления запуска Dead Space, а touchHLE 0.3.0 от 1 октября 2026
  перечисляет Dead Space среди новых поддерживаемых игр. Поэтому результат
  может быть лучше, но полное прохождение именно версии 1.3.8 не подтверждено;
- производительность Dynarmic на Apple A7 и 1 ГБ RAM ещё не проверена;
- возможны отсутствующие framework-функции, проблемы OpenGL ES, звука или управления;
- это первая тестовая сборка, а не готовый стабильный порт.

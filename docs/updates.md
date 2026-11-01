# Обновления

Sparkle проверяет ленту раз в сутки. Скачивание, установка и перезапуск требуют подтверждения.
Настройка проверки хранится в preferences Sparkle, отдельно от kumiko.toml.

Публичный ключ лежит в Resources/sparkle-public-key. Приватный ключ хранится вне git:
это base64 от 32 байтов Ed25519 seed. Сохрани его резервную копию в менеджере паролей.
Смена ключа требует отдельного перехода для уже установленных приложений.

После подписи и notarization собери финальный ZIP. Изменение архива после генерации ленты
сломает проверку подписи.

```sh
swift package resolve
python3 scripts/appcast.py v0.5.0 dist/Kumiko-0.5.0.zip dist/update-feed \
  --private-key-file /path/to/sparkle-private.key
python3 scripts/test_appcast.py
```

Скрипт проверяет версию и ключ приложения, подписывает ZIP инструментом generate_appcast
и создаёт appcast.xml. Для описания изменений передай --release-notes /path/to/notes.md.

После загрузки ZIP запусти Publish update feed в Actions и укажи тег. Ключ берётся из секрета
SPARKLE_PRIVATE_KEY. Workflow принимает только последний стабильный релиз.

appcast.xml публикуется в релиз версии и в отдельный prerelease с тегом updates. Постоянный
адрес ленты работает и до загрузки ZIP следующей версии. Ссылки на ZIP ведут в релизы версий.

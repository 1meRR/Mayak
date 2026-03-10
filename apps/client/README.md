# Flutter client

## Команды

```bash
flutter create . --platforms=android,ios,windows,macos,linux
flutter pub get
flutter run -d windows
```

## Что делает клиент

- сохраняет имя и URL signaling server
- подключается к Rust signaling server по WebSocket
- создаёт локальный MediaStream
- поднимает P2P WebRTC-соединения
- рисует сетку участников и чат комнаты

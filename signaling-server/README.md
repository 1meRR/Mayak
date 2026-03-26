# Rust signaling server

## Запуск

```bash
cargo run
```

## Переменные окружения

```bash
BIND_ADDR=0.0.0.0:8080 cargo run
```

## Endpoints

- `GET /health`
- `GET /ws`

## Назначение

Сервер не передаёт медиа.
Он только:
- регистрирует peers в комнате
- сообщает кто уже есть в комнате
- пересылает offer / answer / ice_candidate
- рассылает системные события `peer_joined` / `peer_left`
- ретранслирует chat-сообщения в комнате

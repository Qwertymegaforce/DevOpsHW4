# Счетчик - фронтэнд

Фронтэнд счетчика на Next.js. Показывает значение счётчика и кнопку увеличения; данные берёт у бэкенда по `/api/counter`.

## Разработка

```sh
npm clean-install
npm run dev      # запросы /api/* проксируются на бэкенд http://localhost:8080
npm run lint
```

## Установка

Выполните следующие команды

```sh
npx next build
cp --recursive .next/standalone dist
cp --recursive public dist/public
cp --recursive .next/static dist/.next/static
```

или запустите `make install`.

Собранный сервер можно запустить командой `node dist/server.js`.

## Docker

- `Dockerfile` — полная сборка с нуля: `docker build -t counter-frontend .`;
- `Dockerfile.ci` — упаковка уже собранного каталога `dist` (используется в CI).

Сервер в контейнере слушает порт `8080`.

## Развертывание

* Запакуйте собранный сервер командой `make package` в архив `server.tar.gz`;
* Скопируйте на сервер;
* Установите командой `sudo sh -c 'rm --recursive --force /opt/counter && tar --extract --verbose --directory / --file server.tar.gz'`;
* Скопируйте Systemd службу из `deploy/counter-frontend.service` в `/etc/systemd/system`;
* Включите службу `systemctl enable --now counter-frontend.service`;

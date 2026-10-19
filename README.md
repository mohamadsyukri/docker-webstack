# docker-webstack

My local PHP/Laravel development stack for WSL + Docker Desktop: nginx, PHP-FPM 8.3 (8.4 on
demand), redis and mailpit in compose, MySQL as its own long-lived container, plus scripts to add
sites and to run Node and Playwright without installing them on the host.

Started from [hanafiah/docker-webstack](https://github.com/hanafiah/docker-webstack) and
[mohamadluqmannulhakim/docker-webstack](https://github.com/mohamadluqmannulhakim/docker-webstack),
cut down to what I actually use.

## What runs

| Service | Image | Reach it at |
|---|---|---|
| nginx | `nginx:1.31.2` | http://&lt;site&gt;.local (port 80) |
| php83 | built from `php/Dockerfile` | `docker exec -w /var/www/projects/<path> php83 php artisan …` |
| php84 | same Dockerfile, PHP 8.4 | only when `php84` is in `COMPOSE_PROFILES` |
| redis | `redis:8.8.0-alpine` | `redis:6379` inside, `127.0.0.1:6380` from the host |
| mailpit | `axllent/mailpit:v1.30.3` | SMTP `mailpit:1025`, inbox http://localhost:8025 |
| mysql-local | `mysql:8.4.10` (outside compose) | `mysql-local:3306` inside, `127.0.0.1:3306` from the host |

**Why MySQL is outside compose:** `docker compose down` can't touch it, so the database survives
any rebuild of the stack. The network is created once by `bin/setup.sh` and marked external, so
compose never deletes it either — that deletion is what used to detach mysql-local and make every
page hang ~20 s on DNS.

## New machine

1. Install Docker Desktop with WSL integration on, then in WSL:

       git clone git@github.com:mohamadsyukri/docker-webstack.git ~/docker-webstack
       cd ~/docker-webstack
       bin/setup.sh --dry-run    # shows what it would do
       bin/setup.sh

   It creates `.env` with random redis and MySQL passwords, the folders, `webstack-network`,
   `mysql-local` (if missing), builds the PHP images, starts everything and prints the hosts-file
   lines you still need to add.

2. Clone each project into `projects/` (e.g. `projects/me/todolist`) and add its site:

       bin/new-site.sh todolist me/todolist          # php83
       bin/new-site.sh todolist me/todolist php84    # or on PHP 8.4

3. Add the printed `127.0.0.1 <name>.local` lines to `C:\Windows\System32\drivers\etc\hosts`
   (Notepad as Administrator).

4. In each project's `.env`: `DB_HOST=mysql-local`, `REDIS_HOST=redis`,
   `REDIS_PASSWORD=<from webstack .env>`, `MAIL_HOST=mailpit`, `MAIL_PORT=1025`.

`bin/setup.sh` is safe to re-run any time something seems broken: it repairs the network, starts
mysql-local, and never removes a container, volume or database.

## Everyday

| Do | Command |
|---|---|
| Start / stop the stack | `docker compose up -d` / `docker compose stop` |
| Artisan, tests, Pint | `docker exec -w /var/www/projects/<path> php83 php artisan test --compact <file>` |
| Turn Xdebug on | `XDEBUG_MODE=debug` in `.env`, then `docker compose up -d --force-recreate php83` |
| npm install / build | `bin/node.sh <path> npm ci` · `bin/node.sh <path> npm run build` |
| Playwright | `bin/playwright.sh <path> npx playwright test e2e/x.spec.ts` |
| Remote testers (MyProjek) | `bin/tester-tunnel.sh start` · `status` · `stop` |
| Logs | `logs/nginx/`, `logs/php83/` |

`bin/playwright.sh` picks the Playwright image matching the version installed in the project, and
points every `*.local` site name at the nginx container, so tests use the same URLs you do.

## Layout

    compose.yaml          the stack
    .env.example          settings template (.env itself is never committed)
    php/Dockerfile        PHP-FPM image, one file for every version
    php/php.ini           shared PHP settings (opcache, uploads, timezone)
    php/fpm.d/www.conf    FPM pool
    nginx/nginx.conf      main nginx config
    nginx/sites/          one .conf per site (mounted as /etc/nginx/conf.d)
    nginx/site.conf.template   used by bin/new-site.sh
    redis/redis.conf      redis settings (password comes from .env)
    bin/                  setup.sh, new-site.sh, node.sh, playwright.sh, tester-tunnel.sh
    projects/             your code (git-ignored; each project has its own repo)

## Moving from the old docker-webstack on the same machine

The container names are the same (`nginx`, `php83`, …), so only one stack can run at a time —
`bin/setup.sh` refuses to start while the old one is up and tells you how to stop it. Keep
`projects/` at the same absolute path, so editor workspaces and anything keyed by path still work.

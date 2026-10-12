# ДЗ #1 — фундамент DevOps-инфраструктуры

Ansible + Docker Compose + Terraform (провайдер `kreuzwerker/docker`) + Bash на одной VM.

| | |
|---|---|
| VM | `111.88.162.106`, Ubuntu 24.04, 2 vCPU / 3 GB, VMware (выдана курсом) |
| Control node | ноутбук: Terraform 1.16, Ansible core 2.16 |
| Compose | `curl http://111.88.162.106` → «Hello World» через reverse proxy, сеть `hw1_app_net` |
| Terraform | `curl -i http://111.88.162.106:8080` → `200 OK`, nginx в сети `tf_web_net` с томом `tf_web_content` |

## Порядок выполнения (по уточнению преподавателя)

1. **Этап 3 — Ansible** готовит хост: пользователи, sshd, Docker, firewall.
2. **Этап 5 — Docker Compose** (тоже через Ansible): proxy + app в своей сети.
3. **Terraform с провайдером Docker** — вместо Этапа 2 из файла задания: nginx-контейнер в новой сети, с томом, на нестандартном порту. С compose-окружением не связан.

Terraform идёт последним, потому что ему нужен уже установленный Docker и пользователь `deployer` в группе `docker`, которые создаёт Ansible.

## Структура

```
ansible/
  inventory.ini               хост vm1 (IP VM, пользователь student)
  group_vars/all/             deployer, /opt/app, подсеть compose, публичные порты
  host_vars/vm1/admin.yml     IP администратора для SSH (git-ignored, есть .example)
  setup_host.yml              роли common, operator, docker, firewall
  deploy_app.yml              роль app (compose в /opt/app)
  roles/common                deployer, sudo NOPASSWD, sshd только по ключу
  roles/operator              vm-operator: минимальные права (аналог IAM-роли)
  roles/docker                Docker CE + compose plugin из официального репозитория
  roles/firewall              ufw: deny inbound, SSH только с admin_cidrs, 80 и 8080 открыты
  roles/app                   разворачивание compose-проекта
compose/                      docker-compose.yml, конфиг прокси, страница app
terraform/
  versions.tf                 провайдер kreuzwerker/docker, подключение к Docker по SSH
  variables.tf                IP, порт, сеть, подсеть, образ — с validation
  main.tf                     docker_network, docker_volume, docker_image, docker_container
  outputs.tf                  URL, имя контейнера, сеть и IP, том
  site/                       nginx.conf и шаблон index.html для контейнера
scripts/monitor.sh            статус сервиса, журнал, ошибки syslog за час
docs/outputs/                 полные выводы команд
```

## Архитектура

```
 Internet ──► ufw ─┬─ 22/tcp   только с admin_cidrs ──► sshd (только ключи, root запрещён)
 (111.88.162.106)  │
                   ├─ 80/tcp   ──► hw1-nginx-1 (reverse proxy)          ┐ hw1_app_net
                   │                  │ http://app:80                   │ 10.20.1.0/24
                   │                  ▼                                 │ (Ansible + Compose)
                   │               hw1-app-1 (Hello World, порт не опубликован) ┘
                   │
                   └─ 8080/tcp ──► tf-nginx :80  10.30.0.10           ┐ tf_web_net
                                     └─ том tf_web_content            │ 10.30.0.0/24
                                        → /usr/share/nginx/html        ┘ (Terraform)

 laptop ── terraform ── ssh://deployer@VM ── docker system dial-stdio ── dockerd
```

Две bridge-сети не связаны: контейнер из одной не достаёт до другой (проверено ниже).

Пользователи на VM:

| Пользователь | Кто создаёт | Права |
|---|---|---|
| `student` | выдан курсом | администратор, под ним работает Ansible |
| `deployer` | Ansible (`roles/common`) | `sudo` без пароля (требование задания), группа `docker`; под ним работает Terraform |
| `vm-operator` | Ansible (`roles/operator`) | вход только по ключу; `sudo` только `systemctl start/stop/restart docker` и `reboot` без аргументов |
| `root` | — | вход по SSH запрещён (`PermitRootLogin no`) |

## Установка и запуск

Нужно: Terraform ≥ 1.9, Ansible core ≥ 2.15, SSH-ключ в `authorized_keys` пользователя `student` на VM.

```bash
git clone https://github.com/ArtZap/devops-hw1-infra.git && cd devops-hw1-infra

# 1. Ansible: настройка хоста (Этап 3)
cd ansible
ansible-galaxy collection install -r requirements.yml -p ./collections
cp host_vars/vm1/admin.yml.example host_vars/vm1/admin.yml   # свой IP: ssh student@<VM_IP> 'echo $SSH_CLIENT'
ansible-playbook setup_host.yml
ansible-playbook setup_host.yml          # второй прогон: changed=0

# 2. Compose-окружение (Этап 5)
ansible-playbook deploy_app.yml
curl http://<VM_IP>

# 3. Terraform + провайдер Docker
cd ../terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan
curl -i http://<VM_IP>:8080/

# 4. Мониторинг (Этап 4)
scp ../scripts/monitor.sh deployer@<VM_IP>:
ssh deployer@<VM_IP> 'sudo ./monitor.sh docker'
```

Удаление: `terraform destroy` удаляет контейнер, сеть и том; образ остаётся (`keep_locally`), им пользуется compose.

## Результаты

Полные выводы — в [`docs/outputs/`](docs/outputs/). Личные IP администратора замаскированы как `x.x`.

### Ansible: идемпотентность

Первый прогон — `changed=2` ([`ansible_setup_run1.txt`](docs/outputs/ansible_setup_run1.txt)): на этой VM роли уже запускались во время отладки, изменились только sudoers `vm-operator` и правило ufw для 8080. Второй прогон ([`ansible_setup_run2.txt`](docs/outputs/ansible_setup_run2.txt)):

```
TASK [common : Create deployment user] *****************************************
ok: [vm1]
TASK [common : Allow passwordless sudo for deployer] ***************************
ok: [vm1]
TASK [common : Harden sshd (key-only, no root login)] **************************
ok: [vm1]
TASK [operator : Grant operator least-privilege sudo] **************************
ok: [vm1]
TASK [docker : Install Docker Engine and Compose plugin] ***********************
ok: [vm1]
TASK [docker : Enable Docker and containerd on boot] ***************************
ok: [vm1] => (item=containerd)
ok: [vm1] => (item=docker)
TASK [firewall : Allow public service ports] ***********************************
ok: [vm1] => (item=80)
ok: [vm1] => (item=8080)
...
PLAY RECAP *********************************************************************
vm1                        : ok=23   changed=0    unreachable=0    failed=0    skipped=2
```

Повторный `deploy_app.yml` тоже даёт `changed=0` ([`ansible_deploy.txt`](docs/outputs/ansible_deploy.txt)).

Состояние хоста после настройки ([`host_checks.txt`](docs/outputs/host_checks.txt)):

```
$ sudo ufw status verbose
Default: deny (incoming), allow (outgoing), deny (routed)
22/tcp                     ALLOW IN    93.175.x.x               # ssh-admin
22/tcp                     ALLOW IN    89.124.x.x               # ssh-admin
22/tcp                     ALLOW IN    83.242.x.x               # ssh-admin
80/tcp                     ALLOW IN    Anywhere                 # public
8080/tcp                   ALLOW IN    Anywhere                 # public

$ sudo -l -U vm-operator
(root) NOPASSWD: /usr/bin/systemctl start docker, /usr/bin/systemctl stop docker,
                 /usr/bin/systemctl restart docker, /usr/sbin/reboot ""

$ systemctl is-enabled docker containerd
enabled
enabled
$ sudo sshd -T | grep -E "^(permitrootlogin|passwordauthentication)"
permitrootlogin no
passwordauthentication no
```

### `docker compose ps` и `curl`

```
$ docker compose ps
NAME          IMAGE               SERVICE   STATUS                    PORTS
hw1-app-1     nginx:1.27-alpine   app       Up 3 minutes (healthy)    80/tcp
hw1-nginx-1   nginx:1.27-alpine   nginx     Up 3 minutes (healthy)    0.0.0.0:80->80/tcp, [::]:80->80/tcp

$ docker compose exec nginx wget -qO- http://app/
<h1>Hello World</h1> ...

$ curl -i http://111.88.162.106
HTTP/1.1 200 OK
Server: nginx
X-Proxy: hw1-nginx

<body><h1>Hello World</h1><p>Served by the app container behind the nginx reverse proxy.</p></body>
```

Заголовок `X-Proxy` ставит прокси, а страницу отдаёт `app`: запрос прошёл через оба контейнера.

### Terraform: `state list`, `apply`, `curl -i`

```
$ terraform state list
docker_container.nginx
docker_image.nginx
docker_network.web
docker_volume.web_content

$ terraform apply tfplan
docker_network.web: Creation complete after 3s
docker_volume.web_content: Creation complete after 1s [id=tf_web_content]
docker_image.nginx: Creation complete after 1s
docker_container.nginx: Creation complete after 12s
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.

Outputs:
container  = "tf-nginx"
network    = { ip = "10.30.0.10", name = "tf_web_net", subnet = "10.30.0.0/24" }
url        = "http://111.88.162.106:8080/"
volume     = "tf_web_content"

$ terraform plan
No changes. Your infrastructure matches the configuration.
```

Полный план — [`terraform_plan.txt`](docs/outputs/terraform_plan.txt), состояние — [`terraform_show.txt`](docs/outputs/terraform_show.txt).

```
$ curl -i http://111.88.162.106:8080/
HTTP/1.1 200 OK
Server: nginx
Content-Type: text/html
X-Managed-By: terraform

<h1>Hello from Terraform</h1>
<li>network: tf_web_net (10.30.0.0/24)</li>
<li>volume: tf_web_content mounted at /usr/share/nginx/html</li>
<li>host port: 8080 -> container port 80</li>
```

Сети и изоляция ([`docker_networks.txt`](docs/outputs/docker_networks.txt)):

```
NAMES         STATUS                    PORTS                                 NETWORKS
tf-nginx      Up 25 seconds (healthy)   0.0.0.0:8080->80/tcp                  tf_web_net
hw1-nginx-1   Up 3 minutes (healthy)    0.0.0.0:80->80/tcp, [::]:80->80/tcp   hw1_app_net
hw1-app-1     Up 3 minutes (healthy)    80/tcp                                hw1_app_net

tf_web_net  subnet=10.30.0.0/24 gw=10.30.0.1: tf-nginx=10.30.0.10/24
hw1_app_net subnet=10.20.1.0/24 gw=10.20.1.1: hw1-app-1=10.20.1.2/24 hw1-nginx-1=10.20.1.3/24

$ docker inspect tf-nginx --format '{{range .Mounts}}...'
volume tf_web_content -> /usr/share/nginx/html

$ docker exec hw1-nginx-1 wget -T 3 -qO- http://10.30.0.10/
wget: download timed out          # из сети compose до tf-nginx не достать
$ docker exec tf-nginx wget -T 3 -qO- http://10.20.1.2/
wget: download timed out          # и в обратную сторону
```

Данные тома переживают пересоздание контейнера ([`volume_persistence.txt`](docs/outputs/volume_persistence.txt)):

```
$ docker exec tf-nginx sh -c "echo persisted > /usr/share/nginx/html/note.txt"
$ terraform apply -replace=docker_container.nginx -auto-approve
docker_container.nginx: Destruction complete after 1s
docker_container.nginx: Creation complete after 11s
$ curl -i http://111.88.162.106:8080/note.txt
HTTP/1.1 200 OK
persisted
```

Проверки входных данных ([`terraform_validation.txt`](docs/outputs/terraform_validation.txt)): `-var external_port=80` → `Invalid value for variable`, `-var network_subnet=10.20.0.0/16` → `Resource precondition failed` (пересекается с `hw1_app_net`).

### `monitor.sh`

На VM ([`monitor_vm.txt`](docs/outputs/monitor_vm.txt)):

```
### sudo ./monitor.sh docker
== Service: docker on zaporozhetsas ==
Status: active
Errors in syslog for the last hour: 4
Top sources:
       2  fwupd
       2  dockerd
exit=0

### sudo ./monitor.sh nginx          # системный nginx остановлен Ansible
== Service: nginx on zaporozhetsas ==
Status: inactive
-- Last 10 journal lines --
Sep 28 16:20:20 zaporozhetsas systemd[1]: Stopping nginx.service - A high performance web server...
Sep 28 16:20:20 zaporozhetsas systemd[1]: nginx.service: Deactivated successfully.
Sep 28 16:20:20 zaporozhetsas systemd[1]: Stopped nginx.service - A high performance web server...
Errors in syslog for the last hour: 4
exit=1

### sudo ./monitor.sh nosuchsvc
Unit 'nosuchsvc' not found
exit=3

### sudo ./monitor.sh "docker; id"
ERROR: invalid service name: 'docker; id'
exit=2
```

Локально (Pop!_OS 24.04) — [`monitor_local.txt`](docs/outputs/monitor_local.txt): `docker` → 0, неактивный `apt-daily.service` → 1 с журналом, `nosuchsvc` → 3.

Коды возврата: `0` — active, `1` — не active, `2` — неверный аргумент, `3` — unit не найден, `4` — нет systemd.

## Архитектурные решения

**Terraform управляет Docker на VM через SSH.** Провайдер подключается как `ssh://deployer@111.88.162.106:22`: на VM запускается `docker system dial-stdio`, и API Docker идёт внутри SSH-сессии. Сокет Docker не открыт по TCP, отдельные TLS-сертификаты не нужны, работает тот же ключ и тот же firewall, что и для SSH.

**Ресурсы Terraform:**
- `docker_network.web` — новая bridge-сеть `tf_web_net` с явной подсетью `10.30.0.0/24`. Precondition не даёт выбрать подсеть, пересекающуюся с LAN машины `10.10.10.0/24` (Docker-сеть перекрыла бы маршрут к шлюзу) или с `hw1_app_net`.
- `docker_volume.web_content` — именованный том для `/usr/share/nginx/html`. Он живёт отдельно от контейнера: при пересоздании контейнера данные сохраняются.
- `docker_image.nginx` — `nginx:1.27-alpine`, тег зафиксирован. `keep_locally = true`: тот же образ использует compose, `destroy` не должен его удалять.
- `docker_container.nginx` — порт `8080 → 80`, только сеть `tf_web_net`, фиксированный IP `10.30.0.10`. `index.html` (из шаблона) и `nginx.conf` записываются блоками `upload` до старта контейнера; `index.html` попадает в том. `healthcheck` + `wait = true`: `apply` завершается ошибкой, если nginx не поднялся. Лимит памяти 128 MiB, `restart = unless-stopped`.

**Почему порт 8080.** 80 занят compose-прокси, 8081 — контейнером из другой лабы (`127.0.0.1:8081`). Validation требует непривилегированный порт (1024–65535) и не даёт взять 8081.

**Состояние Terraform.** Локальный `terraform.tfstate`, файл в `.gitignore`. `.terraform.lock.hcl` в репозитории фиксирует версию и хэши провайдера. Для команды нужен remote backend с блокировкой (S3-совместимый).

**IAM и минимальные привилегии.** Облака нет, поэтому роли — это пользователи Linux с ограниченным sudo:
- `vm-operator`: в sudoers перечислены точные командные строки. Команда без аргументов в sudoers разрешает любые аргументы, поэтому `reboot ""`. `systemctl status` не включён: он открывает pager (`less`) от root, а из него можно запустить shell.
- `root` не входит по SSH, пароли отключены для всех.
- `deployer` получает `NOPASSWD:ALL`, как требует задание. Группа `docker` по сути тоже root-доступ; это ограничение Docker, а не конфигурации.
- Файлы sudoers проверяются `visudo -cf` до установки; конфиг sshd — `sshd -t`.

**Security group (ufw).** Входящие запрещены по умолчанию. SSH — только с трёх `/32`, с которых я работаю. 80 и 8080 открыты всем: это сервисы. Исходящие разрешены: нужны apt и Docker Hub. Роль сначала проверяет `admin_cidrs` (не пусто, каждая сеть не шире `/24`, 22 не в публичных портах) и только потом включает ufw, иначе можно потерять доступ к VM. Модуль `ufw` умеет только добавлять правила, поэтому роль читает `ufw show added` и удаляет правила со своими комментариями (`ssh-admin`, `public`), которых больше нет в переменных. Удаление идёт после добавления: текущее правило SSH не пропадает ни на момент ([`ansible_firewall_drift.txt`](docs/outputs/ansible_firewall_drift.txt)). Правила, добавленные вручную без этих комментариев, роль не трогает. Ограничение: Docker пишет свои правила iptables в обход ufw, поэтому опубликованный порт открыт независимо от ufw. Правило для 8080 в ufw описывает намерение; сервисы, которые не должны быть снаружи, публикуются на `127.0.0.1:` (как 8081).

**Ansible.** Только модули с проверкой состояния (`apt`, `user`, `copy`, `get_url`, `apt_repository`, `systemd_service`, `ufw`, `docker_compose_v2`). Единственный `command` — чтение `ufw show added` с `changed_when: false`, он ничего не меняет. Поэтому повторный прогон ничего не меняет. Docker ставится из официального репозитория, `docker.io` и другие конфликтующие пакеты удаляются. `setup_host.yml` — подготовка хоста, `deploy_app.yml` — приложение.

**Compose.** Наружу опубликован только прокси. `app` доступен лишь внутри `app_net` по DNS-имени `app`. `depends_on: service_healthy` запускает прокси после того, как app прошёл healthcheck. Конфиги смонтированы только для чтения. Изменения в смонтированных файлах не видны compose (они не входят в его hash), поэтому handler перезапускает проект, когда файлы меняются.

## Проблемы и их решение

| Проблема | Как нашёл | Решение |
|---|---|---|
| Повторный `terraform plan` после `apply` хотел изменить контейнер: `memory_swap = 256 -> null` | `terraform plan` | Docker по умолчанию ставит swap = 2×memory. Задал `memory_swap = 128` явно, план стал `No changes` |
| Опубликованный порт Docker доступен в обход ufw | `iptables -t nat -S DOCKER`: DNAT `--dport 8080 → 10.30.0.10:80`, трафик идёт через `FORWARD`, где `DOCKER-FORWARD` стоит раньше цепочек ufw; правила ufw в `INPUT` его не видят | порт 8080 открыт намеренно; внутренние сервисы публикуются только на `127.0.0.1` |
| VM видит мой SSH с `93.175.x.x`, а `ifconfig.me` показывает `89.124.x.x` (разные NAT) | `echo $SSH_CLIENT`, `last` | `admin_cidrs` — список, адрес берётся с сервера |
| Порт 80 занят системным nginx из прошлой лабы | `ss -tlnp` | роль `app` останавливает и отключает его |
| `PasswordAuthentication yes` из `01-lab.conf` сильнее моего конфига: sshd берёт первое прочитанное значение | `sshd -T` | файл назван `00-hardening.conf`, проверка `sshd -t` перед установкой |
| Модуль `ufw` только добавляет правила: IP, убранный из `admin_cidrs`, остался бы с доступом к SSH | ревью безопасности роли, тест с подброшенными правилами `198.51.100.7` → 22 и `9999/tcp` | роль удаляет свои правила, которых нет в переменных; тест: `changed=2` (оба удалены), следующий прогон `changed=0` |
| `community.docker` 3.7.0 считает событие `Waiting` изменением → `changed=1` при каждом прогоне | вывод `-v` | `requirements.yml` с `community.docker` 4.x; готовность проверяется HTTP-запросом (`uri` + `until`) |
| `monitor.sh` пропускал строки из `/var/log/syslog.1`: `grep: binary file matches` (NUL-байты после некорректного завершения) | тест на VM | `grep -a` |

## Вопросы для самопроверки

1. **Императивный vs декларативный подход.** Bash — последовательность команд: «сделай это». Terraform описывает желаемое состояние (`docker_container` с такими портами и сетью), сам сравнивает его с state и реальностью и строит план. Ansible по форме императивен (задачи по порядку), но его модули декларативны (`state: present`): модуль сначала проверяет состояние и действует, только если оно отличается.
2. **Зачем нужен state.** По state Terraform сопоставляет ресурсы в коде с реальными объектами (`docker_container.nginx` ↔ контейнер с конкретным ID), считает diff и знает, что удалять. Если удалить state, Terraform «забудет» ресурсы: `apply` попытается создать их заново и упадёт на конфликте имён (`tf_web_net`, `tf-nginx` уже существуют), а `destroy` ничего не удалит. Восстановление — `terraform import` или блоки `import`. Обратная операция — `terraform state rm`: ресурс остаётся в реальности, но Terraform перестаёт им управлять.
3. **Идемпотентность.** Повторное применение не меняет систему, если она уже в нужном состоянии. Ansible добивается этого модулями, которые сравнивают текущее и желаемое состояние, и handlers, которые срабатывают только при изменении. Проверка: второй прогон `setup_host.yml` и `deploy_app.yml` → `changed=0`. Для Terraform аналог — `plan` после `apply` показывает `No changes`.
4. **Сервис не найден или лог пуст.** Пустой или неверный аргумент (regex блокирует `;`, пробелы и ведущий `-`) → код 2. `LoadState=not-found` → «Unit not found», код 3. Пустой или недоступный журнал → предупреждение с подсказкой (sudo / группа `systemd-journal`). Нет или нельзя прочитать `/var/log/syslog` → предупреждение, скрипт не падает. `grep` без совпадений (код 1) — это «0 ошибок», а не сбой.
5. **Почему такой вариант security group.** Deny по умолчанию и только необходимые порты. SSH ограничен адресами администратора и работает только по ключам: исключены перебор паролей и сканирование SSH из интернета. 80 и 8080 открыты, потому что это сервисы. `app` и Docker API снаружи недоступны вообще (Docker API идёт только через SSH). Остаточный риск — Docker обходит ufw для опубликованных портов, поэтому публиковать что-либо на `0.0.0.0` можно только осознанно.

## Git workflow

- `main` — Initial commit со структурой проекта (`terraform/`, `ansible/`, `scripts/`).
- `feature/infra-setup` — по коммиту на этап: Ansible → monitor.sh → Compose → Terraform → документация.
- Pull Request `feature/infra-setup` → `main`, само-ревью, merge commit.
- После мержа — тег `v0.1.0`.

# ДЗ #1 — фундамент DevOps-инфраструктуры

Terraform + Ansible + Bash + Docker Compose для одной VM: сеть и firewall, пользователь с минимальными правами, Docker, мониторинг сервисов и двухсервисное окружение nginx → app.

| | |
|---|---|
| VM | `111.88.162.106`, Ubuntu 24.04, 2 vCPU / 3 GB, VMware |
| Control node | ноутбук: Terraform 1.16, Ansible core 2.16 |
| Результат | `curl http://111.88.162.106` → «Hello World» через reverse proxy |

## Структура

```
terraform/                  IaC: network, host, firewall (security group), iam
  modules/network/          адресный план «VPC» и подсети для контейнеров
  modules/host/             подключение к VM: SSH, версия ОС, sudo
  modules/firewall/         ufw: deny inbound, SSH только с admin_cidrs, 80/tcp открыт
  modules/iam/              vm-operator: вход только по ключу, sudo только на docker и reboot
  templates/                шаблон inventory.ini
ansible/
  inventory.ini             генерирует Terraform
  group_vars/all/network.yml  генерирует Terraform (подсеть для compose)
  setup_host.yml            роли common + docker
  deploy_app.yml            роль app (compose в /opt/app)
  roles/common              deployer, sudo NOPASSWD, sshd только по ключу
  roles/docker              Docker CE + compose plugin из официального репозитория
  roles/app                 разворачивание compose-проекта
compose/                    docker-compose.yml, конфиг прокси, страница app
scripts/monitor.sh          статус сервиса, журнал, ошибки syslog за час
docs/outputs/               полные выводы команд
```

## Архитектура

```
 Internet ──► ufw ─┬─ 22/tcp  только с admin_cidrs ──► sshd (только ключи, без root)
 (VM 111.88.162.106)│
                   └─ 80/tcp  всем ──► hw1-nginx (reverse proxy, :80)
                                          │  app_net 10.20.1.0/24 (bridge)
                                          ▼
                                       hw1-app (nginx, Hello World, порт не опубликован)
```

Пользователи на VM:

| Пользователь | Кто создаёт | Права |
|---|---|---|
| `student` | выдан курсом | администратор, под ним работают Terraform и Ansible |
| `vm-operator` | Terraform (`modules/iam`) | вход только по ключу; `sudo` только `systemctl start/stop/restart docker` и `reboot` без аргументов |
| `deployer` | Ansible (`roles/common`) | `sudo` без пароля (так требует задание), группа `docker` |
| `root` | — | вход по SSH запрещён (`PermitRootLogin no`) |

## Установка и запуск

Нужно на машине, откуда запускаете: Terraform ≥ 1.9, Ansible core ≥ 2.15, SSH-ключ, который уже добавлен в `authorized_keys` администратора VM.

```bash
git clone <repo> && cd devops-hw1

# 1. Инфраструктура
cd terraform
cp terraform.tfvars.example terraform.tfvars   # указать vm_ip и свои IP в admin_cidrs
ssh student@<VM_IP> 'echo $SSH_CLIENT'         # с какого адреса VM видит ваш SSH
terraform init
terraform plan -out=tfplan
terraform apply tfplan                         # также пишет ansible/inventory.ini и network.yml

# 2. Настройка хоста
cd ../ansible
ansible-galaxy collection install -r requirements.yml -p ./collections
ansible-playbook setup_host.yml
ansible-playbook setup_host.yml                # второй прогон: changed=0

# 3. Приложение
ansible-playbook deploy_app.yml
curl http://<VM_IP>

# 4. Мониторинг
scp ../scripts/monitor.sh deployer@<VM_IP>:
ssh deployer@<VM_IP> 'sudo ./monitor.sh docker'
```

Удаление: `terraform destroy` выключает ufw и удаляет `vm-operator`. Docker и `deployer` принадлежат Ansible и остаются на VM.

## Результаты

Полные выводы лежат в [`docs/outputs/`](docs/outputs/).

### `terraform state list`

```
$ terraform state list
local_file.inventory
local_file.network_vars
module.firewall.terraform_data.security_group
module.host.terraform_data.vm
module.iam.terraform_data.operator
module.network.terraform_data.vpc
```

`terraform plan` сразу после `apply` показывает «No changes»: конфигурация и состояние совпадают. Правила firewall, которые применил Terraform ([`terraform_apply.txt`](docs/outputs/terraform_apply.txt)):

```
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    93.175.x.x               # ssh-admin
22/tcp                     ALLOW IN    89.124.x.x             # ssh-admin
22/tcp                     ALLOW IN    83.242.x.x              # ssh-admin
80/tcp                     ALLOW IN    Anywhere                   # public
80/tcp (v6)                ALLOW IN    Anywhere (v6)              # public
```

Права `vm-operator` (`sudo -l`):

```
(root) NOPASSWD: /usr/bin/systemctl start docker, /usr/bin/systemctl stop docker,
                 /usr/bin/systemctl restart docker, /usr/sbin/reboot ""
```

### Ansible: идемпотентность

Первый прогон — `changed=9` ([`ansible_setup_run1.txt`](docs/outputs/ansible_setup_run1.txt)). Второй прогон:

```
TASK [common : Create deployment user] *****************************************
ok: [vm1]
TASK [common : Authorize deployer SSH key] *************************************
ok: [vm1]
TASK [common : Allow passwordless sudo for deployer] ***************************
ok: [vm1]
TASK [common : Harden sshd (key-only, no root login)] **************************
ok: [vm1]
TASK [docker : Remove conflicting packages] ************************************
ok: [vm1]
TASK [docker : Install repository prerequisites] *******************************
ok: [vm1]
TASK [docker : Create apt keyrings directory] **********************************
ok: [vm1]
TASK [docker : Download Docker GPG key] ****************************************
ok: [vm1]
TASK [docker : Add Docker apt repository] **************************************
ok: [vm1]
TASK [docker : Install Docker Engine and Compose plugin] ***********************
ok: [vm1]
TASK [docker : Enable Docker and containerd on boot] ***************************
ok: [vm1] => (item=containerd)
ok: [vm1] => (item=docker)
TASK [docker : Let deployer use Docker without sudo] ***************************
ok: [vm1]

PLAY RECAP *********************************************************************
vm1                        : ok=13   changed=0    unreachable=0    failed=0    skipped=0
```

Повторный `deploy_app.yml` тоже даёт `changed=0` ([`ansible_deploy.txt`](docs/outputs/ansible_deploy.txt)).

Проверки после настройки:

```
$ ssh deployer@111.88.162.106 'sudo -n true && echo ok; systemctl is-enabled docker containerd'
ok
enabled
enabled
$ ssh -o PreferredAuthentications=password student@111.88.162.106
student@111.88.162.106: Permission denied (publickey).
```

### `monitor.sh`

На VM ([`monitor_vm.txt`](docs/outputs/monitor_vm.txt)):

```
### sudo ./monitor.sh docker
== Service: docker on zaporozhetsas ==
Status: active
Errors in syslog for the last hour: 77
Top sources:
      71  containerd
       4  dockerd
       2  fwupd
exit=0

### sudo ./monitor.sh nginx          # системный nginx остановлен Ansible
== Service: nginx on zaporozhetsas ==
Status: inactive
-- Last 10 journal lines --
Sep 24 16:56:04 zaporozhetsas systemd[1]: Starting nginx.service - A high performance web server...
Sep 24 16:56:04 zaporozhetsas systemd[1]: Started nginx.service - A high performance web server...
Sep 28 16:20:20 zaporozhetsas systemd[1]: Stopping nginx.service - A high performance web server...
Sep 28 16:20:20 zaporozhetsas systemd[1]: nginx.service: Deactivated successfully.
Sep 28 16:20:20 zaporozhetsas systemd[1]: Stopped nginx.service - A high performance web server...
Errors in syslog for the last hour: 77
...
exit=1

### sudo ./monitor.sh nosuchsvc
Unit 'nosuchsvc' not found
exit=3

### ./monitor.sh "docker; id"
ERROR: invalid service name: 'docker; id'
exit=2
```

Локально (Pop!_OS 24.04) — [`monitor_local.txt`](docs/outputs/monitor_local.txt): `docker` → 0, неактивный `apt-daily.service` → 1 с журналом, `nosuchsvc` → 3. Число ошибок сверено с отдельной командой `grep | awk | wc -l`.

Коды возврата: `0` — active, `1` — не active, `2` — неверный аргумент, `3` — unit не найден, `4` — нет systemd.

### `docker compose ps` и `curl`

```
$ cd /opt/app && docker compose ps
NAME          IMAGE               SERVICE   STATUS                        PORTS
hw1-app-1     nginx:1.27-alpine   app       Up About a minute (healthy)   80/tcp
hw1-nginx-1   nginx:1.27-alpine   nginx     Up About a minute (healthy)   0.0.0.0:80->80/tcp, [::]:80->80/tcp

$ docker network inspect hw1_app_net
subnet=10.20.1.0/24 gateway=10.20.1.1
  hw1-nginx-1 10.20.1.3/24
  hw1-app-1 10.20.1.2/24

$ docker compose exec nginx wget -qO- http://app/
<h1>Hello World</h1>
```

```
$ curl -i http://111.88.162.106
HTTP/1.1 200 OK
Server: nginx
Content-Type: text/html
X-Proxy: hw1-nginx

<!doctype html>
...
<body><h1>Hello World</h1><p>Served by the app container behind the nginx reverse proxy.</p></body>
```

Заголовок `X-Proxy` ставит прокси, а страницу отдаёт `app`: запрос прошёл через оба контейнера.

## Архитектурные решения

**VM не создаётся, а принимается под управление.** Курс выдал готовую VMware-VM без вложенной виртуализации (`/dev/kvm` нет), облачного аккаунта нет. Terraform поэтому не создаёт машину, а управляет тем, что на ней можно описать декларативно:
- `network` — адресный план: `vpc_cidr = 10.20.0.0/16`, из него `cidrsubnet(…, 8, 1) = 10.20.1.0/24` для `app_net`. Precondition запрещает пересечение с LAN машины `10.10.10.0/24`: иначе Docker-сеть перекрыла бы маршрут к шлюзу.
- `firewall` — security group на ufw. Все правила берутся из переменных. Любое изменение пересоздаёт ресурс, и набор правил применяется целиком с нуля (`ufw reset` → правила → `enable`), поэтому на VM не остаются старые правила.
- `iam` — аналог IAM-роли: отдельный пользователь, который умеет только управлять Docker-сервисом и перезагружать VM.
- `host` — проверяет SSH, версию ОС и sudo. Остальные модули зависят от него.

Облачный вариант (VPC, `compute_instance`, `security_group`, `iam_service_account`) заменил бы эти четыре модуля, не меняя их интерфейс: `ip` на выходе, `admin_cidrs` на входе.

**Состояние.** Хранится локально в `terraform.tfstate`, файл в `.gitignore`: в нём пути к ключам и данные машины. `.terraform.lock.hcl` лежит в репозитории, чтобы версии провайдеров совпадали у всех. Для командной работы нужен remote backend с блокировкой (например, S3-совместимый).

**Security group.** Входящий трафик запрещён по умолчанию. SSH разрешён только с трёх `/32` — адресов, с которых я работаю. Порт 80 открыт всем: это сервис. Исходящий трафик разрешён: нужны apt и Docker Hub. Validation в Terraform не пропускает для SSH сети шире `/24` и не даёт добавить 22 в публичные порты. Что исключено: перебор паролей SSH (закрыт порт и отключены пароли) и доступ к другим портам, которые могут появиться на VM.

**Минимальные привилегии.**
- `vm-operator`: в sudoers перечислены точные командные строки. Команда без аргументов в sudoers разрешает любые аргументы, поэтому `reboot ""`. `systemctl status` не включён: он открывает pager (`less`) от root, а из него можно запустить shell.
- `root` не может войти по SSH, пароли отключены для всех.
- `deployer` получает `NOPASSWD:ALL`, как требует задание. Docker без sudo ему даёт группа `docker`, что по сути тоже root-доступ; это ограничение Docker, а не конфигурации.
- Файлы sudoers проверяются `visudo -cf` до установки. Сломанный sudoers не попадёт в систему.

**Ansible.** Используются только модули с проверкой состояния (`apt`, `user`, `copy`, `get_url`, `apt_repository`, `systemd_service`, `docker_compose_v2`), без `shell`/`command`, поэтому повторный прогон ничего не меняет. Docker ставится из официального репозитория, `docker.io` и другие конфликтующие пакеты удаляются. Два playbook: `setup_host.yml` — подготовка хоста (проверяется на идемпотентность), `deploy_app.yml` — приложение.

**Compose.** Наружу опубликован только прокси. `app` доступен лишь внутри `app_net` по DNS-имени `app`. `depends_on: service_healthy` запускает прокси после того, как app прошёл healthcheck. Конфиги смонтированы только для чтения. Подсеть приходит из Terraform через `/opt/app/.env`. Изменения в смонтированных файлах не видны compose (они не входят в его hash), поэтому handler перезапускает проект, когда файлы меняются.

## Проблемы и их решение

| Проблема | Как нашёл | Решение |
|---|---|---|
| Terraform не может создать VM: нет nested virtualization | `ls /dev/kvm`, `systemd-detect-virt` → `vmware` | Terraform принимает VM под управление (см. выше) |
| VM видит мой SSH с `93.175.x.x`, а `ifconfig.me` показывает `89.124.x.x` (разные NAT) | `echo $SSH_CLIENT`, `last` | `admin_cidrs` — список, адрес берётся с сервера, а не с сайта |
| Порт 80 занят системным nginx из прошлой лабы | `ss -tlnp` | роль `app` останавливает и отключает его |
| `PasswordAuthentication yes` из `01-lab.conf` сильнее моего конфига: sshd берёт первое прочитанное значение | `sshd -T` | файл назван `00-hardening.conf`, проверка через `sshd -t` перед установкой |
| `community.docker` 3.7.0 не знает `wait` и считает событие `Waiting` изменением → `changed=1` при каждом прогоне | вывод `-v` | `requirements.yml` с `community.docker` 4.x в проекте; готовность проверяется HTTP-запросом (`uri` + `until`) |
| `monitor.sh` на VM пропускал строки из `/var/log/syslog.1`: `grep: binary file matches` (NUL-байты после некорректного завершения) | тест на VM | `grep -a` |
| Pager в `systemctl status` из-под sudo даёт shell | ревью sudoers | команда исключена из прав `vm-operator` |

## Вопросы для самопроверки

1. **Императивный vs декларативный подход.** Bash — последовательность команд: «сделай это». Terraform описывает желаемое состояние, сам сравнивает его с state и строит план изменений. Ansible по форме императивен (задачи выполняются по порядку), но его модули декларативны (`state: present`): модуль сначала проверяет состояние и действует, только если оно отличается.
2. **Зачем нужен state.** По state Terraform сопоставляет ресурсы в коде с реальными объектами, считает diff и знает, что удалять. Если удалить state, Terraform «забудет» ресурсы: следующий `apply` попытается создать всё заново (в облаке — дубликаты или конфликты имён), а `destroy` ничего не удалит. Восстановление — `terraform import` (или блоки `import`). Здесь потеря state означала бы повторный прогон provisioner'ов; они написаны так, что повтор безопасен (`id -u … || useradd`, `ufw reset`).
3. **Идемпотентность.** Повторное применение не меняет систему, если она уже в нужном состоянии. Ansible добивается этого модулями, которые сравнивают текущее и желаемое состояние, и обработчиками (handlers), которые срабатывают только на изменение. Проверка: второй прогон `setup_host.yml` и `deploy_app.yml` → `changed=0`.
4. **Сервис не найден или лог пуст.** Пустой или неверный аргумент (regex блокирует `;`, пробелы и ведущий `-`) → код 2. `LoadState=not-found` → «Unit not found», код 3. Пустой или недоступный журнал → предупреждение с подсказкой (sudo / группа `systemd-journal`). Нет или нельзя прочитать `/var/log/syslog` → предупреждение, скрипт не падает. `grep` без совпадений (код 1) — это «0 ошибок», а не сбой.
5. **Почему такой вариант security group.** Только необходимые порты и deny по умолчанию. SSH ограничен адресами администратора и работает только по ключам, поэтому исключены перебор паролей и сканирование SSH из интернета. Порт 80 открыт, потому что это сервис. Контейнер `app` снаружи недоступен вообще. Ограничение: Docker пишет свои правила iptables в обход ufw, поэтому опубликованный порт открыт независимо от ufw. Для порта 80 это не важно, но публиковать другие порты можно только осознанно или с `127.0.0.1:`.

## Git workflow

`main` ← MR из `feature/infra-setup` (коммит на каждый этап) → тег `v0.1.0` после мержа.

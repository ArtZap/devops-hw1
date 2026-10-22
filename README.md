# ДЗ #1. Фундамент DevOps-инфраструктуры

Всё работает на одной VM, которую выдали на курсе. Хост настраивается Ansible, на нём крутится compose-окружение (прокси + app), а отдельно от него Terraform через провайдер `kreuzwerker/docker` поднимает ещё один nginx в своей сети. Есть скрипт мониторинга на bash.

| | |
|---|---|
| VM | `111.88.162.106`, Ubuntu 24.04, 2 vCPU / 3 GB, VMware |
| Откуда запускаю | ноутбук, Terraform 1.16, Ansible core 2.16 |
| Compose | `curl http://111.88.162.106` отдаёт «Hello World» через reverse proxy, сеть `hw1_app_net` |
| Terraform | `curl -i http://111.88.162.106:8080` отдаёт `200 OK`, nginx в сети `tf_web_net` с томом `tf_web_content` |

## В каком порядке делал

Преподаватель уточнил задание: этап 2 из файла (Terraform для облака) не делаем, сначала выполняем этап 3 с Ansible, а потом пишем Terraform на провайдере Docker. Поэтому порядок такой:

1. Ansible настраивает хост: пользователи, sshd, Docker, firewall (этап 3).
2. Тем же Ansible разворачиваю compose с прокси и app (этап 5).
3. Terraform создаёт nginx-контейнер в новой сети, с томом, на порту 8080. С compose он никак не связан.

Terraform у меня последний, потому что ему нужен Docker на VM и пользователь `deployer` в группе `docker`. И то и другое создаёт Ansible.

## Структура

```
ansible/
  inventory.ini               хост vm1 (IP VM, пользователь student)
  group_vars/all/             deployer, /opt/app, подсеть compose, публичные порты
  setup_host.yml              роли common, operator, docker, firewall
  deploy_app.yml              роль app (compose в /opt/app)
  roles/common                deployer, sudo NOPASSWD, sshd только по ключу
  roles/operator              vm-operator с минимальными правами (вместо IAM-роли)
  roles/docker                Docker CE + compose plugin из официального репозитория
  roles/firewall              ufw: deny inbound, SSH с лимитом подключений, 80 и 8080 открыты
  roles/app                   разворачивание compose-проекта
compose/                      docker-compose.yml, конфиг прокси, страница app
terraform/
  versions.tf                 провайдер kreuzwerker/docker, подключение к Docker по SSH
  variables.tf                IP, порт, сеть, подсеть, образ, с validation
  main.tf                     docker_network, docker_volume, docker_image, docker_container
  outputs.tf                  URL, имя контейнера, сеть и IP, том
  site/                       nginx.conf и шаблон index.html для контейнера
scripts/monitor.sh            статус сервиса, журнал, ошибки syslog за час
docs/outputs/                 полные выводы команд
```

## Схема

```
 Internet ──► ufw ─┬─ 22/tcp   limit (6 подключений / 30 с) ──► sshd (только ключи, root запрещён)
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

Сети друг с другом не связаны, из одной в другую контейнер не достучится. Проверка ниже.

Кто есть на VM:

| Пользователь | Откуда | Что может |
|---|---|---|
| `student` | выдали на курсе | админ, под ним работает Ansible |
| `deployer` | Ansible, `roles/common` | `sudo` без пароля (так в задании), группа `docker`; под ним работает Terraform |
| `vm-operator` | Ansible, `roles/operator` | вход только по ключу; через `sudo` только `systemctl start/stop/restart docker` и `reboot` без аргументов |
| `root` | | по SSH не пускает (`PermitRootLogin no`) |

## Как запустить

Нужны Terraform ≥ 1.9, Ansible core ≥ 2.15 и SSH-ключ, который уже лежит в `authorized_keys` у `student` на VM.

```bash
git clone https://github.com/ArtZap/devops-hw1.git && cd devops-hw1

# 1. Ansible: настройка хоста (этап 3)
cd ansible
ansible-galaxy collection install -r requirements.yml -p ./collections
ansible-playbook setup_host.yml
ansible-playbook setup_host.yml          # второй прогон: changed=0

# 2. Compose (этап 5)
ansible-playbook deploy_app.yml
curl http://<VM_IP>

# 3. Terraform + провайдер Docker
cd ../terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan
curl -i http://<VM_IP>:8080/

# 4. Мониторинг (этап 4)
scp ../scripts/monitor.sh deployer@<VM_IP>:
ssh deployer@<VM_IP> 'sudo ./monitor.sh docker'
```

`terraform destroy` удаляет контейнер, сеть и том. Образ остаётся (`keep_locally`), потому что его использует и compose.

## Результаты

Полные выводы лежат в [`docs/outputs/`](docs/outputs/). Свои IP я там замаскировал как `x.x`.

### Ansible и идемпотентность

Первый прогон показал `changed=2` ([`ansible_setup_run1.txt`](docs/outputs/ansible_setup_run1.txt)). Роли на этой VM я уже запускал, пока отлаживал, так что поменялись только sudoers для `vm-operator` и правило ufw для 8080. Второй прогон ([`ansible_setup_run2.txt`](docs/outputs/ansible_setup_run2.txt)):

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

`deploy_app.yml` при повторном запуске тоже даёт `changed=0` ([`ansible_deploy.txt`](docs/outputs/ansible_deploy.txt)).

Что получилось на хосте ([`host_checks.txt`](docs/outputs/host_checks.txt)):

```
$ sudo ufw status verbose
Default: deny (incoming), allow (outgoing), deny (routed)
22/tcp                     LIMIT IN    Anywhere                 # ssh
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

Заголовок `X-Proxy` добавляет прокси, а саму страницу отдаёт `app`. Значит, запрос прошёл через оба контейнера.

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

Полный план в [`terraform_plan.txt`](docs/outputs/terraform_plan.txt), состояние в [`terraform_show.txt`](docs/outputs/terraform_show.txt).

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
wget: download timed out          # и обратно тоже
```

Чтобы убедиться, что том реально работает, записал в него файл и пересоздал контейнер ([`volume_persistence.txt`](docs/outputs/volume_persistence.txt)). Файл остался:

```
$ docker exec tf-nginx sh -c "echo persisted > /usr/share/nginx/html/note.txt"
$ terraform apply -replace=docker_container.nginx -auto-approve
docker_container.nginx: Destruction complete after 1s
docker_container.nginx: Creation complete after 11s
$ curl -i http://111.88.162.106:8080/note.txt
HTTP/1.1 200 OK
persisted
```

Проверил и валидацию ([`terraform_validation.txt`](docs/outputs/terraform_validation.txt)). С `-var external_port=80` план падает с `Invalid value for variable`, с `-var network_subnet=10.20.0.0/16` падает с `Resource precondition failed`, потому что такая подсеть пересекается с `hw1_app_net`.

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

На ноутбуке (Pop!_OS 24.04) тоже гонял, вывод в [`monitor_local.txt`](docs/outputs/monitor_local.txt): `docker` вернул 0, неактивный `apt-daily.service` вернул 1 и показал журнал, `nosuchsvc` вернул 3.

Коды возврата: `0` сервис active, `1` не active, `2` неверный аргумент, `3` unit не найден, `4` нет systemd.

## Почему сделано так

### Terraform ходит в Docker по SSH

Провайдер подключается к `ssh://deployer@111.88.162.106:22`. На VM при этом запускается `docker system dial-stdio`, и все запросы к Docker API идут внутри SSH-сессии. Открывать Docker по TCP не пришлось, сертификаты тоже не нужны: работает тот же ключ и тот же firewall, что и для обычного SSH.

### Что создаёт Terraform

`docker_network.web` это новая bridge-сеть `tf_web_net` с подсетью `10.30.0.0/24`. Я добавил precondition, который не даст выбрать подсеть, пересекающуюся с LAN самой машины `10.10.10.0/24` (иначе Docker-сеть перекрыла бы маршрут к шлюзу) или с `hw1_app_net`.

`docker_volume.web_content` это именованный том, смонтированный в `/usr/share/nginx/html`. Он не зависит от контейнера, поэтому при пересоздании контейнера данные не теряются.

`docker_image.nginx` это `nginx:1.27-alpine`, тег зафиксирован. Стоит `keep_locally = true`, потому что тот же образ использует compose и `destroy` не должен его удалять.

`docker_container.nginx` публикует `8080 → 80`, подключён только к `tf_web_net` с фиксированным IP `10.30.0.10`. `index.html` (из шаблона) и `nginx.conf` записываются в контейнер блоками `upload` до старта, причём `index.html` ложится в том. Есть `healthcheck` и `wait = true`, так что если nginx не поднимется, `apply` упадёт с ошибкой. Ещё лимит памяти 128 MiB и `restart = unless-stopped`.

### Порт 8080

80 уже занят compose-прокси, а 8081 занят контейнером из другой лабы (`127.0.0.1:8081`). В validation разрешены только непривилегированные порты 1024–65535, и 8081 отдельно запрещён.

### State

`terraform.tfstate` хранится локально и в `.gitignore`. А вот `.terraform.lock.hcl` лежит в репозитории, он фиксирует версию и хэши провайдера. Если бы над проектом работала команда, нужен был бы remote backend с блокировкой, например S3-совместимый.

### Пользователи и права

Облака нет, поэтому вместо IAM-ролей у меня пользователи Linux с ограниченным sudo.

У `vm-operator` в sudoers прописаны точные командные строки. Если в sudoers указать команду без аргументов, она разрешается с любыми аргументами, поэтому там `reboot ""`. `systemctl status` я туда не добавил: он открывает `less` от root, а из `less` можно запустить shell.

root по SSH не заходит, пароли отключены у всех. `deployer` получил `NOPASSWD:ALL`, как требует задание. Группа `docker` по сути тоже даёт root, но это особенность самого Docker, с конфигурацией тут ничего не сделать. Файлы sudoers перед установкой проверяются через `visudo -cf`, конфиг sshd через `sshd -t`.

### Firewall (ufw вместо security group)

Входящие по умолчанию запрещены. 80 и 8080 открыты всем, это сервисы. Исходящие разрешены, без них не работают apt и Docker Hub.

SSH открыт с любого адреса. Сначала я пускал только со своих IP, но домашний провайдер меняет адрес, и однажды я сам себя заблокировал. Поэтому защита SSH держится не на адресе, а на остальном: вход только по ключу, пароли и root отключены (роль `common`). Подобрать ключ перебором нельзя. Против ботов, которые всё равно стучатся в 22-й порт, стоит `ufw limit`: адрес, открывший 6 и больше подключений за 30 секунд, временно блокируется.

Модуль `ufw` умеет только добавлять правила. Поэтому роль читает `ufw show added` и удаляет правила со своими комментариями, которые больше не нужны: старые правила SSH для отдельных адресов (`ssh-admin`) и публичные порты (`public`), которых нет в переменных. Удаляет после того, как добавит новые, так что текущее правило для SSH не пропадает ни на секунду ([`ansible_firewall_drift.txt`](docs/outputs/ansible_firewall_drift.txt)). Правила, которые кто-то добавил руками без этих комментариев, роль не трогает.

Есть ограничение: Docker пишет свои правила iptables в обход ufw, и опубликованный порт открыт независимо от ufw. Правило для 8080 в ufw скорее документирует, что порт открыт намеренно. То, что не должно торчать наружу, надо публиковать на `127.0.0.1:` (как сделано с 8081).

### Ansible

Использую только модули, которые сами проверяют состояние: `apt`, `user`, `copy`, `get_url`, `apt_repository`, `systemd_service`, `ufw`, `docker_compose_v2`. Единственный `command` это чтение `ufw show added` с `changed_when: false`. Поэтому повторный прогон ничего не меняет. Docker ставлю из официального репозитория, а `docker.io` и другие конфликтующие пакеты удаляю. Плейбука два: `setup_host.yml` готовит хост, `deploy_app.yml` разворачивает приложение.

### Compose

Наружу опубликован только прокси. `app` доступен лишь внутри `app_net` по имени `app`. Благодаря `depends_on: service_healthy` прокси стартует только после того, как app прошёл healthcheck. Конфиги смонтированы read-only. Compose не замечает изменений в смонтированных файлах (они не входят в его hash), так что при их изменении проект перезапускает handler.

## С чем столкнулся

| Проблема | Как нашёл | Что сделал |
|---|---|---|
| После `apply` повторный `terraform plan` хотел поменять контейнер: `memory_swap = 256 -> null` | `terraform plan` | Docker по умолчанию ставит swap в два раза больше памяти. Задал `memory_swap = 128` явно, план стал `No changes` |
| Опубликованный порт Docker доступен в обход ufw | `iptables -t nat -S DOCKER`: DNAT `--dport 8080 → 10.30.0.10:80`, трафик идёт через `FORWARD`, где `DOCKER-FORWARD` стоит раньше цепочек ufw, и правила ufw в `INPUT` его не видят | 8080 открыт намеренно, внутренние сервисы публикую только на `127.0.0.1` |
| Сначала SSH был открыт только с моих IP. Провайдер сменил адрес, и я не смог зайти: SSH падал с `Connection timed out during banner exchange`, хотя сайты на 80 и 8080 отвечали | `curl https://ifconfig.me` показал новый адрес, которого не было в списке разрешённых | открыл SSH для всех с `ufw limit`, безопасность держится на входе только по ключу. Старые правила по адресам роль удаляет сама |
| Порт 80 занимал системный nginx из прошлой лабы | `ss -tlnp` | роль `app` его останавливает и отключает |
| `PasswordAuthentication yes` из `01-lab.conf` перебивал мой конфиг: sshd берёт первое прочитанное значение | `sshd -T` | назвал файл `00-hardening.conf`, перед установкой проверка `sshd -t` |
| Модуль `ufw` только добавляет правила: правило, убранное из переменных, осталось бы на сервере | при ревью роли; проверил, подкинув вручную правила `198.51.100.7` → 22 и `9999/tcp` | роль удаляет свои правила, которых нет в переменных. На тесте `changed=2` (оба удалены), следующий прогон `changed=0` |
| `community.docker` 3.7.0 считал событие `Waiting` изменением, и каждый прогон давал `changed=1` | вывод с `-v` | в `requirements.yml` поставил `community.docker` 4.x, готовность проверяю HTTP-запросом (`uri` + `until`) |
| `monitor.sh` пропускал строки из `/var/log/syslog.1` с `grep: binary file matches` (NUL-байты после некорректного выключения) | тест на VM | `grep -a` |

## Вопросы для самопроверки

**1. Императивный и декларативный подход.** Bash это просто последовательность команд. В Terraform я описываю, каким всё должно быть (`docker_container` с такими портами и сетью), а он сам сравнивает это со state и с реальностью и строит план. Ansible выполняет задачи по порядку, то есть по форме он императивный, но сами модули декларативные (`state: present`): модуль сначала смотрит, что есть, и что-то делает, только если состояние отличается.

**2. Зачем state.** По нему Terraform связывает ресурсы в коде с реальными объектами (`docker_container.nginx` и контейнер с конкретным ID), считает diff и понимает, что удалять. Если state удалить, Terraform про ресурсы забудет. `apply` попробует создать их заново и упадёт на конфликте имён (`tf_web_net` и `tf-nginx` уже есть), а `destroy` ничего не удалит. Вернуть можно через `terraform import` или блоки `import`. Обратная операция `terraform state rm`: ресурс остаётся, но Terraform им больше не управляет.

**3. Идемпотентность.** Это когда повторный запуск ничего не меняет, если система уже в нужном состоянии. В Ansible за это отвечают модули, которые сравнивают текущее состояние с желаемым, и handlers, которые срабатывают только при изменениях. Проверял вторым прогоном `setup_host.yml` и `deploy_app.yml`, оба дали `changed=0`. У Terraform аналог: `plan` после `apply` пишет `No changes`.

**4. Сервис не найден или лог пуст.** Пустой или кривой аргумент (regex не пропускает `;`, пробелы и `-` в начале) даёт код 2. Если `LoadState=not-found`, скрипт пишет «Unit not found» и выходит с кодом 3. Если журнал пустой или нет прав его читать, выводится предупреждение с подсказкой (sudo или группа `systemd-journal`). Если `/var/log/syslog` нет или его нельзя прочитать, тоже предупреждение, но скрипт не падает. Когда `grep` ничего не нашёл (код 1), это считается «0 ошибок», а не сбоем.

**5. Почему такая security group.** Всё запрещено, кроме нужных портов. SSH открыт для всех, но только по ключу: паролей нет, поэтому перебирать нечего. `ufw limit` отсекает ботов, которые долбят порт 22. Привязку к IP я убрал, потому что мой адрес меняется, а безопасность от неё почти не зависит, когда пароли выключены. 80 и 8080 открыты, потому что на них сервисы. `app` и Docker API снаружи недоступны вообще, Docker API идёт только через SSH. Остаётся риск, что Docker обходит ufw для опубликованных портов, поэтому публиковать что-то на `0.0.0.0` нужно осознанно.

## Git

В `main` лежит Initial commit со структурой (`terraform/`, `ansible/`, `scripts/`). Работа шла в ветке `feature/infra-setup`, по коммиту на этап: Ansible, monitor.sh, Compose, Terraform, документация. Потом Pull Request в `main` с само-ревью, merge commit и тег `v0.1.0`.

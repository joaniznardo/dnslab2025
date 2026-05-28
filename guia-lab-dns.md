# Guia del Lab de DNS amb BIND9

**Lab:** test018-bind9-lab  
**Assignatura:** Serveis en Xarxa / Administració de Sistemes  
**Institut:** Institut TIC de Barcelona  
**Domini de pràctiques:** `demobind.test` (no enrutable)  
**Xarxa:** `10.25.50.0/24`

---

## Índex

1. [Introducció i objectius](#1-introducció-i-objectius)
2. [Requisits previs](#2-requisits-previs)
3. [Arquitectura del lab](#3-arquitectura-del-lab)
4. [Fonaments teòrics](#4-fonaments-teòrics)
5. [Fase 1 — DNS primari únic](#5-fase-1--dns-primari-únic)
6. [Fase 2 — Primari i secundari](#6-fase-2--primari-i-secundari)
7. [Fase 3 — Delegació de subdomini](#7-fase-3--delegació-de-subdomini)
8. [Fase 4 — Lab complet](#8-fase-4--lab-complet)
9. [Referència de comandes](#9-referència-de-comandes)
10. [Resolució de problemes](#10-resolució-de-problemes)
11. [Punts d'ampliació](#11-punts-dampliació)

---

## 1. Introducció i objectius

Aquest lab progressiu cobreix els conceptes fonamentals del servei DNS implementant-los amb **BIND9** sobre contenidors gestionats per **Containerlab**. Cada fase afegeix complexitat sobre l'anterior, de manera que es pot validar cada concepte per separat abans de continuar.

### Objectius d'aprenentatge

| Fase | Concepte principal |
|------|-------------------|
| 1 | Zona directa, zona inversa, registres A/PTR/MX/NS/SOA |
| 2 | Servidor secundari, transferència de zona (AXFR), mecanisme NOTIFY |
| 3 | Delegació de subdomini, glue records, zona autoritativa delegada |
| 4 | Lab complet: servidor web, client gràfic, logs de consultes |

### Domini i adreces IP

```
Xarxa del lab:  10.25.50.0/24
Domini:         demobind.test

Servidors DNS
  dns1  10.25.50.11   Primari de demobind.test
  dns2  10.25.50.12   Secundari de demobind.test
  dns3  10.25.50.21   Primari de magatzem.demobind.test
  dns4  10.25.50.22   Secundari de magatzem.demobind.test

Serveis
  www   10.25.50.80   Servidor web Nginx
  mail  10.25.50.50   Registre DNS (sense contenidor real)

Clients
  cl01  10.25.50.101  Client textual (dig, nslookup, host, curl)
  cl02  10.25.50.102  Client gràfic Firefox via noVNC (port 6080)

Subdomini magatzem.demobind.test
  rodes         10.25.50.60
  prestatgeries 10.25.50.61
```

---

## 2. Requisits previs

### Programari necessari

```bash
# Verificar versions
docker --version          # >= 20.10
containerlab version      # >= 0.74.0
```

### Construcció de la imatge

El lab utilitza una imatge Docker personalitzada `bind9-lab:latest` basada en Ubuntu 22.04 amb BIND9, `dnsutils` i eines de xarxa:

```bash
./lab.sh build
```

La imatge exposa el port 53 (TCP i UDP) i arrenca amb `sleep infinity` per deixar que Containerlab iniciï `named` via les comandes `exec:` de la topologia. Això permet injectar configuració i adreça IP abans de llançar el servei.

### Verificació prèvia

```bash
./lab.sh check
```

Comprova que Docker, Containerlab i la imatge `bind9-lab:latest` estan disponibles.

---

## 3. Arquitectura del lab

### Topologia de xarxa

```
          ┌──────────────────────────────────────────────────────┐
          │                  br-dns (bridge Linux)               │
          │                 Xarxa 10.25.50.0/24                  │
          └──┬──────┬──────┬──────┬──────┬──────┬──────┬────────┘
             │      │      │      │      │      │      │
          dns1   dns2   dns3   dns4    www   cl01   cl02
        .11    .12    .21    .22    .80   .101   .102
```

Tots els nodes es connecten al pont Linux `br-dns`. La comunicació entre contenidors és directa a capa 2, com en una xarxa LAN real.

### Estructura de fitxers

```
test018-bind9-lab/
├── docker/
│   └── Dockerfile.bind9          # Imatge BIND9 personalitzada
├── fase1-primary/
│   ├── topology.clab.yml
│   └── configs/
│       └── dns1/
│           ├── named.conf
│           ├── named.conf.options
│           ├── named.conf.local
│           ├── named.conf.logging
│           └── zones/
│               ├── db.demobind.test    # Zona directa
│               └── db.10.25.50        # Zona inversa
├── fase2-secondary/
│   └── configs/
│       ├── dns1/  (primari, amb allow-transfer)
│       └── dns2/  (secundari, type slave)
├── fase3-delegation/
│   └── configs/
│       ├── dns1/  (primari, amb glue records i delegació NS)
│       ├── dns2/  (secundari)
│       ├── dns3/  (primari de magatzem.demobind.test)
│       └── dns4/  (secundari de magatzem.demobind.test)
├── fase4-full/
│   └── configs/
│       ├── dns1/ dns2/ dns3/ dns4/
│       ├── nginx/html/index.html
│       └── ...
├── scripts/
│   ├── deploy.sh
│   └── destroy.sh
└── lab.sh                        # Punt d'entrada unificat
```

---

## 4. Fonaments teòrics

### 4.1 Jerarquia DNS

El DNS és una base de dades distribuïda i jeràrquica. La resolució d'un nom segueix la cadena:

```
Client → Resolver local → Servidor arrel (.) → TLD (.test) → DNS autoritatiu
```

En aquest lab, com que el domini `demobind.test` no existeix a l'internet real, els servidors DNS del lab actuen com a autoritat final sense reenviar consultes a servidors externs.

> **Nota important:** Els servidors BIND9 d'aquest lab **no tenen `forwarders` configurats**. Si s'afegissin forwarders (ex. `8.8.8.8`), les consultes recursives del subdomini `magatzem.demobind.test` es reenviarien a Google DNS, que retornaria NXDOMAIN perquè el domini no és real. BIND9 acceptaria aquest NXDOMAIN i mai seguiria la delegació local.

### 4.2 Registres DNS fonamentals

| Registre | Propòsit | Exemple |
|----------|----------|---------|
| `SOA` | Inici d'autoritat d'una zona | Defineix el servidor primari i temporitzadors |
| `NS` | Servidor de noms autoritatiu | `demobind.test. IN NS dns1.demobind.test.` |
| `A` | Adreça IPv4 | `www IN A 10.25.50.80` |
| `PTR` | Resolució inversa | `80 IN PTR www.demobind.test.` |
| `MX` | Servidor de correu | `@ IN MX 10 mail.demobind.test.` |
| `CNAME` | Àlies | `ftp IN CNAME www.demobind.test.` |

### 4.3 El registre SOA

```
@   IN  SOA dns1.demobind.test. hostmaster.demobind.test. (
        2026052801  ; serial   — Format YYYYMMDDNN, incrementar en cada canvi
        3600        ; refresh  — Cada quant el secundari comprova el primari (1h)
        900         ; retry    — Si el refresh falla, reintenta cada 15min
        604800      ; expire   — Deixa de respondre si no pot contactar el primari (1 setmana)
        86400 )     ; negative TTL — Temps de cache per respostes NXDOMAIN
```

El camp **serial** és crític: si el secundari comprova el primari i el serial no ha augmentat, no fa la transferència. **Cal incrementar el serial cada vegada que es modifica un fitxer de zona.**

### 4.4 Transferència de zona (AXFR/IXFR)

Quan un servidor secundari s'inicia:
1. Llegeix la seva còpia en cache local (si existeix)
2. Comprova el serial del primari via consulta SOA
3. Si el serial del primari és major, sol·licita una transferència completa (AXFR) o incremental (IXFR)
4. El primari respon amb tots els registres de la zona

El mecanisme **NOTIFY** permet que el primari avisi proactivament els secundaris quan la zona canvia, sense esperar el `refresh`. Redueix la latència de propagació de canvis.

### 4.5 Delegació de subdomini

La delegació permet transferir l'autoritat d'un subdomini a un conjunt diferent de servidors DNS:

```
demobind.test (dns1/dns2) → magatzem.demobind.test (dns3/dns4)
```

Per fer-ho, la zona pare (`demobind.test`) afegeix:
- **Registres NS** que apunten als servidors del subdomini
- **Glue records** (registres A) per als servidors de noms del subdomini, **dins de la mateixa zona pare**

Els glue records són necessaris per trencar la dependència circular: si `dns3.demobind.test` és el servidor de `magatzem.demobind.test`, i `dns3` és un host de `demobind.test`, cal saber la IP de `dns3` per poder preguntar-li per `magatzem`... però `dns3` no respon per `demobind.test`. La solució és incloure la IP de `dns3` directament a la zona pare com a glue record.

---

## 5. Fase 1 — DNS primari únic

### Concepte

Un sol servidor DNS autoritatiu per al domini `demobind.test`. Cobreix zona directa (noms → IPs) i zona inversa (IPs → noms).

### Topologia

```
br-dns ── dns1 (10.25.50.11)
       └── cl01 (10.25.50.101)
```

### Desplegament

```bash
./lab.sh deploy 1
```

### Configuració rellevant

**`fase1-primary/configs/dns1/named.conf.local`**
```
zone "demobind.test" {
    type master;
    file "/etc/bind/zones/db.demobind.test";
    allow-query { any; };
};

zone "50.25.10.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.10.25.50";
    allow-query { any; };
};
```

**`fase1-primary/configs/dns1/zones/db.demobind.test`** (zona directa)
```
$TTL 86400
@   IN  SOA dns1.demobind.test. hostmaster.demobind.test. (
        2026052801  ; serial
        3600        ; refresh
        900         ; retry
        604800      ; expire
        86400 )     ; negative TTL

@       IN  NS      dns1.demobind.test.
@       IN  MX  10  mail.demobind.test.

dns1    IN  A       10.25.50.11
mail    IN  A       10.25.50.50
www     IN  A       10.25.50.80
cl01    IN  A       10.25.50.101
```

**`fase1-primary/configs/dns1/zones/db.10.25.50`** (zona inversa)
```
$TTL 86400
@   IN  SOA dns1.demobind.test. hostmaster.demobind.test. (
        2026052801 3600 900 604800 86400 )

@   IN  NS  dns1.demobind.test.

11  IN  PTR dns1.demobind.test.
50  IN  PTR mail.demobind.test.
80  IN  PTR www.demobind.test.
101 IN  PTR cl01.demobind.test.
```

> **Nota sobre la zona inversa:** El nom de la zona `50.25.10.in-addr.arpa` és la xarxa `10.25.50` escrita a l'inrevés. Els registres PTR contenen només l'últim octet de la IP (ex. `11` per a `10.25.50.11`).

### Verificació — Fase 1

Obrir shell al client textual:
```bash
./lab.sh shell cl01
```

Des de dins del contenidor `cl01`:

```bash
# Resolució directa bàsica
dig dns1.demobind.test
dig www.demobind.test
dig mail.demobind.test

# Resolució inversa
dig -x 10.25.50.11
dig -x 10.25.50.80

# Registre MX (correu)
dig demobind.test MX

# Servidor de noms de la zona
dig demobind.test NS

# Registre SOA
dig demobind.test SOA

# nslookup interactiu
nslookup
> server 10.25.50.11
> www.demobind.test
> exit
```

Sortida esperada per `dig www.demobind.test`:
```
;; ANSWER SECTION:
www.demobind.test.      86400   IN      A       10.25.50.80
```

### Logs de BIND9 — Fase 1

```bash
./lab.sh logs dns1   # Fitxer query.log
./lab.sh errors dns1 # Fitxer error.log
```

Cada consulta genera una entrada al `query.log`. La configuració de logging (`named.conf.logging`) defineix dos canals:
- `query_log`: registra totes les consultes rebudes
- `error_log`: registra avisos, errors de configuració, fallades de transferència

---

## 6. Fase 2 — Primari i secundari

### Concepte

Afegim un servidor DNS secundari (`dns2`) que replica les zones del primari via AXFR. El primari notifica activament el secundari de qualsevol canvi (NOTIFY).

### Topologia

```
br-dns ── dns1 (10.25.50.11)  ← primari
       ├── dns2 (10.25.50.12)  ← secundari
       ├── cl01 (10.25.50.101)
       └── cl02 (10.25.50.102)
```

### Desplegament

```bash
./lab.sh deploy 2
```

El `dns2` té `startup-delay: 10` a la topologia per assegurar que `dns1` ja està operatiu quan el secundari intenta la primera transferència AXFR.

### Configuració rellevant

**`fase2-secondary/configs/dns1/named.conf.local`** (primari — afegeix transfer i notify)
```
zone "demobind.test" {
    type master;
    file "/etc/bind/zones/db.demobind.test";
    allow-query { any; };
    allow-transfer { 10.25.50.12; };   ← permet AXFR des de dns2
    notify yes;                         ← avisa dns2 en cada canvi
    also-notify { 10.25.50.12; };
};

zone "50.25.10.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.10.25.50";
    allow-query { any; };
    allow-transfer { 10.25.50.12; };
    notify yes;
    also-notify { 10.25.50.12; };
};
```

**`fase2-secondary/configs/dns2/named.conf.local`** (secundari)
```
zone "demobind.test" {
    type slave;
    masters { 10.25.50.11; };               ← aprèn del primari
    file "/var/cache/bind/db.demobind.test.slave";  ← còpia local en cache
};

zone "50.25.10.in-addr.arpa" {
    type slave;
    masters { 10.25.50.11; };
    file "/var/cache/bind/db.10.25.50.slave";
};
```

### Verificació — Fase 2

```bash
./lab.sh shell cl01
```

```bash
# Consultar directament al secundari
dig @10.25.50.12 www.demobind.test
dig @10.25.50.12 demobind.test NS

# Verificar que el secundari té els mateixos registres que el primari
dig @10.25.50.11 demobind.test ANY
dig @10.25.50.12 demobind.test ANY

# Comprovar transferència de zona des del primari (AXFR)
dig @10.25.50.12 demobind.test AXFR
# Hauria de retornar tots els registres de la zona

# Veure el serial als dos servidors (han de coincidir)
dig @10.25.50.11 demobind.test SOA
dig @10.25.50.12 demobind.test SOA
```

### Comprovar la transferència als logs

```bash
./lab.sh errors dns1   # Ha d'aparèixer: "zone demobind.test/IN: sending notifies"
./lab.sh errors dns2   # Ha d'aparèixer: "zone demobind.test/IN: transferred serial XXXXXXXXXX"
```

### Simulació d'un canvi de zona

Per practicar el mecanisme de transferència, es pot forçar una recàrrega manual:

```bash
# Des de dins del contenidor dns1
docker exec -it clab-bind9-fase2-dns1 bash
rndc reload demobind.test   # Recarrega la zona sense reiniciar
rndc notify demobind.test   # Força un NOTIFY cap al secundari
```

---

## 7. Fase 3 — Delegació de subdomini

### Concepte

Delegació de l'autoritat del subdomini `magatzem.demobind.test` a dos nous servidors DNS (`dns3` com a primari i `dns4` com a secundari). La zona pare (`demobind.test`) inclou glue records per fer possible la resolució.

### Topologia

```
br-dns ── dns1 (10.25.50.11)  ← primari de demobind.test
       ├── dns2 (10.25.50.12)  ← secundari de demobind.test
       ├── dns3 (10.25.50.21)  ← primari de magatzem.demobind.test
       ├── dns4 (10.25.50.22)  ← secundari de magatzem.demobind.test
       ├── cl01 (10.25.50.101)
       └── cl02 (10.25.50.102)
```

### Desplegament

```bash
./lab.sh deploy 3
```

### Configuració rellevant

**`fase3-delegation/configs/dns1/zones/db.demobind.test`** — zona pare amb glue i delegació:
```
; ... (registres habituals) ...

dns1    IN  A   10.25.50.11
dns2    IN  A   10.25.50.12
; ...

; Glue records — IPs dels servidors de noms del subdomini delegat
; Cal incloure'ls aquí perquè dns3/dns4 formen part de demobind.test
dns3    IN  A   10.25.50.21
dns4    IN  A   10.25.50.22

; Delegació: qui és autoritatiu per a magatzem.demobind.test?
magatzem    IN  NS  dns3.demobind.test.
magatzem    IN  NS  dns4.demobind.test.
```

**`fase3-delegation/configs/dns3/zones/db.magatzem.demobind.test`** — zona del subdomini:
```
$TTL 86400
@   IN  SOA dns3.demobind.test. hostmaster.magatzem.demobind.test. (
        2026052801 3600 900 604800 86400 )

@               IN  NS  dns3.demobind.test.
@               IN  NS  dns4.demobind.test.

rodes           IN  A   10.25.50.60
prestatgeries   IN  A   10.25.50.61
```

**`fase3-delegation/configs/dns3/named.conf.local`** (primari del subdomini):
```
zone "magatzem.demobind.test" {
    type master;
    file "/etc/bind/zones/db.magatzem.demobind.test";
    allow-query { any; };
    allow-transfer { 10.25.50.22; };
    notify yes;
    also-notify { 10.25.50.22; };
};
```

**`fase3-delegation/configs/dns4/named.conf.local`** (secundari del subdomini):
```
zone "magatzem.demobind.test" {
    type slave;
    masters { 10.25.50.21; };
    file "/var/cache/bind/db.magatzem.demobind.test.slave";
};
```

### Flux de resolució de `rodes.magatzem.demobind.test`

1. `cl01` pregunta a `dns1` (el seu resolver configurat)
2. `dns1` busca `magatzem.demobind.test` a la seva zona
3. Troba registres NS apuntant a `dns3.demobind.test` i `dns4.demobind.test`
4. Gràcies als glue records, `dns1` sap que `dns3` és a `10.25.50.21`
5. `dns1` pregunta a `dns3` per `rodes.magatzem.demobind.test`
6. `dns3` respon amb `10.25.50.60`
7. `dns1` retorna el resultat a `cl01`

### Verificació — Fase 3

```bash
./lab.sh shell cl01
```

```bash
# Resolució completa via dns1 (recurs a través de la delegació)
dig rodes.magatzem.demobind.test
dig prestatgeries.magatzem.demobind.test

# Consulta directa al servidor del subdomini
dig @10.25.50.21 rodes.magatzem.demobind.test
dig @10.25.50.21 magatzem.demobind.test NS

# Verificar els glue records a la zona pare
dig @10.25.50.11 dns3.demobind.test
dig @10.25.50.11 dns4.demobind.test

# Verificar la delegació des de la zona pare
dig @10.25.50.11 magatzem.demobind.test NS

# Transferència del subdomini
dig @10.25.50.22 magatzem.demobind.test AXFR

# Traçar el camí de resolució pas a pas
dig +trace rodes.magatzem.demobind.test @10.25.50.11
```

---

## 8. Fase 4 — Lab complet

### Concepte

Lab complet amb tots els components: 4 servidors DNS, servidor web Nginx accessible per nom, client textual i client gràfic Firefox via noVNC.

### Topologia

```
br-dns ── dns1 (10.25.50.11)
       ├── dns2 (10.25.50.12)
       ├── dns3 (10.25.50.21)
       ├── dns4 (10.25.50.22)
       ├── www  (10.25.50.80)  ← Nginx: http://www.demobind.test
       ├── cl01 (10.25.50.101) ← netshoot (dig, curl, nslookup)
       └── cl02 (10.25.50.102) ← Firefox noVNC → http://localhost:6080
```

### Desplegament

```bash
./lab.sh deploy 4
```

### Client gràfic (cl02)

El contenidor `cl02` usa la imatge `lscr.io/linuxserver/firefox` que exposa Firefox via noVNC al port 3000 del contenidor, mapejat al port 6080 del host:

```
http://localhost:6080
```

Des del Firefox del noVNC, es pot navegar a:
- `http://www.demobind.test` — pàgina "labdns"
- `http://10.25.50.80` — mateixa pàgina per IP directa

### Servidor web Nginx

La pàgina de l'Nginx (`fase4-full/configs/nginx/html/index.html`) mostra el rètol "labdns" amb informació del servidor. Es pot personalitzar modificant el fitxer HTML i redespleqant.

### Verificació completa — Fase 4

```bash
./lab.sh shell cl01
```

```bash
# ── Zona directa ────────────────────────────────────
dig dns1.demobind.test          # 10.25.50.11
dig dns2.demobind.test          # 10.25.50.12
dig www.demobind.test           # 10.25.50.80
dig mail.demobind.test          # 10.25.50.50
dig cl01.demobind.test          # 10.25.50.101
dig cl02.demobind.test          # 10.25.50.102

# ── Zona inversa ────────────────────────────────────
dig -x 10.25.50.11              # dns1.demobind.test
dig -x 10.25.50.80              # www.demobind.test
dig -x 10.25.50.101             # cl01.demobind.test

# ── Registres especials ─────────────────────────────
dig demobind.test MX            # 10 mail.demobind.test
dig demobind.test NS            # dns1, dns2
dig demobind.test SOA           # Serial, TTL, etc.

# ── Delegació ───────────────────────────────────────
dig rodes.magatzem.demobind.test
dig prestatgeries.magatzem.demobind.test
dig magatzem.demobind.test NS   # dns3, dns4

# ── Redundància — provar dns2 ────────────────────────
dig @10.25.50.12 www.demobind.test
dig @10.25.50.12 demobind.test NS

# ── Servidor web ────────────────────────────────────
curl http://www.demobind.test   # Ha de mostrar el HTML de "labdns"
curl -v http://www.demobind.test 2>&1 | grep "< HTTP"   # HTTP/1.1 200 OK

# ── Logs ────────────────────────────────────────────
exit   # Sortir del contenidor
./lab.sh logs dns1              # Consultes rebudes per dns1
./lab.sh errors dns1            # Errors o avisos de dns1
```

---

## 9. Referència de comandes

### Gestió del lab

```bash
./lab.sh build          # Construir la imatge bind9-lab:latest
./lab.sh check          # Verificar requisits
./lab.sh deploy N       # Desplegar la fase N (1, 2, 3 o 4)
./lab.sh destroy        # Aturar i eliminar el lab actiu
./lab.sh status         # Mostrar fase activa i contenidors
```

### Accés als nodes

```bash
./lab.sh shell cl01         # Shell al client textual
./lab.sh shell dns1         # Shell al servidor DNS primari
./lab.sh shell dns3         # Shell al primari del subdomini
./lab.sh shell www          # Shell al servidor Nginx
```

### Visualització de logs

```bash
./lab.sh logs   dns1        # query.log de dns1 (en temps real)
./lab.sh errors dns1        # error.log de dns1 (en temps real)
./lab.sh logs   dns2        # query.log de dns2
./lab.sh errors dns3        # error.log de dns3
```

### Comandes `dig` de referència

```bash
# Resolució directa
dig FQDN [@servidor]              # Registre A per defecte
dig FQDN A [@servidor]            # Forçar registre A
dig FQDN MX [@servidor]           # Registres de correu
dig FQDN NS [@servidor]           # Servidors de noms
dig FQDN SOA [@servidor]          # Registre d'inici d'autoritat
dig FQDN ANY [@servidor]          # Tots els registres

# Resolució inversa
dig -x IP [@servidor]

# Transferència de zona (des del primari o secundari)
dig @servidor DOMINI AXFR

# Traçar el camí de resolució
dig +trace FQDN [@servidor]

# Sortida compacta
dig +short FQDN

# Sense recursió (consulta autoritativa directa)
dig +norecurse FQDN @servidor
```

### Comandes `nslookup` de referència

```bash
nslookup FQDN                    # Resolució simple
nslookup FQDN SERVIDOR           # Via servidor concret
nslookup -type=MX DOMINI         # Registres MX
nslookup -type=NS DOMINI         # Servidors de noms
nslookup -type=SOA DOMINI        # Registre SOA
nslookup -query=AXFR DOMINI SERVER  # Transferència (alguns clients)
```

### Comandes `rndc` (control de BIND9)

```bash
# Des de dins del contenidor del servidor
rndc status                       # Estat del servidor
rndc reload                       # Recarregar totes les zones
rndc reload demobind.test         # Recarregar zona específica
rndc notify demobind.test         # Forçar NOTIFY als secundaris
rndc flush                        # Buidar la cache del resolver
rndc dumpdb -cache                # Bolcar la cache a /var/cache/bind/named_dump.db
```

---

## 10. Resolució de problemes

### El contenidor no arrenca

```bash
docker logs clab-bind9-fase1-dns1   # Logs del contenidor
./lab.sh errors dns1                 # Errors de named
```

Causa habitual: error de sintaxi a un fitxer de configuració de BIND9. El `named` no arrenca si hi ha errors de sintaxi.

```bash
# Verificar sintaxi des de dins del contenidor
docker exec clab-bind9-fase1-dns1 named-checkconf /etc/bind/named.conf
docker exec clab-bind9-fase1-dns1 named-checkzone demobind.test /etc/bind/zones/db.demobind.test
```

### `dig` retorna NXDOMAIN

Possibles causes:
1. El registre no existeix al fitxer de zona
2. Error de sintaxi al fitxer de zona (named va ignorar-lo)
3. El serial no s'ha incrementat i el secundari no ha transferit la zona modificada
4. El fitxer de zona té un punt final incorrecte (ex. `dns1.demobind.test` sense punt final és relatiu)

```bash
# Verificar el fitxer de zona
docker exec clab-bind9-fase1-dns1 named-checkzone demobind.test /etc/bind/zones/db.demobind.test

# Verificar que named ha carregat la zona
docker exec clab-bind9-fase1-dns1 rndc zonestatus demobind.test
```

### La transferència de zona no funciona

```bash
# Verificar que el primari permet AXFR des del secundari
dig @10.25.50.11 demobind.test AXFR   # Ha de retornar registres

# Verificar logs al primari
./lab.sh errors dns1   # Buscar "transfer" o "xfer"

# Verificar logs al secundari
./lab.sh errors dns2   # Buscar "transferred" o "failed"
```

Causa habitual: `allow-transfer` no inclou la IP del secundari, o el `startup-delay` del secundari no és suficient.

### La delegació no funciona

```bash
# Verificar que dns1 té els glue records i els NS de delegació
dig @10.25.50.11 magatzem.demobind.test NS

# Verificar que dns3 respon directament
dig @10.25.50.21 rodes.magatzem.demobind.test

# Si dns1 té forwarders configurats, la delegació fallarà per a dominis locals!
# Verificar que NO hi ha forwarders:
docker exec clab-bind9-fase3-dns1 cat /etc/bind/named.conf.options
# No ha d'aparèixer cap línia "forwarders"
```

### El bridge no existeix

```bash
# Error: "Bridge br-dns referenced in topology but does not exist"
# Solució: crear el bridge manualment (o usar deploy.sh que ho fa automàticament)
sudo ip link add name br-dns type bridge
sudo ip link set br-dns up
```

### El noVNC (cl02) no és accessible

```bash
# Verificar que el contenidor cl02 és actiu
docker ps | grep cl02

# Verificar que el port 6080 és accessible
curl http://localhost:6080
```

Obrir `http://localhost:6080` al navegador del host. Si es veu una pantalla negra, esperar uns 10 segons que Firefox acabi d'arrancar.

---

## 11. Punts d'ampliació

Aquesta secció descriu com estendre el lab per treballar conceptes DNS avançats.

### 11.1 DNSSEC — Validació criptogràfica

DNSSEC afegeix signatures digitals als registres DNS per garantir autenticitat i integritat. És el pas natural després de dominar DNS bàsic.

**Com implementar-ho:**

1. Generar un parell de claus per a la zona (KSK i ZSK):
```bash
dnssec-keygen -a RSASHA256 -b 2048 -n ZONE demobind.test   # KSK
dnssec-keygen -a RSASHA256 -b 1024 -n ZONE demobind.test   # ZSK
```

2. Signar la zona:
```bash
dnssec-signzone -A -3 $(head -c 1000 /dev/random | sha1sum | cut -b 1-16) \
    -N INCREMENT -o demobind.test -t db.demobind.test
```

3. Activar DNSSEC a `named.conf.options`:
```
dnssec-validation yes;    # En comptes de "no"
dnssec-enable yes;
```

4. Verificar:
```bash
dig demobind.test DNSKEY   # Ha de retornar claus DNSKEY
dig www.demobind.test +dnssec   # Ha d'incloure registres RRSIG
```

### 11.2 Views (Split-horizon DNS)

Les views permeten retornar respostes DNS diferents en funció de qui fa la consulta. Útil per distingir entre consultes internes (xarxa local) i externes (internet).

**Cas d'ús típic:** `www.empresa.com` → IP interna des de la xarxa local, IP pública des d'internet.

**Configuració bàsica:**
```
view "interna" {
    match-clients { 10.25.50.0/24; };
    zone "demobind.test" {
        type master;
        file "/etc/bind/zones/db.demobind.test.intern";
    };
};

view "externa" {
    match-clients { any; };
    zone "demobind.test" {
        type master;
        file "/etc/bind/zones/db.demobind.test.extern";
    };
};
```

**Nota:** Quan s'usen views, *totes* les zones han d'estar dins d'una view (incloses les zones per defecte).

### 11.3 DNS dinàmic (DDNS)

Permet actualitzar registres DNS automàticament, com fa un servidor DHCP quan assigna una IP.

**Integració amb Kea DHCP** (veure lab `test003-kea-containerlab`):
1. Configurar Kea per enviar actualitzacions DDNS a BIND9
2. Configurar BIND9 per acceptar actualitzacions autenticades (`allow-update`)
3. Usar TSIG (claus HMAC) per autenticar les actualitzacions

```bash
# Generar clau TSIG
tsig-keygen -a hmac-sha256 dhcp-key
```

```
# A named.conf.local
zone "demobind.test" {
    type master;
    file "/etc/bind/zones/db.demobind.test";
    allow-update { key dhcp-key; };
};
```

### 11.4 ACLs (Llistes de control d'accés)

Les ACLs permeten controlar qui pot fer consultes, transferències o actualitzacions.

```
acl "xarxa-local" {
    10.25.50.0/24;
    127.0.0.1;
};

options {
    allow-query     { xarxa-local; };
    allow-recursion { xarxa-local; };   // Evitar ser un resolver obert
    allow-transfer  { none; };           // Denegar per defecte
};
```

**Importància:** Un servidor DNS configurat com a resolver obert (`allow-recursion { any; }` + accés públic) pot ser usat en atacs d'amplificació DNS. En producció, restringir sempre la recursió.

### 11.5 Rate limiting (DNS rate limiting)

Limita el nombre de respostes per segon per evitar atacs d'amplificació:

```
options {
    rate-limit {
        responses-per-second 10;
        window 5;
    };
};
```

### 11.6 Monitoratge amb Statistics Channel

BIND9 pot exposar estadístiques via HTTP per integrar amb Prometheus/Grafana:

```
statistics-channels {
    inet 0.0.0.0 port 8053 allow { any; };
};
```

Accedir a `http://dns1:8053` per veure estadístiques en XML, o usar el bind9_exporter de Prometheus.

### 11.7 Registres addicionals

```
; AAAA — IPv6
www     IN  AAAA    2001:db8::80

; CNAME — Àlies
ftp     IN  CNAME   www.demobind.test.
webmail IN  CNAME   www.demobind.test.

; TXT — Informació arbitrària (usat per SPF, DKIM, etc.)
@       IN  TXT     "v=spf1 mx -all"
_dmarc  IN  TXT     "v=DMARC1; p=reject"

; SRV — Localització de serveis
_ldap._tcp  IN  SRV 10 5 389 ldap.demobind.test.

; CAA — Autorització de certificats
@   IN  CAA 0 issue "letsencrypt.org"
```

### 11.8 Scripting de gestió de zones

Per a entorns dinàmics, es poden automatitzar canvis de zona amb `nsupdate`:

```bash
# Afegir un registre A dinàmicament (requereix allow-update)
nsupdate -k /etc/bind/keys/dhcp.key <<EOF
server 10.25.50.11
zone demobind.test.
update add nou-host.demobind.test. 3600 A 10.25.50.99
send
EOF
```

### 11.9 Alta disponibilitat amb anycast

En producció, múltiples instàncies d'un servidor DNS autoritatiu anuncien la mateixa IP via BGP (anycast). El tràfic DNS és enrutat automàticament al servidor més proper. Es pot simular en el lab amb Containerlab afegint routers BGP (FRR o BIRD).

### 11.10 Registre de zona complet (exemple de referència)

Exemple de zona avançada per a pràctica:

```
$TTL 300
@   IN  SOA dns1.demobind.test. admin.demobind.test. (
        2026052801 3600 900 604800 300 )

; Servidors de noms
@       IN  NS  dns1.demobind.test.
@       IN  NS  dns2.demobind.test.

; Correu
@       IN  MX  10  mail.demobind.test.
@       IN  MX  20  mail2.demobind.test.   ; MX de backup

; SPF (autoritza els MX a enviar correu)
@       IN  TXT "v=spf1 mx -all"

; Hosts principals
dns1    IN  A   10.25.50.11
dns2    IN  A   10.25.50.12
mail    IN  A   10.25.50.50
mail2   IN  A   10.25.50.51   ; Servidor de correu backup
www     IN  A   10.25.50.80
cl01    IN  A   10.25.50.101
cl02    IN  A   10.25.50.102

; Àlies
ftp     IN  CNAME www.demobind.test.
static  IN  CNAME www.demobind.test.

; Serveis SRV
_http._tcp  IN  SRV 10 0 80  www.demobind.test.
_https._tcp IN  SRV 10 0 443 www.demobind.test.

; Glue records per a la delegació
dns3    IN  A   10.25.50.21
dns4    IN  A   10.25.50.22

; Delegació
magatzem    IN  NS  dns3.demobind.test.
magatzem    IN  NS  dns4.demobind.test.
```

---

## Resum de fases i validació

| Fase | Nodes | Concepte clau | Comanda de verificació |
|------|-------|--------------|------------------------|
| 1 | dns1, cl01 | Zona directa + inversa | `dig www.demobind.test @10.25.50.11` |
| 2 | + dns2, cl02 | Transferència AXFR, NOTIFY | `dig @10.25.50.12 demobind.test AXFR` |
| 3 | + dns3, dns4 | Delegació, glue records | `dig rodes.magatzem.demobind.test` |
| 4 | + www | Lab complet, Nginx | `curl http://www.demobind.test` |

---

*Guia generada per al lab test018-bind9-lab — Institut TIC de Barcelona*

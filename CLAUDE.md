# CLAUDE.md — test018-bind9-lab

Laboratori modular de DNS amb BIND9 i Containerlab. Quatre fases progressives:
DNS primari → DNS primari+secundari → Delegació de subdomini → Lab complet amb web i client gràfic.

## Common Commands

```bash
./lab.sh build              # Construir la imatge Docker bind9-lab:latest
./lab.sh deploy 1           # Desplegar fase 1 (DNS primari bàsic)
./lab.sh deploy 2           # Desplegar fase 2 (+ secundari)
./lab.sh deploy 3           # Desplegar fase 3 (+ delegació magatzem)
./lab.sh deploy 4           # Desplegar fase 4 (+ nginx + client noVNC)
./lab.sh status             # Mostrar fase desplegada i contenidors
./lab.sh shell dns1         # Obrir shell al node dns1
./lab.sh logs dns1          # Mostrar logs BIND9 de dns1
./lab.sh destroy            # Destruir el lab actiu
```

## Architecture

- **docker/**: Dockerfile.bind9 — ubuntu:22.04 + bind9 + dnsutils
- **fase1-primary/**: dns1 (primari) + cl01 (client textual)
- **fase2-secondary/**: + dns2 (secundari, replicació AXFR)
- **fase3-delegation/**: + dns3+dns4 (servidors del subdomini magatzem)
- **fase4-full/**: + nginx (www.demobind.test) + cl02 (Firefox noVNC, port 6080)
- **assesment/**: 40 preguntes DNS, 4 models (A/B/C/D) + solucions

## Network Configuration

| Node | FQDN | IP |
|------|------|----|
| dns1 | dns1.demobind.test | 10.25.50.11 |
| dns2 | dns2.demobind.test | 10.25.50.12 |
| dns3 | dns3.demobind.test | 10.25.50.21 |
| dns4 | dns4.demobind.test | 10.25.50.22 |
| mail | mail.demobind.test | 10.25.50.50 (només registre DNS) |
| www  | www.demobind.test  | 10.25.50.80 |
| cl01 | cl01.demobind.test | 10.25.50.101 |
| cl02 | cl02.demobind.test | 10.25.50.102 |
| rodes | rodes.magatzem.demobind.test | 10.25.50.60 |
| prestatgeries | prestatgeries.magatzem.demobind.test | 10.25.50.61 |

## Key Files

- `*/topology.clab.yml`: Definició containerlab de cada fase
- `*/configs/dns1/named.conf.local`: Zones del servidor primari
- `*/configs/dns2/named.conf.local`: Zones del servidor secundari (type slave)
- `*/configs/dns3/named.conf.local`: Zona magatzem.demobind.test (primari)
- `*/configs/dns*/named.conf.logging`: Configuració de logs (query + errors)
- `*/configs/dns*/zones/db.*`: Fitxers de zona DNS

## Logging

- `/var/log/bind/query.log` — Totes les consultes DNS rebudes
- `/var/log/bind/error.log` — Errors, avisos i transferències de zona

## Consultes DNS útils (des de cl01)

```bash
dig demobind.test SOA           # Registre SOA
dig demobind.test NS            # Servidors de noms
dig www.demobind.test           # Zona directa
dig -x 10.25.50.80              # Zona inversa
dig @10.25.50.11 demobind.test AXFR   # Transferència de zona
dig magatzem.demobind.test NS   # Servidors del subdomini delegat
dig rodes.magatzem.demobind.test      # Host del subdomini
```

## Important Notes

- Imatge base: `ubuntu:22.04` amb bind9 instal·lat; `CMD ["sleep","infinity"]`
- Els contenidors reben la IP via `exec: ip addr add`; named s'inicia des d'exec
- Servidor secundari té `startup-delay: 10` per garantir que el primari ja és actiu
- El client noVNC (cl02) és accessible des del host a `http://localhost:6080`
- El serial del SOA segueix el format YYYYMMDDNN (ex: 2026052801)
- Zona delegada: dns3 primari, dns4 secundari per `magatzem.demobind.test`
- Glue records per dns3/dns4 inclosos al fitxer `db.demobind.test`
- **NO forwarders** als named.conf.options: amb forwarders, 8.8.8.8 retorna NXDOMAIN per
  dominis `.test` no registrats i trenca la resolució recursiva de la delegació.
  Connectivitat externa dels contenidors va per eth0 (Docker management).
- Les comandes exec amb redireccions shell (`>`, `>>`) requereixen `sh -c '...'`
  perquè containerlab no fa el wrap automàticament.

## Troubleshooting

- Si named no arrenca: `docker exec clab-<nom>-dns1 cat /var/log/bind/error.log`
- Si la transferència AXFR falla: verificar `allow-transfer` al primari i `masters` al secundari
- Si la delegació no funciona: verificar glue records (dns3/dns4 A records a db.demobind.test)
- Per reiniciar named sense recrear el contenidor: `docker exec clab-<nom>-dns1 pkill named && docker exec clab-<nom>-dns1 /usr/sbin/named -u bind`
- El directori de zones (:ro) no es pot modificar en calent; cal redesplegament

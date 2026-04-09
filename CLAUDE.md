# LegacyMCP — CLAUDE.md

## Cos'è questo progetto

LegacyMCP è un MCP (Model Context Protocol) server per Active Directory on-premises.
Permette a un LLM (Claude) di interrogare un ambiente AD reale, raccogliere dati di
assessment e rispondere a domande sulla configurazione del dominio.

Il progetto nasce come esperimento per dimostrare che l'AI può governare anche
l'infrastruttura legacy — non solo il cloud. È pubblicato su GitHub con licenza MIT
come progetto open source, con un layer enterprise proprietario sviluppato separatamente
da Impresoft 4ward.

Il progetto è creato da Marco Lelli, Head of Identity presso Impresoft 4ward (4ward.it),
società di consulenza IT specializzata in Microsoft Identity, e collegato al
blog Legacy Things (legacythings.it).

Repository: https://github.com/Marco-Lelli/legacy-mcp

---

## Struttura del progetto

### Layer Open Source — LegacyMCP Core
Pubblicato su GitHub con licenza MIT.
Scope funzionale basato sullo script ADDS_Inventory.ps1 di Carl Webster (v3.20).
Riferimento: https://github.com/CarlWebster/Active-Directory-V3
Sola lettura assoluta. Nessuna modifica all'ambiente AD.

Copre:
- Forest info — nome, functional level, schema version, optional features (es. Recycle Bin)
- Schema AD — oggetti e attributi custom
- Domini — configurazione, functional level, password policy default
- Domain Controllers — lista, ruoli FSMO, OS version, configurazioni locali
  (incluse impostazioni registry NTP avanzato — 12 chiavi tra cui AnnounceFlags,
  MaxNegPhaseCorrection, MaxPosPhaseCorrection, SpecialPollInterval,
  VMICTimeProviderEnabled — recuperate contattando ogni DC individualmente)
- Event Log configuration — impostazioni EventLog per ogni DC
  (Application/System/Security: MaxSizeBytes, RetentionDays, OverflowAction)
- SYSVOL — stato e replicazione (DFSR con traduzione stato numerico)
- Siti e site links — topologia di replicazione
- Utenti — conteggi, stati (abilitati/disabilitati/locked), lastlogon, pwdLastSet,
  PasswordNeverExpires, adminCount, UserPrincipalName, DistinguishedName, mail
- Gruppi — gruppi privilegiati, membership, nested groups ricorsivi,
  DistinguishedName, adminCount
- Computer objects — nome, OS, LastLogonDate, PasswordLastSet, Enabled,
  DistinguishedName, Description, IsCNO, IsVCO (limite 10.000 oggetti, configurabile)
- Organizational Units — struttura OU completa
- GPO Inventory — lista GPO per dominio, link alle OU, blocked inheritance
  (inventario, non analisi approfondita — quella è nel layer proprietario)
- Trust relationships — tipo, direzione, transitività, SIDHistory
- Fine-Grained Password Policies
- DNS — configurazione DNS dei Domain Controllers
- PKI / CA Discovery — Certification Authorities presenti in AD
  (CN=Public Key Services, CN=Enrollment Services)
  discovery automatica da AD, CN e Distinguished Name di ogni CA

NON incluso nel layer base:
- Analisi servizio DHCP — nel layer proprietario
- Analisi configurazione PKI — nel layer proprietario
- Analisi ESC path — nel layer proprietario

### Layer Proprietario — LegacyMCP Enterprise
Sviluppato internamente da Impresoft 4ward, non pubblicato open source.

Moduli pianificati:

- **DHCP Analysis** — assessment infrastruttura DHCP
- **GPO Analysis** — analisi approfondita Group Policy
- **AD Security Analysis** — analisi postura di sicurezza AD
- **AD Health Check** — verifica configurazioni e salute operativa
- **PKI Configuration Analysis** — configurazione CA, template, chain of trust, CRL, AIA
- **PKI Security Analysis** — analisi sicurezza PKI
- **ESC Analysis** — analisi template vulnerabili ESC1-ESC8
- **Generazione documento DOCX** — output da template aziendale Impresoft 4ward

---

## Modalità operative

LegacyMCP supporta due modalità operative con la stessa interfaccia verso Claude.

### Live Mode
Connessione diretta ai Domain Controllers via WinRM e PowerShell.
Richiede credenziali con diritti adeguati e accesso di rete ai DC.
Ideale per amministratori interni o consulenti con accesso diretto alla rete.
I dati sono freschi e interrogabili in tempo reale.

**Prerequisiti infrastrutturali:**
- Listener WinRM HTTPS su porta 5986 con certificato valido sul DC
- TLS 1.2 abilitato via registry (non default su Windows Server 2012 R2,
  verificare su tutte le versioni precedenti a 2016)
- CA interna non scaduta se il certificato DC è emesso internamente
- Server MCP su member server dedicato, mai sul Domain Controller

### Offline Mode
Un collector PowerShell raccoglie i dati AD e li esporta in un file JSON strutturato.
Il MCP server carica il JSON e lo converte internamente in SQLite per interrogazioni
efficienti. Il consulente lavora sul proprio PC con i dati esportati dall'ambiente
del cliente. Zero accesso di rete durante la fase di analisi.

Il file JSON è il formato di trasporto — leggibile, verificabile, trasportabile.
SQLite è il motore interno — mai esposto direttamente all'utente.

---

## Scope di lavoro — Workspace

LegacyMCP opera su scope variabili a seconda del contesto di assessment.

### Scenari supportati
- Singolo dominio — accesso limitato a un child domain, senza Enterprise Admin
- Foresta completa — accesso con Enterprise Admin, visione globale
- Foreste multiple standalone — clienti con ambienti separati
- Foreste multiple in relazione — migrazioni, M&A, trust cross-forest

### Concetto di Workspace
Un workspace definisce il contesto di lavoro corrente:
- Quali foreste e domini sono in scope
- Le credenziali associate a ciascuno (gMSA o account dedicato)
- Il tipo di relazione tra le foreste (standalone / source-destination / trust)
- La modalità operativa (Live o Offline)

### Offline Mode multi-scope
In Offline Mode ogni foresta o dominio produce un file JSON separato.
Il MCP server carica tutti i file in SQLite mantenendo una chiave sorgente
per ogni oggetto. Questo abilita controlli incrociati tra ambienti diversi.

### Caso d'uso migrazione
Quando il workspace contiene una foresta source e una destination, LegacyMCP
abilita query comparative:
- Utenti presenti in source ma non in destination
- Gruppi senza equivalente nel target
- Mapping SIDHistory per utenti già migrati
- Conflitti di naming tra i due ambienti

---

## Autenticazione al MCP Server

LegacyMCP supporta tre profili di deployment con requisiti di sicurezza crescenti.
Il codice è unico — cambia il file di configurazione e le istruzioni di deployment.

| Profilo | Scenario | Layer | Autenticazione |
|---------|----------|-------|----------------|
| A | stdio locale sul PC del consulente | Core | Nessuna |
| B — LAN condivisa | Server in rete interna, team condiviso | Core | API key di team |
| B — LAN con audit | Server in rete interna, accesso nominale | Enterprise | Entra ID nominale |
| C | Server esposto su internet | Enterprise | OAuth2/OIDC Entra ID obbligatorio |

### Profilo A — stdio locale
Il MCP server gira sulla macchina del consulente come processo locale.
Comunicazione via stdio — nessuna rete coinvolta, superficie di attacco zero.
Nessuna autenticazione necessaria: chi ha accesso alla macchina ha già
accesso a tutto.

Il JSON prodotto dal collector è classificato Confidential/Restricted.
Responsabilità del consulente:
- Disco cifrato (BitLocker)
- Non sincronizzare il JSON su cloud non autorizzati (OneDrive personale,
  Dropbox, ecc.)
- Trasporto sicuro se il file deve spostarsi — non email in chiaro,
  non USB non cifrata
- Eliminazione sicura al termine dell'engagement

LegacyMCP non cifra il JSON — non è un vault. La sicurezza a riposo
è demandata al sistema operativo e alle policy aziendali.

### Profilo B — LAN condivisa (layer Core)
Il MCP server gira su un server in rete interna, accessibile al team.
Autenticazione tramite API key di team condivisa nel config.yaml.
TLS obbligatorio — nessun traffico in chiaro al di fuori di localhost.

### Profilo B — LAN con audit (layer Enterprise)
Come il Profilo B Core, ma con autenticazione nominale tramite Entra ID.
Ogni operazione è tracciata per utente — prerequisito per ambienti
con requisiti di audit o compliance.

### Profilo C — internet (layer Enterprise)
Scenario possibile ma da affrontare con le dovute cautele.
Requisiti minimi per rendere lo scenario accettabile:
- WAF obbligatorio davanti al MCP server
  (Azure Application Gateway con WAF, Cloudflare WAF, AWS WAF)
- TLS termination sul WAF
- OAuth2/OIDC con Entra ID come provider di identità
- MFA obbligatorio
- IP allowlisting se i consulenti operano da paesi noti
- Rate limiting
- Logging centralizzato di tutto il traffico in ingresso

Senza WAF e OAuth2/OIDC: sconsigliato.

---

## Deployment Profiles

Il campo `profile` nel config.yaml determina:
- Il mode di default per tutti i forest del workspace
- Se l'override per singolo forest è permesso
- I requisiti di autenticazione al server MCP

| Profile | Default mode | Override | Auth | Notes |
|---------|--------------|----------|------|-------|
| A | offline | no | nessuna | PC del consulente |
| B-core | live | yes | API key di team | LAN condivisa |
| B-enterprise | live | yes | Nominale per utente | LAN con audit |
| C | offline | no | Forte — obbligatoria | Internet / SaaS |

### config.yaml — profile field

Esempio Profile B-core con forest eterogenei (live + offline + snapshot storico):

```yaml
profile: B-core

workspace:
  forests:
    - name: contoso.local
      module: ad-core
      dc: dc01.contoso.local
      credentials: gmsa

    - name: contoso.local-pki
      module: ad-pki
      mode: offline           # override: questo modulo non supporta live
      file: data/contoso-pki.json

    - name: contoso.local-snapshot-2025
      relation: snapshot
      module: ad-core
      mode: offline
      file: data/contoso-snapshot-20250318.json

server:
  host: 0.0.0.0   # Profile B: bind su tutte le interfacce
  port: 8000
```

### config.yaml — global mode field (deprecated)

Il campo `mode:` globale a livello root del config.yaml e' deprecato dal v0.1.1.
Usare il campo `profile:` per il deployment profile e, se necessario, il campo
`mode:` per-forest per gli override individuali. Il server emette un warning
a stderr se rileva `mode:` al livello root.

### server.host

Per deployment in rete (Profile B) impostare `server.host: 0.0.0.0` nel config.yaml.
Il default `127.0.0.1` è corretto solo per Profile A (localhost).
In Profile B, uvicorn si lega a localhost per default e non è raggiungibile
dalla rete senza questo campo esplicito.

---

## Module System

Ogni forest nel workspace dichiara opzionalmente il campo `module`,
che identifica il tipo di dati contenuti nel JSON.

Esempi: `ad-core`, `ad-pki`, `ad-gpo`, `ad-dhcp`.

I moduli sono indipendenti — nessuna dipendenza forzata tra di loro.
Un workspace può contenere forest con moduli diversi.

Il layer Core include il modulo `ad-core`, che copre l'intero inventario AD
come definito da ADDS_Inventory.ps1 di Carl Webster.

Moduli aggiuntivi sono disponibili nel layer enterprise.
Ogni JSON include un blocco `_metadata` con `module`, `collected_at`
e `collector_version`.

---

## Snapshots as Bridge Between Profiles

Gli snapshot prodotti in Profile B sono riutilizzabili in Profile A e Profile C.

- **Profile B → Profile A**: esporta uno snapshot dal workspace live,
  caricalo in Profile A per consultazione locale o confronto storico.
- **Profile B → Profile C**: lo snapshot è il formato di trasporto verso
  il Portal in Profile C. I dati non lasciano mai la rete del cliente
  finché non vengono esportati come JSON.

Lo snapshot è il meccanismo di continuità tra profili — produce un JSON
nello stesso formato del collector offline, caricabile in qualsiasi
workspace con `mode: offline`.

---

## Principio architetturale fondamentale — Degradazione elegante

LegacyMCP opera spesso in ambienti parzialmente raggiungibili — DC in sedi remote,
firewall restrittivi, macchine in manutenzione.

Regole:
- Ogni operazione verso un DC ha un timeout configurabile
- Il fallimento su un DC non blocca la raccolta sugli altri
- Ogni dato ha un campo di stato: "completo" / "parziale" / "non raggiungibile"
- I DC irraggiungibili generano un warning nel EventLog dedicato, non un errore bloccante
- L'output finale indica chiaramente quali informazioni sono complete e quali parziali

---

## Requisiti tecnici

### PowerShell
- Versione minima: PowerShell 5.1
- Supporto opzionale: PowerShell 7.x
- Copertura: Windows Server 2012 R2 aggiornato a WMF 5.1 fino a Windows Server 2025

### MCP Server
- Linguaggio: Python
- SDK: mcp (SDK MCP ufficiale Anthropic)
- Formato dati interno: JSON (trasporto) + SQLite (interrogazione Offline Mode)

### Autenticazione ad AD
- Metodo preferito: gMSA (Group Managed Service Account)
- Il gMSA elimina la gestione manuale delle password
- Richiede che la macchina che ospita il servizio sia domain-joined

### Deployment come servizio Windows
- LegacyMCP può essere installato come servizio Windows
- Gestibile con strumenti standard Windows (sc, services.msc, PowerShell)
- Riavvio automatico in caso di crash

### EventLog dedicato
- LegacyMCP scrive in un EventLog dedicato (non nel log Application generico)
- Ogni operazione viene loggata: chi ha richiesto cosa, su quali oggetti,
  con quale risultato
- I DC irraggiungibili generano eventi di Warning
- Gli errori bloccanti generano eventi di Error
- Compatibile con SIEM, Microsoft Sentinel, e qualsiasi NPM del cliente
- **Setup richiesto**: il source "LegacyMCP" deve essere registrato una volta
  con `scripts/Register-EventLog.ps1` (richiede Administrator).
  Se non registrato, il server continua a funzionare ma emette un warning
  a stderr alla prima scrittura EventLog fallita.

### Performance Counter — Heartbeat
- **Non ancora implementato** — pianificato per una release futura.
- Descrizione funzionale: contatore heartbeat incrementale, contatore DC
  contattati con successo vs totali, monitorabile con PerfMon e SCOM.
- Implementazione richiede win32pdh (pywin32) e registrazione del counter
  come prerequisito di installazione (analoga a EventLog).

---

## Security by Design — Principi architetturali

1. **Read-only assoluto** — mai creare, modificare o cancellare oggetti AD. Decisione architetturale, non limitazione tecnica.

2. **Minimo privilegio** — operare con i diritti minimi necessari. In Offline Mode nessuna credenziale AD.

3. **Dati sensibili locali** — in Offline Mode i dati AD non escono dalla rete del cliente. Il JSON è classificato Confidential/Restricted.

4. **Autenticazione forte per endpoint esposti** — tre profili A/B/C con requisiti di sicurezza crescenti.

5. **TLS su tutti gli endpoint non-localhost** — nessun traffico in chiaro al di fuori di localhost.

6. **Credenziali mai in chiaro** — gMSA, Azure Key Vault, Windows Credential Manager. Mai in config files, variabili d'ambiente o log.

7. **Integrita' del codice** — collector PS1 firmato Authenticode, exe firmato per le release, hash SHA256 pubblicati per tutti gli artefatti di release.

8. **Auditabilita' completa** — EventLog dedicato, ogni operazione loggata con chi ha richiesto cosa, quando, su quali oggetti. Compatibile con SIEM e Microsoft Sentinel.

9. **Formato dati unificato** — snapshot Live Mode e JSON Offline Mode hanno lo stesso formato. Interoperabilita' completa tra le due modalita'.

10. **Degradazione sicura** — dati parziali sempre espliciti. DC irraggiungibili segnalati, mai saltati silenziosamente.

11. **Server MCP mai su Domain Controller** — i DC devono eseguire solo
    i servizi necessari al ruolo AD. Il server MCP va su un member server
    dedicato. Questa è una regola architetturale, non una raccomandazione.

---

## Cosa NON fare

- Non usare LDAP puro come unico metodo di accesso ad AD — manca il layer semantico
- Non ignorare errori di connessione ai DC — gestire sempre con degradazione elegante
- Non scrivere nell'Application EventLog generico — usare sempre il log dedicato
- Non hardcodare credenziali — usare sempre gMSA o configurazione esterna
- Non modificare mai oggetti AD nel layer open source — sola lettura assoluta
- Non usare PowerShell precedente a 5.1
- Non esporre il MCP server su internet senza WAF e autenticazione forte con MFA
- Non installare il server MCP su un Domain Controller — i DC devono
  eseguire solo i servizi necessari al ruolo AD. Il server MCP va su
  un member server dedicato. Installare su un DC viola il principio
  di separazione dei ruoli e aumenta la superficie di attacco.
- Nei file PowerShell usare esclusivamente caratteri ASCII — niente em dash, virgolette
  curve, o qualsiasi carattere non-ASCII. Usare trattini semplici (-) e virgolette dritte.
  Motivo: PowerShell su Windows legge i file senza BOM in codepage ANSI (CP1252) e
  interpreta i byte UTF-8 multi-byte come caratteri diversi, causando errori di parsing
  difficili da diagnosticare (es. il byte 0x94 dell'em dash UTF-8 diventa U+201D,
  virgoletta destra, che PowerShell riconosce come terminatore di stringa).

---

## Contesto operativo tipico

I consulenti di Impresoft 4ward lavorano spesso da remoto, connessi in VPN alla rete
del cliente, su macchine di management del cliente. A volte in modalità desktop sharing.

- Live Mode: usato quando il consulente ha accesso diretto alla rete del cliente
- Offline Mode: usato quando il consulente lavora da remoto o in desktop sharing —
  il collector gira nel contesto del cliente, il JSON viene portato fuori
  e analizzato in ambiente separato

---

## Strategia prompt per sessioni di assessment

### 1. Separare raccolta da analisi — due turni distinti

Il numero di tool call per turno e' limitato. Separare la raccolta dati
dall'analisi permette di sfruttare entrambi i turni al massimo.

Turno 1 — raccolta:
  "Raccogli tutti i dati di [forest] chiamando tutti i tool disponibili.
  Non produrre analisi — dimmi solo 'dati raccolti' quando hai finito."

Turno 2 — analisi:
  "Produci il report completo con finding per severita' Alta/Media/Bassa
  e segnala tool che hanno restituito dati vuoti o anomali."

### 2. Un ambiente alla volta

Non chiedere analisi su piu' forest in un singolo turno.
Il piano Pro di Claude Desktop ha un limite noto di tool call per turno
che viene raggiunto facilmente con query multi-forest.
Completare l'analisi di un forest, poi passare al successivo.

### 3. Query specifiche vs query generali

Quando si sa cosa cercare, essere specifici riduce il numero di tool call.

Esempio generico (molte call):
  "Analizza tutto l'ambiente"

Esempio specifico (poche call):
  "Dammi utenti con adminCount=1 e gruppi privilegiati con nested groups
  su contoso.local"

### 4. Il comando "Continue"

Se Claude raggiunge il limite tool call prima di produrre il report,
scrivere "Continue" fa riprendere la produzione del testo senza ulteriori
tool call, perche' i dati sono gia' in memoria.
E' la soluzione immediata quando si vede il messaggio:
  "Claude reached its tool-use limit for this turn."

### 5. list_workspaces() come primo passo

All'inizio di ogni sessione Claude chiama automaticamente list_workspaces()
per scoprire gli ambienti disponibili e verificare che i file JSON siano
stati caricati correttamente.
Se non lo fa, chiederlo esplicitamente prima di qualsiasi altra query.

---

## Client supportati

**Testato e funzionante:**
- Claude Desktop con piano Pro Anthropic

**Compatibile, non ancora testato ufficialmente:**
- GitHub Copilot in VS Code
  (configurazione tramite .vscode/mcp.json)

**In fase di valutazione architetturale:**
- Microsoft 365 Copilot tramite Copilot Studio
  (richiede server esposto su HTTPS — deployment Azure con APIM)

---

## Struttura repository
```
legacy-mcp/
├── collector/          # PowerShell offline data collector
│   ├── Collect-ADData.ps1
│   ├── README.txt
│   └── modules/        # moduli PS per area funzionale
├── config/             # template configurazione per profilo A/B/C
├── docs/               # architettura e documentazione
├── client/             # consultant client scripts (generated + static)
│   ├── mcp-remote-live.ps1   # DPAPI wrapper for mcp-remote
│   ├── mcp-remote-live.bat   # Claude Desktop entry point (generated)
│   ├── .legacymcp-key        # DPAPI-encrypted API key (generated, gitignored)
│   └── certs/                # server TLS cert (gitignored)
├── src/legacy_mcp/     # MCP server Python
│   ├── server.py       # entrypoint FastMCP
│   ├── config.py
│   ├── auth.py         # ASGI middleware — API key validation (Profile B)
│   ├── oauth.py        # OAuth 2.0 stub — discovery, PKCE, client_credentials
│   ├── workspace/
│   ├── modes/          # live.py e offline.py
│   ├── storage/        # JSON → SQLite
│   ├── tools/          # 15 moduli tool MCP
│   │   ├── workspace_info.py   # list_workspaces — entry point di sessione
│   │   ├── forest.py
│   │   ├── domains.py
│   │   ├── dcs.py
│   │   ├── sysvol.py
│   │   ├── sites.py
│   │   ├── users.py
│   │   ├── groups.py
│   │   ├── computers.py        # get_computers, get_computer_summary
│   │   ├── ous.py
│   │   ├── gpo.py
│   │   ├── trusts.py
│   │   ├── fgpp.py
│   │   ├── dns.py
│   │   └── pki.py
│   ├── eventlog/
│   └── service/        # Windows Service wrapper
└── tests/
    ├── fixtures/       # contoso-sample.json (AD fittizio per test)
    └── unit/
```

---

## Git Operations

- Always run `git status` and show the full list of staged files before any commit
- Never run `git commit` or `git push` without explicit user confirmation
- Always use absolute paths in configuration files (YAML, JSON) unless explicitly requested otherwise
- Always run `python -m pytest` after code changes before committing

---

## Cronologia del progetto

- 13 marzo 2025 — Prima idea
- 14 marzo 2025 — Definizione scope, architettura, decisioni tecniche, avvio lavori.
  Installazione Claude Code, creazione repository locale, primi file.
- 15 marzo 2025 — Primo sviluppo: struttura completa 54 file, 27 tool MCP,
  server funzionante in Offline Mode, 9/9 unit test passati.
  Prima query reale su contoso.local — risposta completa con finding.
  Primo commit git.
- 17 marzo 2025 — Gap analysis collector vs Webster, allineamento moduli PS,
  aggiunta Computers.psm1, pwdLastSet, adminCount, EventLog config, SYSVOL DFSR,
  NTP avanzato. Creazione README.txt collector. Repository GitHub privato creato
  e primo push. Test su ambienti reali, fix BOM UTF-8 loader Python,
  fix em dash UTF-8 in PowerShell (CP1252 parsing bug).
- 18 marzo 2025 — Test approfonditi su 4 ambienti AD reali: 17 anomalie censite
  e classificate (9 bug loader, 4 bug collector, 4 gap strutturali).
  Fix atomica KNOWN_SECTIONS loader.py. Fix collector: EventLog RetentionDays,
  schema OID filtering, MemberCount range retrieval, TrustedForDelegation.
  Nuovo tool get_computers con get_computer_summary e filtri delegation/stale.
  Definita architettura enterprise Azure (VM Windows, Blob Storage, Portal,
  APIM, Copilot Studio). Due file CLAUDE separati: pubblico e privato.
- 8 aprile 2026 — v0.1.5 "Secure Channel". OAuth 2.0 stub completo (oauth.py):
  discovery, PKCE auto-approve, dynamic client registration, token dual grant
  (authorization_code + client_credentials). Setup-LegacyMCPClient.ps1: API key
  migrata da env var AUTH_HEADER a DPAPI user-scope (.legacymcp-key).
  Entry point Claude Desktop migrato da PS1 a BAT (mcp-remote-live.bat) per
  evitare stdout pollution che rompeva il JSON-RPC. NODE_EXTRA_CA_CERTS
  impostato direttamente nel BAT. 341 test verdi. Prima release pubblica su GitHub.
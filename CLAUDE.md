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

LegacyMCP supporta tre profili di deployment con configurazione di sicurezza diversa.
Il codice è unico — cambia il file di configurazione e le istruzioni di deployment.

### Profilo A — Offline Mode locale
Il MCP server gira sulla macchina del consulente.
Non esposto in rete — superficie di attacco zero.
Autenticazione: API key locale nel file di configurazione,
o solo localhost senza autenticazione esplicita.

### Profilo B — Live Mode in rete interna
Il MCP server gira su un server dentro la rete del cliente.
Accessibile solo dalla LAN aziendale.
Autenticazione: HTTPS su porta 443 con certificato interno,
API key o integrazione con Entra ID / AD FS per SSO aziendale.
Il gMSA gestisce l'accesso ad AD — l'autenticazione al MCP è separata.

### Profilo C — Live Mode esposto su internet
Scenario sconsigliato senza adeguate protezioni — esporre un MCP server AD
su internet è una superficie di attacco seria.

Requisiti minimi per rendere lo scenario accettabile:
- WAF (Web Application Firewall) obbligatorio davanti al MCP server
  — opzione naturale in ambito Microsoft: Azure Application Gateway con WAF,
  integrato con Entra ID e Microsoft Sentinel
  — alternative: Cloudflare WAF, AWS WAF
- TLS termination sul WAF — il MCP server parla HTTP interno
- HTTPS con certificato valido
- OAuth2 / OIDC con Entra ID come provider di identità
- MFA obbligatorio
- IP allowlisting — se i consulenti operano da paesi noti, bloccare tutto il resto
- Rate limiting
- Logging centralizzato di tutto il traffico in ingresso

Senza WAF: sconsigliato.
Con WAF e configurazione completa: accettabile con le dovute cautele.

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

### Performance Counter — Heartbeat
- LegacyMCP espone un Performance Counter dedicato
- Contatore heartbeat: parte da zero all'avvio del servizio,
  si incrementa ogni N secondi
- Contatore DC: DC contattati con successo vs DC totali nell'ultimo ciclo
- Monitorabile con PerfMon, SCOM, e qualsiasi tool di monitoring Windows-based

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

---

## Cosa NON fare

- Non usare LDAP puro come unico metodo di accesso ad AD — manca il layer semantico
- Non ignorare errori di connessione ai DC — gestire sempre con degradazione elegante
- Non scrivere nell'Application EventLog generico — usare sempre il log dedicato
- Non hardcodare credenziali — usare sempre gMSA o configurazione esterna
- Non modificare mai oggetti AD nel layer open source — sola lettura assoluta
- Non usare PowerShell precedente a 5.1
- Non esporre il MCP server su internet senza WAF e autenticazione forte con MFA
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
├── src/legacy_mcp/     # MCP server Python
│   ├── server.py       # entrypoint FastMCP
│   ├── config.py
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